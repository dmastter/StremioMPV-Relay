// local http relay for mpv. it serves a remote file (a debrid cdn link) to the player and fetches the
// requested byte range over several parallel connections, replacing any connection that stalls or
// turns slow. urls, redirect targets, query strings and headers are never logged.
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Threading;

[assembly: System.Runtime.Versioning.TargetFramework(".NETFramework,Version=v4.8", FrameworkDisplayName = ".NET Framework 4.8")]

namespace StremioMpvRelay
{
    sealed class Options
    {
        public const string Usage = "usage: relay.exe --ready-file <path> [--port N] [--token <hex>] [--parent-pid <pid>] " +
            "[--idle-exit <seconds>] [--connections N] [--chunk-mb N] [--log <path>] [--insecure-test-ca <pem>]";

        static readonly string[] Names = { "--ready-file", "--port", "--token", "--parent-pid", "--idle-exit", "--connections",
            "--chunk-mb", "--log", "--insecure-test-ca" };

        public string ReadyFile;
        public int Port;
        public string Token;
        public int ParentPid;
        public double IdleExit = 300;
        public int Connections = 4;
        public int ChunkMb = 4;
        public string LogPath;
        public string TestCa;

        public static Options Parse(string[] args)
        {
            var o = new Options();
            for (int i = 0; i < args.Length; i++)
            {
                string name = args[i];
                if (Array.IndexOf(Names, name) < 0) throw new ArgumentException("unknown option " + name);
                if (i + 1 >= args.Length) throw new ArgumentException(name + " needs a value");
                string v = args[++i];
                switch (name)
                {
                    case "--ready-file": o.ReadyFile = v; break;
                    case "--port": o.Port = Int(name, v, 0, 65535); break;
                    case "--token": o.Token = v; break;
                    case "--parent-pid": o.ParentPid = Int(name, v, 1, int.MaxValue); break;
                    case "--idle-exit": o.IdleExit = Int(name, v, 0, int.MaxValue); break;
                    case "--connections": o.Connections = Int(name, v, 1, 16); break;
                    case "--chunk-mb": o.ChunkMb = Int(name, v, 1, 64); break;
                    case "--log": o.LogPath = v; break;
                    case "--insecure-test-ca": o.TestCa = v; break;
                }
            }
            if (string.IsNullOrEmpty(o.ReadyFile)) throw new ArgumentException("--ready-file is required");
            if (o.Token != null)
            {
                if (o.Token.Length < 16 || o.Token.Length > 128) throw new ArgumentException("--token must be 16 to 128 hex characters");
                foreach (char c in o.Token)
                    if (!Uri.IsHexDigit(c)) throw new ArgumentException("--token must be hex");
            }
            return o;
        }

        static int Int(string name, string v, int min, int max)
        {
            int n;
            if (!int.TryParse(v, NumberStyles.None, CultureInfo.InvariantCulture, out n) || n < min || n > max)
                throw new ArgumentException(name + " must be a number from " + min + " to " + max);
            return n;
        }
    }

    static class Clock
    {
        static readonly Stopwatch watch = Stopwatch.StartNew();
        public static double Now { get { return watch.Elapsed.TotalSeconds; } }
    }

    static class Log
    {
        const long MaxBytes = 1024 * 1024;
        const int KeepBytes = 200 * 1024;
        static readonly object sync = new object();
        static FileStream file;

        public static void Open(string path)
        {
            string full = Path.GetFullPath(path);
            Directory.CreateDirectory(Path.GetDirectoryName(full));
            file = new FileStream(full, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.ReadWrite | FileShare.Delete);
            lock (sync) Trim();
        }

        public static void Write(string msg)
        {
            if (file == null) return;
            byte[] b = Encoding.UTF8.GetBytes(DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff", CultureInfo.InvariantCulture) + " " + msg + "\r\n");
            lock (sync)
            {
                try
                {
                    file.Seek(0, SeekOrigin.End);
                    file.Write(b, 0, b.Length);
                    file.Flush();
                    Trim();
                }
                catch (Exception) { }
            }
        }

        // keeps the last ~200 KB, from a line start, once the file passes 1 MB
        static void Trim()
        {
            long len = file.Length;
            if (len <= MaxBytes) return;
            var tail = new byte[KeepBytes];
            file.Seek(len - KeepBytes, SeekOrigin.Begin);
            int got = 0;
            while (got < tail.Length)
            {
                int n = file.Read(tail, got, tail.Length - got);
                if (n <= 0) break;
                got += n;
            }
            int start = Array.IndexOf(tail, (byte)'\n', 0, got) + 1;
            file.SetLength(0);
            file.Write(tail, start, got - start);
            file.Flush();
        }
    }

    sealed class BufferPool
    {
        readonly Stack<byte[]> items = new Stack<byte[]>();
        readonly int size, keep;

        public BufferPool(int size, int keep) { this.size = size; this.keep = keep; }

        public int Size { get { return size; } }

        public byte[] Rent()
        {
            lock (items) { if (items.Count > 0) return items.Pop(); }
            return new byte[size];
        }

        public void Return(byte[] b)
        {
            if (b == null || b.Length != size) return;
            lock (items) { if (items.Count < keep) items.Push(b); }
        }

        public int Trim()
        {
            lock (items) { int n = items.Count; items.Clear(); return n; }
        }
    }

    // an http error status from upstream. never holds a url
    sealed class UpstreamError : Exception
    {
        public readonly int Status;
        public readonly double RetryAfter;
        public readonly string ContentRange;

        public UpstreamError(int status, double retryAfter, string contentRange) : base("status " + status)
        {
            Status = status; RetryAfter = retryAfter; ContentRange = contentRange;
        }
    }

    // our own fixed messages, safe to log
    sealed class RelayError : Exception
    {
        public RelayError(string msg) : base(msg) { }
    }

    // one http/1.1 request on a tcp connection of its own (HttpWebRequest pools and reuses sockets and
    // can sit on a reset for seconds). Abort() works from any thread: it closes the socket
    sealed class Upstream
    {
        const int TimeoutMs = 15000;
        public static X509Certificate2 TestCa;
        static volatile bool tls13Off;
        [ThreadStatic] static bool certRejected;

        volatile Socket sock;
        volatile bool aborted;
        Stream stream;
        readonly byte[] buf = new byte[16384];
        int bufPos, bufLen;
        long left;
        long chunkLeft;
        bool chunked, chunkSeen, eof;
        string location;

        public int Status;
        public Uri Url;
        public long ContentLength;
        public string ContentType, ContentRange, AcceptRanges;
        public double RetryAfter;

        public void Abort()
        {
            aborted = true;
            Socket s = sock;
            if (s != null) { try { s.Close(); } catch (Exception) { } }
        }

        // sends the request and reads the response head, following up to 10 redirects. statuses from 300
        // up (other than redirects) throw UpstreamError
        public void Open(Uri url, long from, long to, string ua)
        {
            for (int hop = 0; ; hop++)
            {
                Url = url;
                Exchange(url, from, to, ua);
                if (Status >= 300 && Status < 400 && location != null)
                {
                    Uri next;
                    if (hop >= 10) throw new RelayError("too many redirects");
                    if (!Uri.TryCreate(url, location, out next) || (next.Scheme != Uri.UriSchemeHttp && next.Scheme != Uri.UriSchemeHttps))
                        throw new RelayError("bad redirect");
                    Disconnect();
                    url = next;
                    continue;
                }
                if (Status >= 300) throw new UpstreamError(Status, RetryAfter, ContentRange);
                return;
            }
        }

        void Exchange(Uri url, long from, long to, string ua)
        {
            Connect(url);
            var sb = new StringBuilder();
            sb.Append("GET ").Append(url.PathAndQuery).Append(" HTTP/1.1\r\nHost: ");
            sb.Append(url.HostNameType == UriHostNameType.IPv6 ? "[" + url.DnsSafeHost + "]" : url.IdnHost);
            if (!url.IsDefaultPort) sb.Append(':').Append(url.Port.ToString(CultureInfo.InvariantCulture));
            sb.Append("\r\nUser-Agent: ").Append(string.IsNullOrEmpty(ua) ? "libmpv" : ua).Append("\r\n");
            if (from >= 0 && to >= 0) sb.Append("Range: bytes=").Append(from.ToString(CultureInfo.InvariantCulture)).Append('-').Append(to.ToString(CultureInfo.InvariantCulture)).Append("\r\n");
            else if (from >= 0) sb.Append("Range: bytes=").Append(from.ToString(CultureInfo.InvariantCulture)).Append("-\r\n");
            else if (to > 0) sb.Append("Range: bytes=-").Append(to.ToString(CultureInfo.InvariantCulture)).Append("\r\n");
            sb.Append("Accept: */*\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n");
            byte[] req = Encoding.ASCII.GetBytes(sb.ToString());
            stream.Write(req, 0, req.Length);
            stream.Flush();
            do ReadHead(); while (Status >= 100 && Status < 200);
        }

        void Connect(Uri url)
        {
            Disconnect();
            string host = url.DnsSafeHost;
            IPAddress ip;
            IPAddress[] addrs = IPAddress.TryParse(host, out ip) ? new[] { ip } : Dns.GetHostAddresses(url.IdnHost);
            if (addrs.Length == 0) throw new RelayError("host not found");
            for (int i = 0; ; i++)
            {
                var s = new Socket(addrs[i].AddressFamily, SocketType.Stream, ProtocolType.Tcp);
                sock = s;
                if (aborted) { s.Close(); throw new RelayError("aborted"); }
                try
                {
                    IAsyncResult ar = s.BeginConnect(addrs[i], url.Port, null, null);
                    // with more addresses to try (a broken ipv6 route listed first), a short wait for this one
                    int wait = i + 1 < addrs.Length ? 3000 : TimeoutMs;
                    if (!ar.AsyncWaitHandle.WaitOne(wait)) { s.Close(); throw new RelayError("connect timeout"); }
                    s.EndConnect(ar);
                    ar.AsyncWaitHandle.Close();
                    break;
                }
                catch (Exception)
                {
                    s.Close();
                    if (aborted || i + 1 >= addrs.Length) throw;
                }
            }
            sock.NoDelay = true;
            sock.ReceiveTimeout = TimeoutMs;
            sock.SendTimeout = TimeoutMs;
            stream = new NetworkStream(sock, false);
            if (url.Scheme != Uri.UriSchemeHttps) return;
            var ssl = new SslStream(stream, false, CheckCertificate);
            stream = ssl;
            bool tls13 = !tls13Off;
            certRejected = false;
            try { ssl.AuthenticateAsClient(url.IdnHost, null, tls13 ? SslProtocols.Tls12 | (SslProtocols)12288 : SslProtocols.Tls12, false); }
            catch (AuthenticationException)
            {
                // windows without tls 1.3 can refuse the combined setting: the retry uses tls 1.2 only
                if (tls13 && !certRejected && !aborted)
                {
                    tls13Off = true;
                    Log.Write("tls handshake failed with tls 1.3 enabled, using tls 1.2 only");
                }
                throw new RelayError(certRejected ? "certificate rejected" : "tls handshake failed");
            }
        }

        void Disconnect()
        {
            Socket s = sock;
            sock = null;
            if (s != null) { try { s.Close(); } catch (Exception) { } }
            stream = null;
            bufPos = bufLen = 0;
        }

        void ReadHead()
        {
            int end;
            if (bufPos > 0)
            {
                Buffer.BlockCopy(buf, bufPos, buf, 0, bufLen - bufPos);
                bufLen -= bufPos;
                bufPos = 0;
            }
            while ((end = Program.HeaderEnd(buf, bufLen)) < 0)
            {
                if (bufLen == buf.Length) throw new RelayError("response head too large");
                int n = stream.Read(buf, bufLen, buf.Length - bufLen);
                if (n <= 0) throw new RelayError("connection closed before the response");
                bufLen += n;
            }
            string[] lines = Encoding.GetEncoding(28591).GetString(buf, 0, end).Split(new[] { "\r\n" }, StringSplitOptions.None);
            bufPos = end + 4;
            string[] first = lines[0].Split(' ');
            if (first.Length < 2 || !first[0].StartsWith("HTTP/", StringComparison.Ordinal) ||
                !int.TryParse(first[1], NumberStyles.None, CultureInfo.InvariantCulture, out Status))
                throw new RelayError("bad response");
            ContentLength = -1;
            ContentType = ContentRange = AcceptRanges = location = null;
            RetryAfter = 0;
            chunked = false;
            for (int i = 1; i < lines.Length; i++)
            {
                int c = lines[i].IndexOf(':');
                if (c <= 0) continue;
                string name = lines[i].Substring(0, c).Trim().ToLowerInvariant(), value = lines[i].Substring(c + 1).Trim();
                long l;
                int secs;
                switch (name)
                {
                    case "content-length": if (long.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out l)) ContentLength = l; break;
                    case "content-type": ContentType = value; break;
                    case "content-range": ContentRange = value; break;
                    case "accept-ranges": AcceptRanges = value; break;
                    case "location": location = value; break;
                    case "retry-after": if (int.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out secs)) RetryAfter = secs; break;
                    case "transfer-encoding": chunked = value.IndexOf("chunked", StringComparison.OrdinalIgnoreCase) >= 0; break;
                }
            }
            if (chunked) ContentLength = -1;
            left = ContentLength;
            chunkLeft = 0;
            chunkSeen = eof = false;
        }

        // the response body; 0 at its end, RelayError when the connection ends before it
        public int Read(byte[] b, int off, int count)
        {
            if (eof || count == 0) return 0;
            if (chunked) return ReadChunked(b, off, count);
            if (left == 0) { eof = true; return 0; }
            int n = Raw(b, off, left > 0 ? (int)Math.Min(count, left) : count);
            if (n <= 0)
            {
                eof = true;
                if (left > 0) throw new RelayError("early end of data");
                return 0;
            }
            if (left > 0) left -= n;
            return n;
        }

        int ReadChunked(byte[] b, int off, int count)
        {
            if (chunkLeft == 0)
            {
                if (chunkSeen) ReadLine();
                string line = ReadLine();
                int semi = line.IndexOf(';');
                long size;
                if (!long.TryParse(semi >= 0 ? line.Substring(0, semi).Trim() : line.Trim(), NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out size) || size < 0)
                    throw new RelayError("bad chunk");
                chunkSeen = true;
                if (size == 0)
                {
                    while (ReadLine().Length > 0) { }
                    eof = true;
                    return 0;
                }
                chunkLeft = size;
            }
            int n = Raw(b, off, (int)Math.Min(count, chunkLeft));
            if (n <= 0) throw new RelayError("early end of data");
            chunkLeft -= n;
            return n;
        }

        string ReadLine()
        {
            var sb = new StringBuilder();
            while (true)
            {
                if (bufPos >= bufLen)
                {
                    bufPos = 0;
                    bufLen = stream.Read(buf, 0, buf.Length);
                    if (bufLen <= 0) { bufLen = 0; throw new RelayError("early end of data"); }
                }
                byte c = buf[bufPos++];
                if (c == '\n') return sb.ToString();
                if (c != '\r') sb.Append((char)c);
                if (sb.Length > 4096) throw new RelayError("bad chunk");
            }
        }

        int Raw(byte[] b, int off, int count)
        {
            if (bufPos < bufLen)
            {
                int n = Math.Min(count, bufLen - bufPos);
                Buffer.BlockCopy(buf, bufPos, b, off, n);
                bufPos += n;
                return n;
            }
            return stream.Read(b, off, count);
        }

        // windows' normal checks, plus (tests only) server certificates that chain to the test ca
        static bool CheckCertificate(object sender, X509Certificate cert, X509Chain chain, SslPolicyErrors errors)
        {
            if (errors == SslPolicyErrors.None) return true;
            if (TestCa != null && cert != null && errors == SslPolicyErrors.RemoteCertificateChainErrors && ChainsToTestCa(cert)) return true;
            certRejected = true;
            return false;
        }

        static bool ChainsToTestCa(X509Certificate cert)
        {
            var c = new X509Chain();
            try
            {
                c.ChainPolicy.RevocationMode = X509RevocationMode.NoCheck;
                c.ChainPolicy.VerificationFlags = X509VerificationFlags.AllowUnknownCertificateAuthority;
                c.ChainPolicy.ExtraStore.Add(TestCa);
                if (!c.Build(new X509Certificate2(cert))) return false;
                var root = c.ChainElements[c.ChainElements.Count - 1].Certificate;
                if (!string.Equals(root.Thumbprint, TestCa.Thumbprint, StringComparison.OrdinalIgnoreCase)) return false;
                foreach (X509ChainStatus st in c.ChainStatus)
                    if (st.Status != X509ChainStatusFlags.NoError && st.Status != X509ChainStatusFlags.UntrustedRoot) return false;
                return true;
            }
            finally { c.Reset(); }
        }
    }

    sealed class UrlInfo
    {
        public readonly object Sync = new object();
        public readonly string Key;
        public readonly Uri Original;
        public Uri Final;
        public long Size = -1;
        public string ContentType = "application/octet-stream";
        public bool Ranges = true;
        public double LastUsed;
        double connRate, best, bestAt, ttfb;

        public UrlInfo(string key, Uri original) { Key = key; Original = original; }

        public Uri Target { get { lock (Sync) return Final ?? Original; } }

        // per-connection rate including the request time (ewma), for sizing pieces
        public double ConnRate { get { lock (Sync) return connRate; } }

        public void AddConnRate(double r)
        {
            lock (Sync) connRate = connRate <= 0 ? r : connRate * 0.7 + r * 0.3;
        }

        public void SeedConnRate(double r)
        {
            lock (Sync) if (connRate <= 0) connRate = r;
        }

        public double Ttfb { get { lock (Sync) return ttfb; } }

        public void AddTtfb(double t)
        {
            lock (Sync) ttfb = ttfb <= 0 ? t : ttfb * 0.7 + t * 0.3;
        }

        // best recent connection rate, halving every 30 s
        public double Best(double now)
        {
            lock (Sync) return best * Math.Pow(0.5, (now - bestAt) / 30.0);
        }

        public void OfferRate(double now, double r)
        {
            lock (Sync)
            {
                if (r >= best * Math.Pow(0.5, (now - bestAt) / 30.0)) { best = r; bestAt = now; }
            }
        }

        public void Redirected(Uri asked, Uri got)
        {
            if (got == null || got.Equals(asked)) return;
            lock (Sync) Final = got;
        }

        // a redirect target was refused (expired cdn link): the next requests go through the original link
        // again. false when the original link itself was refused. other pieces may have done it already
        public bool Forget(Uri asked)
        {
            lock (Sync)
            {
                if (asked.Equals(Original)) return false;
                if (Final != null && Final.Equals(asked)) Final = null;
                return true;
            }
        }
    }

    sealed class Piece
    {
        public long Base;
        public int Length;
        public int Filled;          // bytes in Buf from the start of the piece
        public byte[] Buf;
        public bool Done, Released;
        public int Hedges, FailCount;
        public double FailSince = -1;
        public readonly List<Attempt> Active = new List<Attempt>();

        public long End { get { return Base + Length - 1; } }

        public string Span { get { return Base.ToString(CultureInfo.InvariantCulture) + "-" + End.ToString(CultureInfo.InvariantCulture); } }
    }

    // one connection (and its retries) feeding a piece
    sealed class Attempt
    {
        public Piece P;
        public long Pos;            // next absolute offset this connection delivers
        public double Started, FirstByte, LastData;
        public long Bytes;
        public bool Aborted, Waiting;
        public Upstream Up;
        public bool PreOpened;
        public Uri Target;
        readonly double[] sampleT = new double[8];
        readonly long[] sampleB = new long[8];
        int samples;

        public void Reset(double now)
        {
            Started = now; FirstByte = -1; LastData = now; Bytes = 0; samples = 0;
        }

        public void Sample(double now)
        {
            sampleT[samples % sampleT.Length] = now;
            sampleB[samples % sampleT.Length] = Bytes;
            samples++;
        }

        // bytes/s over about the last `window` seconds, not counting the wait for the first byte
        public double Rate(double now, double window)
        {
            if (FirstByte < 0) return 0;
            double t0 = FirstByte;
            long b0 = 0;
            int n = Math.Min(samples, sampleT.Length);
            for (int i = 0; i < n; i++)
            {
                if (sampleT[i] <= now - window && sampleT[i] > t0) { t0 = sampleT[i]; b0 = sampleB[i]; }
            }
            double dt = now - t0;
            return dt > 0.05 ? (Bytes - b0) / dt : 0;
        }
    }

    sealed class Session
    {
        const int MinPiece = 256 * 1024;
        const int FirstPiece = 512 * 1024;
        const double PieceSeconds = 2.0;
        const int MaxHedges = 3;

        readonly object sync = new object();
        readonly UrlInfo info;
        readonly long first, last;
        readonly string userAgent;
        readonly int window, maxInFlight, maxPiece;
        readonly List<Piece> pieces = new List<Piece>();
        readonly ManualResetEvent stop = new ManualResetEvent(false);
        long next;
        bool cancelled;
        string failure;
        public int Connections, Hedged, Retries;
        // what the cdn delivers per connection while sending, unlike the player's pace when its cache is full
        double rateSum;
        int rateN;
        public double PerConnection { get { lock (sync) return rateN > 0 ? rateSum / rateN : 0; } }

        // pre: the resolve request, already open at `first`, serves the first piece
        public Session(UrlInfo info, long first, long last, string userAgent, Upstream pre, long preLast)
        {
            this.info = info;
            this.first = first;
            this.last = last;
            this.userAgent = userAgent;
            window = Program.Opt.Connections;
            maxInFlight = 2 * window;
            maxPiece = Program.PiecePool.Size;
            next = first;
            if (pre != null)
            {
                lock (sync)
                {
                    var p = NewPiece(first, Math.Min(Math.Min(preLast, last) - first + 1, maxPiece));
                    Start(p, false, pre);
                }
            }
        }

        public static long InitialPiece(int maxPiece) { return Math.Min(FirstPiece, maxPiece); }

        public string Failure { get { lock (sync) return failure; } }

        // streams the range to the client; returns the number of bytes sent
        public long Send(Socket client)
        {
            long sent = first;
            try
            {
                lock (sync) Schedule();
                while (sent <= last)
                {
                    Piece head = null;
                    int off = 0, count = 0;
                    lock (sync)
                    {
                        if (cancelled) break;
                        if (pieces.Count > 0)
                        {
                            head = pieces[0];
                            off = (int)(sent - head.Base);
                            count = head.Filled - off;
                        }
                        if (count <= 0)
                        {
                            Monitor.Wait(sync, 250);
                            if (cancelled) break;
                            if (head != null) count = head.Filled - off;
                        }
                    }
                    if (count <= 0)
                    {
                        if (Program.ClientGone(client)) { lock (sync) Cancel("client closed"); break; }
                        continue;
                    }
                    Program.SendAll(client, head.Buf, off, count);
                    sent += count;
                    if (sent > head.End)
                    {
                        lock (sync)
                        {
                            pieces.RemoveAt(0);
                            head.Released = true;
                            Program.PiecePool.Return(head.Buf);
                            head.Buf = null;
                            Schedule();
                        }
                    }
                }
            }
            catch (Exception)
            {
                lock (sync) Cancel("client closed");
            }
            finally
            {
                lock (sync)
                {
                    Cancel(null);
                    foreach (var p in pieces)
                    {
                        p.Released = true;
                        Program.PiecePool.Return(p.Buf);
                        p.Buf = null;
                    }
                    pieces.Clear();
                }
            }
            return sent - first;
        }

        // under lock
        void Cancel(string why)
        {
            if (cancelled) return;
            cancelled = true;
            failure = why;
            stop.Set();
            foreach (var p in pieces)
                foreach (var a in p.Active) AbortAttempt(a);
            Monitor.PulseAll(sync);
        }

        // under lock
        static void AbortAttempt(Attempt a)
        {
            if (a.Aborted) return;
            a.Aborted = true;
            if (a.Up != null) a.Up.Abort();
        }

        // under lock: keeps up to `window` pieces between what the client is sent and what is fetched
        void Schedule()
        {
            while (!cancelled && pieces.Count < window && next <= last)
            {
                var p = NewPiece(next, Math.Min(last - next + 1, PieceSize()));
                Start(p, false, null);
            }
        }

        // pieces last about 2 s on one connection, so the client gets them in order at the combined speed
        long PieceSize()
        {
            double r = info.ConnRate;
            long size = r > 0 ? (long)(r * PieceSeconds) : FirstPiece;
            size = (size + 65535) / 65536 * 65536;
            return Math.Max(Math.Min(MinPiece, maxPiece), Math.Min(maxPiece, size));
        }

        Piece NewPiece(long at, long len)
        {
            var p = new Piece();
            p.Base = at;
            p.Length = (int)len;
            p.Buf = Program.PiecePool.Rent();
            pieces.Add(p);
            next = at + len;
            return p;
        }

        // under lock
        void Start(Piece p, bool hedge, Upstream pre)
        {
            var a = new Attempt();
            a.P = p;
            a.Pos = p.Base + p.Filled;
            a.Up = pre;
            a.PreOpened = pre != null;
            a.Reset(Clock.Now);
            p.Active.Add(a);
            if (hedge) { p.Hedges++; Hedged++; }
            ThreadPool.QueueUserWorkItem(state => Program.Guarded(() => Fetch(a)));
        }

        void Fetch(Attempt a)
        {
            Piece p = a.P;
            byte[] tmp = Program.ReadPool.Rent();
            try
            {
                while (true)
                {
                    Upstream up;
                    long from, to;
                    lock (sync)
                    {
                        up = a.PreOpened ? a.Up : null;
                        a.PreOpened = false;
                        if (cancelled || a.Aborted || p.Done || p.Released)
                        {
                            if (up != null) up.Abort();
                            return;
                        }
                        from = a.Pos;
                        to = p.End;
                    }
                    try
                    {
                        if (up == null)
                        {
                            Uri target = info.Target;
                            up = new Upstream();
                            lock (sync)
                            {
                                if (cancelled || a.Aborted) return;
                                a.Up = up;
                                a.Target = target;
                                Connections++;
                            }
                            double t0 = Clock.Now;
                            up.Open(target, from, to, userAgent);
                            info.AddTtfb(Clock.Now - t0);
                            info.Redirected(target, up.Url);
                            long ca, cb, size;
                            if (up.Status != 206) throw new RelayError("status " + up.Status + " to a range request");
                            if (!Program.ParseContentRange(up.ContentRange, out ca, out cb, out size) || ca != from || cb < from)
                                throw new RelayError("unexpected content-range");
                            // a server that sends a range in parts: the rest comes with the next request
                            if (cb < to) to = cb;
                        }
                        long pos = from;
                        while (pos <= to)
                        {
                            int n = up.Read(tmp, 0, (int)Math.Min(tmp.Length, to - pos + 1));
                            if (n <= 0) throw new RelayError("early end of data");
                            bool more;
                            lock (sync) more = Commit(a, tmp, n);
                            pos += n;
                            if (!more) return;
                        }
                        if (to < p.End) continue;
                        return;
                    }
                    catch (Exception e)
                    {
                        if (!Failed(a, e)) return;
                    }
                    finally
                    {
                        up.Abort();
                    }
                }
            }
            finally
            {
                lock (sync)
                {
                    p.Active.Remove(a);
                    Monitor.PulseAll(sync);
                    Schedule();
                }
                Program.ReadPool.Return(tmp);
            }
        }

        // under lock. copies what this connection adds to the piece; false when it should stop reading
        bool Commit(Attempt a, byte[] tmp, int n)
        {
            Piece p = a.P;
            if (cancelled || a.Aborted || p.Done || p.Released) return false;
            double now = Clock.Now;
            if (a.FirstByte < 0) a.FirstByte = now;
            a.LastData = now;
            a.Bytes += n;
            long filledEnd = p.Base + p.Filled;
            long end = a.Pos + n;
            if (end > filledEnd)
            {
                int skip = (int)(filledEnd - a.Pos);
                Buffer.BlockCopy(tmp, skip, p.Buf, p.Filled, n - skip);
                p.Filled += n - skip;
                p.FailSince = -1;
                p.FailCount = 0;
                if (pieces.Count > 0 && pieces[0] == p) Monitor.PulseAll(sync);
            }
            a.Pos = end;
            if (p.Filled == p.Length)
            {
                p.Done = true;
                if (now - a.Started > 0.05) info.AddConnRate(a.Bytes / (now - a.Started));
                if (a.Bytes >= 256 * 1024 && now - a.FirstByte > 0.05)
                {
                    info.OfferRate(now, a.Bytes / (now - a.FirstByte));
                    rateSum += a.Bytes / (now - a.FirstByte);
                    rateN++;
                }
                foreach (var o in p.Active)
                    if (o != a) AbortAttempt(o);
                Monitor.PulseAll(sync);
                return false;
            }
            // two connections on one piece: the one clearly behind lost the race
            if (p.Active.Count > 1 && a.Pos == p.Base + p.Filled)
            {
                long lag = Math.Min(256 * 1024, Math.Max(32 * 1024, p.Length / 8));
                foreach (var o in p.Active)
                {
                    if (o != a && !o.Aborted && !o.Waiting && a.Pos - o.Pos >= lag && (o.FirstByte >= 0 || now - o.Started >= 2))
                        AbortAttempt(o);
                }
            }
            return true;
        }

        // decides what happens after a failed request; true to retry on a new connection
        bool Failed(Attempt a, Exception e)
        {
            Piece p = a.P;
            string label = Program.Describe(e);
            var ue = e as UpstreamError;
            int status = ue != null ? ue.Status : 0;
            double delay;
            lock (sync)
            {
                if (cancelled || a.Aborted || p.Done || p.Released) return false;
                int others = 0;
                foreach (var o in p.Active)
                    if (o != a && !o.Aborted) others++;
                if (others > 0)
                {
                    Log.Write("piece " + p.Span + ": " + label + ", the other connection carries on");
                    return false;
                }
                bool fatal = false, reresolve = false;
                if (status == 401 || status == 403 || status == 404 || status == 410)
                {
                    reresolve = a.Target != null && info.Forget(a.Target);
                    fatal = !reresolve;
                }
                else if (status > 0 && !Program.Retryable(status)) fatal = true;
                // a cdn node that keeps failing: a fresh link from the original one may land on another node
                if (!fatal && !reresolve && p.FailCount >= 2 && a.Target != null && !a.Target.Equals(info.Original))
                    reresolve = info.Forget(a.Target);
                double now = Clock.Now;
                if (p.FailSince < 0) p.FailSince = now;
                if (!fatal && now - p.FailSince > 60) fatal = true;
                if (fatal)
                {
                    Log.Write("piece " + p.Span + ": " + label + ", giving up");
                    Cancel("failed: " + label);
                    return false;
                }
                delay = reresolve && p.FailCount == 0 ? 0 : Program.Backoff(p.FailCount);
                if (ue != null && ue.RetryAfter > delay) delay = Math.Min(5.0, ue.RetryAfter);
                p.FailCount++;
                Retries++;
                a.Waiting = true;
                a.Up = null;
                Log.Write("piece " + p.Span + ": " + label + (reresolve ? ", resolving the link again" : ", retry in " + Program.F1(delay) + " s"));
            }
            if (delay > 0 && stop.WaitOne(TimeSpan.FromSeconds(delay))) return false;
            lock (sync)
            {
                if (cancelled || a.Aborted || p.Done || p.Released) return false;
                a.Waiting = false;
                a.Pos = p.Base + p.Filled;
                a.Reset(Clock.Now);
                return true;
            }
        }

        // every 250 ms: measures connections and adds one for a piece whose connection stalls or crawls
        public void Tick(double now)
        {
            lock (sync)
            {
                if (cancelled) return;
                int live = 0, n = 0;
                double sum = 0;
                foreach (var p in pieces)
                {
                    foreach (var a in p.Active)
                    {
                        if (a.Aborted) continue;
                        live++;
                        if (a.Waiting) continue;
                        a.Sample(now);
                        if (a.FirstByte >= 0 && now - a.FirstByte >= 1.0)
                        {
                            info.OfferRate(now, a.Rate(now, 1.5));
                            sum += a.Bytes / (now - a.Started);
                            n++;
                        }
                    }
                }
                if (n > 0) info.SeedConnRate(sum / n);
                double best = info.Best(now);
                for (int i = 0; i < pieces.Count && live < maxInFlight; i++)
                {
                    var p = pieces[i];
                    if (p.Done) continue;
                    Attempt only = null;
                    int count = 0;
                    foreach (var a in p.Active)
                        if (!a.Aborted) { only = a; count++; }
                    // its connection ended without finishing it (shouldn't happen): start another
                    if (count == 0) { Start(p, false, null); live++; continue; }
                    if (count != 1 || only.Waiting || p.Hedges >= MaxHedges) continue;
                    string why = SlowReason(p, only, now, best);
                    if (why == null) continue;
                    Log.Write("piece " + p.Span + ": " + why + ", adding a connection");
                    Start(p, true, null);
                    live++;
                }
                Schedule();
            }
        }

        string SlowReason(Piece p, Attempt a, double now, double best)
        {
            if (a.FirstByte < 0)
            {
                double limit = Math.Max(2.0, 3 * info.Ttfb);
                return now - a.Started >= limit ? "no data for " + Program.F1(now - a.Started) + " s after the request" : null;
            }
            if (now - a.LastData >= 2.0) return "no data for " + Program.F1(now - a.LastData) + " s";
            if (now - a.FirstByte < 1.5) return null;
            double rate = a.Rate(now, 1.5);
            // compare with connections running right now (a shared line slows all of them alike);
            // with none, with the best recent one
            double reference = 0;
            foreach (var q in pieces)
            {
                foreach (var o in q.Active)
                {
                    if (o != a && !o.Aborted && !o.Waiting && o.FirstByte >= 0 && now - o.FirstByte >= 1.0)
                        reference = Math.Max(reference, o.Rate(now, 1.5));
                }
            }
            if (reference <= 0) reference = best;
            if (reference <= 0 || rate >= reference / 3) return null;
            if (p.End - a.Pos + 1 <= rate) return null;    // done within a second anyway
            return "slow at " + Program.Speed(rate) + " (best " + Program.Speed(reference) + ")";
        }
    }

    sealed class ClientRequest
    {
        public string Method, Target, Range, UserAgent;
    }

    static class Program
    {
        public static Options Opt;
        public static BufferPool PiecePool, ReadPool;
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
        static readonly Dictionary<string, UrlInfo> cache = new Dictionary<string, UrlInfo>();
        static readonly List<Session> sessions = new List<Session>();
        static int openClients, ticking;
        static double lastActivity, lastSession;
        static bool trimmed;
        static Timer timer;
        static string readyPath, readyText;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool MoveFileEx(string existing, string replacement, int flags);

        static int Main(string[] args)
        {
            try
            {
                Opt = Options.Parse(args);
            }
            catch (ArgumentException e)
            {
                Console.Error.WriteLine("relay: " + e.Message);
                Console.Error.WriteLine(Options.Usage);
                return 2;
            }
            try
            {
                return Run();
            }
            catch (Exception e)
            {
                Log.Write("fatal: " + Describe(e));
                Console.Error.WriteLine("relay: " + Describe(e));
                return 1;
            }
        }

        // .net framework's uri drops trailing dots from path segments ("/Show.S01./x.mkv" becomes
        // "/Show.S01/x.mkv"), so the server would get another path. clearing the parser's
        // CanonicalizeAsFilePath flag for http and https keeps the path as given
        static void KeepPathDots()
        {
            try
            {
                MethodInfo getSyntax = typeof(UriParser).GetMethod("GetSyntax", BindingFlags.Static | BindingFlags.NonPublic);
                FieldInfo flags = typeof(UriParser).GetField("m_Flags", BindingFlags.Instance | BindingFlags.NonPublic);
                if (getSyntax == null || flags == null) return;
                foreach (string scheme in new[] { "http", "https" })
                {
                    object parser = getSyntax.Invoke(null, new object[] { scheme });
                    if (parser != null) flags.SetValue(parser, (int)flags.GetValue(parser) & ~0x1000000);
                }
            }
            catch (Exception e) { Log.Write("couldn't keep trailing dots in paths: " + Describe(e)); }
        }

        static int Run()
        {
            if (Opt.LogPath != null) Log.Open(Opt.LogPath);
            try { Process.GetCurrentProcess().PriorityClass = ProcessPriorityClass.BelowNormal; } catch (Exception) { }
            KeepPathDots();

            Process parent = null;
            if (Opt.ParentPid > 0)
            {
                try
                {
                    parent = Process.GetProcessById(Opt.ParentPid);
                    if (parent.WaitForExit(0)) { Log.Write("the parent process is already gone"); return 0; }
                }
                catch (ArgumentException) { Log.Write("the parent process is already gone"); return 0; }
            }

            if (Opt.Token == null)
            {
                var bytes = new byte[16];
                using (var rng = new RNGCryptoServiceProvider()) rng.GetBytes(bytes);
                var sb = new StringBuilder();
                foreach (byte b in bytes) sb.Append(b.ToString("x2", Inv));
                Opt.Token = sb.ToString();
            }
            if (Opt.TestCa != null) Upstream.TestCa = LoadPem(Opt.TestCa);

            // connections and clients block on their sockets in pool threads; reusing threads keeps handles
            // down, and a higher minimum lets the pool start them without its usual delay
            int workers, ports;
            ThreadPool.GetMinThreads(out workers, out ports);
            ThreadPool.SetMinThreads(Math.Max(workers, 64), ports);

            PiecePool = new BufferPool(Opt.ChunkMb * 1024 * 1024, 2 * Opt.Connections);
            ReadPool = new BufferPool(64 * 1024, 32);

            var listener = new TcpListener(IPAddress.Loopback, Opt.Port);
            listener.Server.ExclusiveAddressUse = true;
            listener.Start(64);
            int port = ((IPEndPoint)listener.LocalEndpoint).Port;
            lastActivity = lastSession = Clock.Now;

            var accept = new Thread(() => AcceptLoop(listener));
            accept.IsBackground = true;
            accept.Start();
            timer = new Timer(TickAll, null, 250, 250);

            WriteReadyFile(Opt.ReadyFile, port);
            Log.Write("started: " + Opt.Connections + " connections, pieces up to " + Opt.ChunkMb + " MB, idle exit " +
                (Opt.IdleExit > 0 ? Opt.IdleExit + " s" : "off") + (parent != null ? ", watching the parent process" : ""));

            string reason;
            while (true)
            {
                if (parent != null)
                {
                    if (parent.WaitForExit(2000)) { reason = "the parent process exited"; break; }
                }
                else Thread.Sleep(2000);
                if (Opt.IdleExit > 0 && Volatile.Read(ref openClients) == 0 && Clock.Now - Volatile.Read(ref lastActivity) >= Opt.IdleExit)
                {
                    reason = "no client for " + Opt.IdleExit + " s";
                    break;
                }
            }
            Log.Write("exiting: " + reason);
            DeleteReadyFile();
            try { listener.Stop(); } catch (Exception) { }
            Environment.Exit(0);
            return 0;
        }

        static void AcceptLoop(TcpListener listener)
        {
            while (true)
            {
                Socket c;
                try
                {
                    c = listener.AcceptSocket();
                    // counts as activity right away, so the idle exit can't fire before the client is handled
                    Touch();
                    ThreadPool.QueueUserWorkItem(state => Guarded(() => HandleClient(c)));
                }
                catch (Exception) { Thread.Sleep(100); }
            }
        }

        static void TickAll(object state)
        {
            if (Interlocked.Exchange(ref ticking, 1) == 1) return;
            try
            {
                Session[] list;
                lock (sessions) list = sessions.ToArray();
                double now = Clock.Now;
                foreach (var s in list) s.Tick(now);
                if (list.Length > 0) { lastSession = now; trimmed = false; }
                else if (!trimmed && now - lastSession > 60)
                {
                    // nothing playing for a minute: give the piece buffers back
                    trimmed = true;
                    if (PiecePool.Trim() > 0) GC.Collect();
                }
            }
            catch (Exception e) { Log.Write("tick error: " + e.GetType().Name); }
            finally { Interlocked.Exchange(ref ticking, 0); }
        }

        static void Touch() { Volatile.Write(ref lastActivity, Clock.Now); }

        // an exception that escapes a thread would end the process: log its type instead
        public static void Guarded(Action body)
        {
            try { body(); }
            catch (Exception e) { Log.Write("internal error: " + e.GetType().Name); }
        }

        static void HandleClient(Socket s)
        {
            Interlocked.Increment(ref openClients);
            Touch();
            double t0 = Clock.Now;
            string method = null, rangeText = "none", outcome = "complete", what = "";
            int status = 0, conns = 0, hedged = 0, retries = 0;
            double perConn = 0;
            long sent = 0;
            bool abortive = false;
            Upstream pre = null;
            try
            {
                s.NoDelay = true;
                s.ReceiveTimeout = 10000;
                var rq = ReadRequest(s);
                if (rq == null) { outcome = null; return; }
                method = rq.Method == "GET" || rq.Method == "HEAD" ? rq.Method : "other method";
                if (rq.Method != "GET" && rq.Method != "HEAD") { status = 405; Reply(s, 405, null); return; }
                string path = rq.Target;
                int q = path.IndexOf('?');
                if (q >= 0) path = path.Substring(0, q);
                string[] parts = path.Split('/');
                if (parts.Length < 2 || parts[0].Length != 0 || !TokenMatches(parts[1])) { status = 403; Reply(s, 403, null); return; }
                Uri url = parts.Length >= 3 ? DecodeUrl(parts[2]) : null;
                if (url == null) { status = 400; Reply(s, 400, null); return; }
                long ra, rb;
                int kind = ParseRange(rq.Range, out ra, out rb);
                rangeText = kind == 0 ? "none" : kind == 2 ? "bytes=-" + rb.ToString(Inv) : "bytes=" + ra.ToString(Inv) + "-" + (rb >= 0 ? rb.ToString(Inv) : "");
                bool head = rq.Method == "HEAD";

                long preFirst = -1, preLast = -1;
                UrlInfo info = Cached(url.OriginalString);
                if (info == null)
                {
                    long from = 0, to = Session.InitialPiece(PiecePool.Size) - 1;
                    if (kind == 1) { from = ra; to = rb >= 0 ? Math.Min(rb, ra + to) : ra + to; }
                    else if (kind == 2) to = 0;
                    int resolveStatus;
                    string error;
                    info = Resolve(url, from, to, rq.UserAgent, s, ref conns, ref retries, out pre, out preFirst, out preLast, out resolveStatus, out error);
                    if (info == null)
                    {
                        status = resolveStatus;
                        outcome = "failed: " + error;
                        Reply(s, status, null);
                        return;
                    }
                }
                if (!info.Ranges)
                {
                    what = ", pass-through";
                    sent = PassThrough(s, head, info, kind, ra, rb, rq.UserAgent, ref pre, ref status, ref conns);
                    return;
                }

                long size = info.Size, S, E;
                if (kind == 0) { S = 0; E = size - 1; }
                else if (kind == 1) { S = ra; E = rb < 0 || rb >= size ? size - 1 : rb; }
                else { S = Math.Max(0, size - rb); E = size - 1; }
                if (kind != 0 && (S >= size || (kind == 2 && rb == 0)))
                {
                    status = 416;
                    what = ", size " + size.ToString(Inv);
                    Reply(s, 416, "Content-Range: bytes */" + size.ToString(Inv) + "\r\n");
                    return;
                }
                status = kind == 0 ? 200 : 206;
                var h = new StringBuilder();
                h.Append("Content-Type: ").Append(info.ContentType).Append("\r\n");
                h.Append("Content-Length: ").Append((E - S + 1).ToString(Inv)).Append("\r\n");
                if (kind != 0) h.Append("Content-Range: bytes ").Append(S.ToString(Inv)).Append('-').Append(E.ToString(Inv)).Append('/').Append(size.ToString(Inv)).Append("\r\n");
                h.Append("Accept-Ranges: bytes\r\n");
                SendHead(s, status, h.ToString());
                what = ", " + (size == 0 ? "empty" : S.ToString(Inv) + "-" + E.ToString(Inv)) + "/" + size.ToString(Inv);
                if (head || size == 0) return;

                if (pre != null && preFirst != S) { pre.Abort(); pre = null; }
                var session = new Session(info, S, E, rq.UserAgent, pre, preLast);
                pre = null;
                lock (sessions) sessions.Add(session);
                try { sent = session.Send(s); }
                finally { lock (sessions) sessions.Remove(session); }
                conns += session.Connections;
                hedged = session.Hedged;
                retries += session.Retries;
                perConn = session.PerConnection;
                string f = session.Failure;
                if (sent < E - S + 1) outcome = f ?? "client closed";
                abortive = f != null && f != "client closed";
                // the player's reconnect starts from the original link again, like a fresh open would
                if (abortive) lock (cache) cache.Remove(info.Key);
            }
            catch (Exception e)
            {
                outcome = "error: " + Describe(e);
                abortive = true;
            }
            finally
            {
                if (pre != null) pre.Abort();
                double dur = Clock.Now - t0;
                if (method != null && outcome != null)
                {
                    Log.Write(method + " " + rangeText + " -> " + status + what + ", sent " + sent.ToString(Inv) + " in " + F2(dur) + " s (" +
                        (sent / 1048576.0 / Math.Max(dur, 0.001)).ToString("0.00", Inv) + " MB/s), connections " + conns + ", hedged " + hedged +
                        ", retries " + retries + (perConn > 0 ? ", cdn " + (perConn / 1048576.0).ToString("0.0", Inv) + " MB/s per connection" : "") +
                        ": " + outcome);
                }
                CloseClient(s, abortive);
                Interlocked.Decrement(ref openClients);
                Touch();
            }
        }

        static ClientRequest ReadRequest(Socket s)
        {
            var buf = new byte[16384];
            int n = 0, end;
            while ((end = HeaderEnd(buf, n)) < 0)
            {
                if (n == buf.Length) return null;
                int r;
                try { r = s.Receive(buf, n, buf.Length - n, SocketFlags.None); }
                catch (Exception) { return null; }
                if (r <= 0) return null;
                n += r;
            }
            string[] lines = Encoding.GetEncoding(28591).GetString(buf, 0, end).Split(new[] { "\r\n" }, StringSplitOptions.None);
            string[] first = lines[0].Split(' ');
            if (first.Length != 3 || !first[2].StartsWith("HTTP/1.", StringComparison.Ordinal) || !first[1].StartsWith("/", StringComparison.Ordinal))
                return null;
            var rq = new ClientRequest();
            rq.Method = first[0];
            rq.Target = first[1];
            for (int i = 1; i < lines.Length; i++)
            {
                int c = lines[i].IndexOf(':');
                if (c <= 0) continue;
                string name = lines[i].Substring(0, c).Trim(), value = lines[i].Substring(c + 1).Trim();
                if (name.Equals("Range", StringComparison.OrdinalIgnoreCase)) rq.Range = value;
                else if (name.Equals("User-Agent", StringComparison.OrdinalIgnoreCase)) rq.UserAgent = CleanHeader(value);
            }
            return rq;
        }

        // offset of the blank line that ends an http head, or -1
        public static int HeaderEnd(byte[] b, int n)
        {
            for (int i = 3; i < n; i++)
                if (b[i] == '\n' && b[i - 1] == '\r' && b[i - 2] == '\n' && b[i - 3] == '\r') return i - 3;
            return -1;
        }

        // 0 = no usable range (whole file), 1 = a- or a-b (b = -1 when open), 2 = suffix of b bytes
        static int ParseRange(string h, out long a, out long b)
        {
            a = -1;
            b = -1;
            if (h == null || !h.StartsWith("bytes=", StringComparison.OrdinalIgnoreCase)) return 0;
            string spec = h.Substring(6).Split(',')[0].Trim();
            int dash = spec.IndexOf('-');
            if (dash < 0) return 0;
            string x = spec.Substring(0, dash).Trim(), y = spec.Substring(dash + 1).Trim();
            long v;
            if (x.Length == 0)
            {
                if (!long.TryParse(y, NumberStyles.None, Inv, out v)) return 0;
                b = v;
                return 2;
            }
            if (!long.TryParse(x, NumberStyles.None, Inv, out v)) return 0;
            a = v;
            if (y.Length == 0) return 1;
            if (!long.TryParse(y, NumberStyles.None, Inv, out v) || v < a) { a = -1; return 0; }
            b = v;
            return 1;
        }

        static bool TokenMatches(string s)
        {
            string t = Opt.Token;
            if (s == null || s.Length != t.Length) return false;
            int d = 0;
            for (int i = 0; i < t.Length; i++) d |= s[i] ^ t[i];
            return d == 0;
        }

        static Uri DecodeUrl(string s)
        {
            if (string.IsNullOrEmpty(s) || s.Length > 16384 || s.Length % 4 == 1) return null;
            foreach (char c in s)
            {
                if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '_')) return null;
            }
            string b = s.Replace('-', '+').Replace('_', '/');
            if (b.Length % 4 == 2) b += "==";
            else if (b.Length % 4 == 3) b += "=";
            string text;
            try { text = new UTF8Encoding(false, true).GetString(Convert.FromBase64String(b)); }
            catch (FormatException) { return null; }
            catch (ArgumentException) { return null; }
            Uri u;
            if (!Uri.TryCreate(text, UriKind.Absolute, out u)) return null;
            if (u.Scheme != Uri.UriSchemeHttp && u.Scheme != Uri.UriSchemeHttps) return null;
            return u;
        }

        static readonly byte[] Crlf = { 13, 10 };

        static readonly string[] Reasons = { "200 OK", "206 Partial Content", "400 Bad Request", "401 Unauthorized", "403 Forbidden",
            "404 Not Found", "405 Method Not Allowed", "408 Request Timeout", "410 Gone", "416 Range Not Satisfiable",
            "429 Too Many Requests", "500 Internal Server Error", "502 Bad Gateway", "503 Service Unavailable", "504 Gateway Timeout" };

        static string StatusLine(int code)
        {
            string c = code.ToString(Inv) + " ";
            foreach (var r in Reasons)
                if (r.StartsWith(c, StringComparison.Ordinal)) return "HTTP/1.1 " + r + "\r\n";
            return "HTTP/1.1 " + c + (code < 400 ? "OK" : "Error") + "\r\n";
        }

        static void SendHead(Socket s, int code, string headers)
        {
            byte[] b = Encoding.ASCII.GetBytes(StatusLine(code) + headers + "Connection: close\r\n\r\n");
            SendAll(s, b, 0, b.Length);
        }

        static void Reply(Socket s, int code, string headers)
        {
            SendHead(s, code, (headers ?? "") + "Content-Length: 0\r\n");
        }

        // non-blocking: a blocked send on windows loopback doesn't always fail when the player closes its
        // side (after a seek), which left the session, its thread and its pieces stuck forever. a paused
        // player may stop reading for hours, so a full socket alone is no reason to give up
        public static void SendAll(Socket s, byte[] b, int off, int count)
        {
            bool was = s.Blocking;
            s.Blocking = false;
            try
            {
                while (count > 0)
                {
                    SocketError err;
                    int n = s.Send(b, off, count, SocketFlags.None, out err);
                    if (err == SocketError.WouldBlock)
                    {
                        if (!s.Poll(1000000, SelectMode.SelectWrite) && ClientGone(s)) throw new IOException("client closed");
                        continue;
                    }
                    if (err != SocketError.Success) throw new SocketException((int)err);
                    off += n;
                    count -= n;
                }
            }
            finally { try { s.Blocking = was; } catch (ObjectDisposedException) { } }
        }

        // the player closed its side (it does that on every seek)
        public static bool ClientGone(Socket s)
        {
            try { return s.Poll(0, SelectMode.SelectRead) && s.Available == 0; }
            catch (Exception) { return true; }
        }

        // the response length is always known, so the player closes first; we wait for that (up to 30 s:
        // a client process that exits doesn't always send a fin on loopback). a shutdown or close of our
        // own while data is still queued can lose its tail on windows loopback.
        // abortive: a reset right away, so ffmpeg reconnects instead of waiting for the missing bytes
        static void CloseClient(Socket s, bool abortive)
        {
            try
            {
                if (!abortive)
                {
                    var junk = new byte[4096];
                    double until = Clock.Now + 30;
                    while (Clock.Now < until)
                    {
                        if (!s.Poll(250000, SelectMode.SelectRead)) continue;
                        if (s.Available == 0) break;
                        s.Receive(junk);
                    }
                }
                s.LingerState = new LingerOption(true, abortive ? 0 : 10);
            }
            catch (Exception) { }
            try { s.Close(); } catch (Exception) { }
        }

        static UrlInfo Cached(string key)
        {
            lock (cache)
            {
                UrlInfo i;
                if (!cache.TryGetValue(key, out i)) return null;
                i.LastUsed = Clock.Now;
                return i;
            }
        }

        static void Remember(UrlInfo info)
        {
            lock (cache)
            {
                info.LastUsed = Clock.Now;
                cache[info.Key] = info;
                while (cache.Count > 32)
                {
                    UrlInfo oldest = null;
                    foreach (var i in cache.Values)
                        if (oldest == null || i.LastUsed < oldest.LastUsed) oldest = i;
                    cache.Remove(oldest.Key);
                }
            }
        }

        // first request for a link: follows redirects and learns the size, type and range support. the
        // response stays open so its body can serve the start of the client's range
        static UrlInfo Resolve(Uri url, long from, long to, string ua, Socket client, ref int conns, ref int retries,
            out Upstream up, out long first, out long last, out int status, out string error)
        {
            up = null;
            first = last = -1;
            status = 0;
            error = null;
            double start = Clock.Now;
            int fails = 0;
            while (true)
            {
                var u = new Upstream();
                conns++;
                string label;
                double delay;
                int code = 0;
                try
                {
                    u.Open(url, from, to, ua);
                    var info = new UrlInfo(url.OriginalString, url);
                    info.Final = u.Url;
                    info.ContentType = CleanType(u.ContentType);
                    long a, b, size;
                    if (u.Status == 206 && ParseContentRange(u.ContentRange, out a, out b, out size) && size >= 0 &&
                        !"none".Equals((u.AcceptRanges ?? "").Trim(), StringComparison.OrdinalIgnoreCase))
                    {
                        info.Size = size;
                        first = a;
                        last = b;
                    }
                    else
                    {
                        info.Ranges = false;
                        info.Size = u.Status == 200 ? u.ContentLength : -1;
                    }
                    Remember(info);
                    up = u;
                    return info;
                }
                catch (UpstreamError e)
                {
                    u.Abort();
                    long a, b, size;
                    if (e.Status == 416 && ParseContentRange(e.ContentRange, out a, out b, out size) && size >= 0)
                    {
                        var info = new UrlInfo(url.OriginalString, url);
                        info.Size = size;
                        Remember(info);
                        return info;
                    }
                    label = Describe(e);
                    code = e.Status;
                    if (!Retryable(code))
                    {
                        status = code >= 400 && code < 500 ? code : 502;
                        error = label;
                        Log.Write("resolve: " + label);
                        return null;
                    }
                    delay = Math.Max(Backoff(fails), Math.Min(5.0, e.RetryAfter));
                }
                catch (Exception e)
                {
                    u.Abort();
                    label = Describe(e);
                    delay = Backoff(fails);
                }
                fails++;
                if (Clock.Now - start + delay > 60 || ClientGone(client))
                {
                    status = code > 0 ? code : 502;
                    error = label;
                    Log.Write("resolve: " + label + ", giving up");
                    return null;
                }
                retries++;
                Log.Write("resolve: " + label + ", retry in " + F1(delay) + " s");
                for (double until = Clock.Now + delay; Clock.Now < until; )
                {
                    Thread.Sleep(250);
                    if (ClientGone(client)) break;
                }
            }
        }

        public static double Backoff(int fails) { return Math.Min(5.0, 0.5 * Math.Pow(2, Math.Min(fails, 4))); }

        public static bool Retryable(int status) { return status == 0 || status == 408 || status == 429 || status >= 500; }

        // the server can't do ranges: one plain stream, with the client's range passed on as is
        static long PassThrough(Socket s, bool head, UrlInfo info, int kind, long ra, long rb, string ua,
            ref Upstream up, ref int status, ref int conns)
        {
            if (up == null)
            {
                up = new Upstream();
                conns++;
                try
                {
                    if (kind == 1) up.Open(info.Original, ra, rb, ua);
                    else if (kind == 2) up.Open(info.Original, -1, rb, ua);
                    else up.Open(info.Original, -1, -1, ua);
                }
                catch (UpstreamError e)
                {
                    status = e.Status >= 400 && e.Status < 600 ? e.Status : 502;
                    Reply(s, status, e.Status == 416 && e.ContentRange != null ? "Content-Range: " + CleanHeader(e.ContentRange) + "\r\n" : null);
                    return 0;
                }
            }
            status = up.Status;
            var h = new StringBuilder();
            h.Append("Content-Type: ").Append(CleanType(up.ContentType)).Append("\r\n");
            bool chunked = up.ContentLength < 0 && !head;
            if (chunked) h.Append("Transfer-Encoding: chunked\r\n");
            else if (up.ContentLength >= 0) h.Append("Content-Length: ").Append(up.ContentLength.ToString(Inv)).Append("\r\n");
            if (status == 206 && up.ContentRange != null) h.Append("Content-Range: ").Append(CleanHeader(up.ContentRange)).Append("\r\n");
            h.Append(status == 206 ? "Accept-Ranges: bytes\r\n" : "Accept-Ranges: none\r\n");
            SendHead(s, status, h.ToString());
            if (head) return 0;
            long sent = 0;
            byte[] buf = ReadPool.Rent();
            try
            {
                int n;
                while ((n = up.Read(buf, 0, buf.Length)) > 0)
                {
                    if (chunked)
                    {
                        byte[] len = Encoding.ASCII.GetBytes(n.ToString("x", Inv) + "\r\n");
                        SendAll(s, len, 0, len.Length);
                    }
                    SendAll(s, buf, 0, n);
                    if (chunked) SendAll(s, Crlf, 0, 2);
                    sent += n;
                }
                if (chunked)
                {
                    byte[] tail = Encoding.ASCII.GetBytes("0\r\n\r\n");
                    SendAll(s, tail, 0, tail.Length);
                }
            }
            finally { ReadPool.Return(buf); }
            return sent;
        }

        // "bytes a-b/size" or "bytes */size"; size is -1 for "*"
        public static bool ParseContentRange(string v, out long a, out long b, out long size)
        {
            a = b = size = -1;
            if (v == null) return false;
            v = v.Trim();
            if (!v.StartsWith("bytes", StringComparison.OrdinalIgnoreCase)) return false;
            v = v.Substring(5).Trim();
            int slash = v.IndexOf('/');
            if (slash < 0) return false;
            string range = v.Substring(0, slash).Trim(), total = v.Substring(slash + 1).Trim();
            if (total != "*" && !long.TryParse(total, NumberStyles.None, Inv, out size)) return false;
            if (range == "*") return size >= 0;
            int dash = range.IndexOf('-');
            if (dash < 0) return false;
            return long.TryParse(range.Substring(0, dash), NumberStyles.None, Inv, out a) &&
                   long.TryParse(range.Substring(dash + 1), NumberStyles.None, Inv, out b) && b >= a;
        }

        static string CleanType(string t)
        {
            t = CleanHeader(t);
            return t.Length == 0 ? "application/octet-stream" : t;
        }

        static string CleanHeader(string v)
        {
            if (v == null) return "";
            var sb = new StringBuilder();
            foreach (char c in v)
                if (c >= 32 && c < 127) sb.Append(c);
            return sb.ToString().Trim();
        }

        // a label for the log: status codes and error kinds, never exception messages (they can hold host:port)
        public static string Describe(Exception e)
        {
            var u = e as UpstreamError;
            if (u != null) return "status " + u.Status;
            if (e is RelayError) return e.Message;
            var se = e as SocketException;
            if (se != null) return "connection error (" + se.SocketErrorCode + ")";
            if (e is IOException)
            {
                se = e.InnerException as SocketException;
                if (se != null) return se.SocketErrorCode == SocketError.TimedOut ? "no data for 15 s" : "connection error (" + se.SocketErrorCode + ")";
                return "connection error";
            }
            if (e is ObjectDisposedException) return "connection closed";
            if (e is AuthenticationException) return "tls handshake failed";
            return e.GetType().Name;
        }

        public static string F1(double v) { return v.ToString("0.0", Inv); }

        static string F2(double v) { return v.ToString("0.00", Inv); }

        public static string Speed(double bps)
        {
            return bps >= 1048576 ? (bps / 1048576).ToString("0.0", Inv) + " MB/s" : (bps / 1024).ToString("0", Inv) + " KB/s";
        }

        static X509Certificate2 LoadPem(string path)
        {
            string text = File.ReadAllText(path);
            const string begin = "-----BEGIN CERTIFICATE-----", end = "-----END CERTIFICATE-----";
            int a = text.IndexOf(begin, StringComparison.Ordinal);
            int b = a < 0 ? -1 : text.IndexOf(end, a, StringComparison.Ordinal);
            if (b < 0) throw new RelayError("no certificate in the --insecure-test-ca file");
            return new X509Certificate2(Convert.FromBase64String(text.Substring(a + begin.Length, b - a - begin.Length)));
        }

        static void WriteReadyFile(string path, int port)
        {
            int pid = Process.GetCurrentProcess().Id;
            readyPath = Path.GetFullPath(path);
            readyText = "{\"port\":" + port.ToString(Inv) + ",\"token\":\"" + Opt.Token + "\",\"pid\":" + pid.ToString(Inv) + "}";
            Directory.CreateDirectory(Path.GetDirectoryName(readyPath));
            string tmp = readyPath + "." + pid.ToString(Inv) + ".tmp";
            File.WriteAllText(tmp, readyText, new UTF8Encoding(false));
            // replace-existing + write-through: readers see the old file or the whole new one
            if (!MoveFileEx(tmp, readyPath, 1 | 8)) throw new Win32Exception(Marshal.GetLastWin32Error());
        }

        static void DeleteReadyFile()
        {
            try
            {
                if (readyPath != null && File.Exists(readyPath) && File.ReadAllText(readyPath) == readyText) File.Delete(readyPath);
            }
            catch (Exception) { }
        }
    }
}
