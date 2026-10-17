using System.Diagnostics;
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
using Microsoft.UI.Dispatching;
using Reqly.Smoke;

namespace Reqly;

/// <summary>
/// The self-check's speed part, with <c>--smoke-parts speed</c>, for release builds: the same
/// traffic goes straight to a server on this PC and through Reqly, which records all of it as it
/// records any traffic, to see what Reqly costs it. Meanwhile the window's thread is timed, to see
/// that the window keeps up, and the list, to see how soon the requests show.
/// </summary>
public sealed partial class MainWindow
{
    private async Task CheckSpeedAsync(string path)
    {
        if (capturingPort is not int port || https is null || testServer is null || options.RootStandIn is null)
        {
            Log("speed: not checked, since this run isn't capturing with a stand-in certificate");
            return;
        }
        await https.SetUpAsync();
        await https.AddHostAsync("localhost");
        using var root = X509CertificateLoader.LoadCertificate(https.CertificateForDevices!);
        using var plain = new SpeedServer();
        using var secure = new SpeedServer(testServer.Certificate);
        var http = $"http://127.0.0.1:{plain.Port}";
        var tls = $"https://localhost:{secure.Port}";
        X509Certificate2[] direct = [testServer.Authority];
        X509Certificate2[] decrypted = [root];
        Log($"speed: {Environment.ProcessorCount} processors, memory {Megabytes()} MB, {list?.Total ?? 0} requests in the list");

        var watch = new ThreadWatch(DispatcherQueue);
        await CompareAsync("small requests, one at a time", http + "/small", 2000, 1, direct, direct, port);
        await CompareAsync("small requests, 16 at a time", http + "/small", 4000, 16, direct, direct, port);
        await CompareAsync("100 MB download", http + $"/bytes?n={100 << 20}", 3, 1, direct, direct, port);
        await CompareAsync("HTTPS, decrypted: small requests, one at a time", tls + "/small", 1000, 1, direct, decrypted, port);
        await CompareAsync("HTTPS, decrypted: small requests, 16 at a time", tls + "/small", 2000, 16, direct, decrypted, port);
        await CompareAsync("HTTPS, decrypted: 50 MB download", tls + $"/bytes?n={50 << 20}", 3, 1, direct, decrypted, port);
        await https.StopDecryptingAsync("localhost");
        await CompareAsync("HTTPS, not decrypted: small requests, one at a time", tls + "/small", 1000, 1, direct, direct, port);
        await CompareAsync("HTTPS, not decrypted: 50 MB download", tls + $"/bytes?n={50 << 20}", 3, 1, direct, direct, port);
        var (longest, stalls, ticks) = watch.Stop();
        Log($"speed: the window's thread, all along: longest wait {longest:F0} ms, {stalls} waits over 100 ms in {ticks} checks");
        Log($"speed: memory {Megabytes()} MB, {list?.Total ?? 0} requests in the list");
        await SaveScreenshotAsync(Root, path + ".speed.png");
        await https.RemoveAsync();
    }

    /// <summary>
    /// Sends the requests straight to the server, then through Reqly, and says how fast each way
    /// went, and how soon the list showed the ones through Reqly.
    /// </summary>
    private async Task CompareAsync(string name, string url, int requests, int parallel, X509Certificate2[] trustedDirect, X509Certificate2[] trustedThroughReqly, int port)
    {
        // Each way a little first, so neither pays for starting up.
        using var straight = SpeedClient(null, trustedDirect, parallel);
        using var through = SpeedClient(port, trustedThroughReqly, parallel);
        var warmUp = requests >= 20 ? 20 : 1;
        await SendAsync(straight, url, warmUp, Math.Min(parallel, warmUp));
        await SendAsync(through, url, warmUp, Math.Min(parallel, warmUp));
        await SettleAsync();

        var before = list?.Total ?? 0;
        var straightRun = await SendAsync(straight, url, requests, parallel);
        var watch = new ThreadWatch(DispatcherQueue);
        var collected = GcSnapshot.Now();
        var throughRun = await SendAsync(through, url, requests, parallel);
        var (longest, stalls, _) = watch.Stop();
        var collections = collected.Since();
        // From the last response until the list stops growing.
        var shown = await SettleAsync();
        var rows = (list?.Total ?? 0) - before;
        Log($"speed: {name}: straight {straightRun.Describe(requests)} · through Reqly {throughRun.Describe(requests)}" +
            $" · {rows} new rows, the last {shown:F0} ms after the last response" +
            $" · window's thread: longest wait {longest:F0} ms, {stalls} over 100 ms · {collections}");
    }

    /// <summary>
    /// The self-check's serve part, with <c>--smoke-parts serve</c>: Reqly captures while the
    /// traffic comes from another program, such as the core's speed probe, so nothing else in
    /// this process adds to what's timed; with <c>serve,decrypt</c>, it decrypts 127.0.0.1 too. It
    /// says it's ready in <c>&lt;report&gt;.ready</c>, and stops once <c>&lt;report&gt;.done</c>
    /// appears. Meanwhile the window's thread is timed.
    /// </summary>
    private async Task ServeAsync(string path)
    {
        if (capturingPort is not int port || https is null || options.RootStandIn is null)
        {
            Log("serve: not served, since this run isn't capturing with a stand-in certificate");
            return;
        }
        var decrypts = options.SmokeParts?.Contains("decrypt") == true;
        if (decrypts)
        {
            await https.SetUpAsync();
            Log($"serve: decrypting 127.0.0.1: {await https.AddHostAsync("127.0.0.1") ?? "yes"}");
        }
        // Whether the window is in front, since Windows slows what isn't, unless it's capturing.
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        Log($"serve: in front at the start: {GetForegroundWindow() == hwnd}");
        var watch = new ThreadWatch(DispatcherQueue);
        var collected = GcSnapshot.Now();
        File.WriteAllText(path + ".ready", port.ToString());
        var waited = Stopwatch.StartNew();
        while (!File.Exists(path + ".done") && waited.Elapsed < TimeSpan.FromMinutes(10))
        {
            await Task.Delay(200);
        }
        var (longest, stalls, ticks) = watch.Stop();
        Log($"serve: in front at the end: {GetForegroundWindow() == hwnd}");
        Log($"serve: {list?.Total ?? 0} requests in the list, memory {Megabytes()} MB · the window's thread: longest wait {longest:F0} ms, " +
            $"{stalls} waits over 100 ms in {ticks} checks · {collected.Since()}");
        await SaveScreenshotAsync(Root, path + ".serve.png");
        if (decrypts)
        {
            await https.RemoveAsync();
        }
    }

    /// <summary>How often .NET has collected garbage, which pauses this process's .NET threads, and for how long in all.</summary>
    private readonly record struct GcSnapshot(int Young, int Middle, int Old, TimeSpan Paused)
    {
        public static GcSnapshot Now() =>
            new(GC.CollectionCount(0), GC.CollectionCount(1), GC.CollectionCount(2), GC.GetTotalPauseDuration());

        public string Since()
        {
            var now = Now();
            return $".NET collected garbage {now.Young - Young} times ({now.Middle - Middle} gen 1, {now.Old - Old} gen 2), " +
                $"pausing {(now.Paused - Paused).TotalMilliseconds:F0} ms in all";
        }
    }

    private sealed record SpeedRun(TimeSpan Total, double[] Times, long Bytes, int Failures)
    {
        public string Describe(int requests)
        {
            var sorted = Times.Where(time => time > 0).Order().ToArray();
            double At(double share) => sorted.Length == 0 ? 0 : sorted[Math.Min(sorted.Length - 1, (int)(sorted.Length * share))];
            var failures = Failures > 0 ? $", {Failures} failed" : "";
            if (Bytes > 10L << 20)
            {
                return $"{Bytes / Total.TotalSeconds / (1 << 20):F0} MB/s{failures}";
            }
            return $"{requests / Total.TotalSeconds:F0}/s, {At(0.5):F2} ms each, {At(0.95):F2} ms for the slowest 5%{failures}";
        }
    }

    /// <summary>Sends `requests` GETs, `parallel` at a time, off the window's thread, reading each body to its end.</summary>
    private static async Task<SpeedRun> SendAsync(HttpClient client, string url, int requests, int parallel)
    {
        var times = new double[requests];
        long bytes = 0;
        var failures = 0;
        var next = -1;
        var total = Stopwatch.StartNew();
        await Task.WhenAll(Enumerable.Range(0, parallel).Select(_ => Task.Run(async () =>
        {
            var buffer = new byte[81920];
            int index;
            while ((index = Interlocked.Increment(ref next)) < requests)
            {
                var one = Stopwatch.StartNew();
                try
                {
                    using var response = await client.GetAsync(url, HttpCompletionOption.ResponseHeadersRead);
                    response.EnsureSuccessStatusCode();
                    await using var body = await response.Content.ReadAsStreamAsync();
                    long size = 0;
                    int read;
                    while ((read = await body.ReadAsync(buffer)) > 0)
                    {
                        size += read;
                    }
                    Interlocked.Add(ref bytes, size);
                    times[index] = one.Elapsed.TotalMilliseconds;
                }
                catch (Exception error) when (error is HttpRequestException or IOException or TaskCanceledException)
                {
                    Interlocked.Increment(ref failures);
                }
            }
        })));
        return new SpeedRun(total.Elapsed, times, bytes, failures);
    }

    /// <summary>A client straight to the server, or through Reqly on `port`, trusting only the certificates given.</summary>
    private static HttpClient SpeedClient(int? port, X509Certificate2[] trusted, int parallel)
    {
        var handler = new SocketsHttpHandler
        {
            UseProxy = port is not null,
            Proxy = port is int through ? new WebProxy($"http://127.0.0.1:{through}") : null,
            MaxConnectionsPerServer = parallel,
            PooledConnectionLifetime = TimeSpan.FromMinutes(5),
        };
        handler.SslOptions.RemoteCertificateValidationCallback = (_, certificate, _, errors) =>
        {
            if (certificate is null)
            {
                return false;
            }
            using var chain = new X509Chain();
            chain.ChainPolicy.TrustMode = X509ChainTrustMode.CustomRootTrust;
            chain.ChainPolicy.CustomTrustStore.AddRange(trusted);
            chain.ChainPolicy.RevocationMode = X509RevocationMode.NoCheck;
            var server = certificate as X509Certificate2 ?? X509CertificateLoader.LoadCertificate(certificate.GetRawCertData());
            return chain.Build(server) && (errors & ~SslPolicyErrors.RemoteCertificateChainErrors) == 0;
        };
        return new HttpClient(handler, disposeHandler: true) { Timeout = TimeSpan.FromSeconds(60) };
    }

    /// <summary>Waits until the list has stopped growing for half a second, and returns when it last grew, in ms from now.</summary>
    private async Task<double> SettleAsync()
    {
        var watch = Stopwatch.StartNew();
        var last = list?.Total ?? 0;
        var changed = watch.Elapsed;
        while (watch.Elapsed - changed < TimeSpan.FromMilliseconds(500) && watch.Elapsed < TimeSpan.FromSeconds(60))
        {
            await Task.Delay(20);
            if ((list?.Total ?? 0) != last)
            {
                last = list?.Total ?? 0;
                changed = watch.Elapsed;
            }
        }
        return changed.TotalMilliseconds;
    }

    private static long Megabytes()
    {
        using var process = Process.GetCurrentProcess();
        return process.WorkingSet64 >> 20;
    }

    /// <summary>
    /// Times the window's thread: a timer asks it every 16 ms, a frame, and each wait longer than
    /// that is how long the window couldn't answer you.
    /// </summary>
    private sealed class ThreadWatch
    {
        private readonly DispatcherQueueTimer timer;
        private readonly Stopwatch clock = Stopwatch.StartNew();
        private double last;
        private double longest;
        private int stalls;
        private int ticks;

        public ThreadWatch(DispatcherQueue queue)
        {
            timer = queue.CreateTimer();
            timer.Interval = TimeSpan.FromMilliseconds(16);
            timer.Tick += (_, _) =>
            {
                var now = clock.Elapsed.TotalMilliseconds;
                var waited = now - last - 16;
                last = now;
                ticks++;
                longest = Math.Max(longest, waited);
                if (waited > 100)
                {
                    stalls++;
                }
            };
            timer.Start();
        }

        public (double Longest, int Stalls, int Ticks) Stop()
        {
            timer.Stop();
            return (Math.Max(0, longest), stalls, ticks);
        }
    }
}
