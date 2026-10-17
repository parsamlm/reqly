using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography.X509Certificates;
using System.Text;

namespace Reqly.Smoke;

/// <summary>
/// A server for the self-check's speed part, on this PC's loopback address only. It keeps each
/// connection open for the next request, as most servers do, and answers <c>/small</c> with a
/// little JSON and <c>/bytes?n=N</c> with N bytes. Given a certificate, it speaks HTTPS.
/// </summary>
public sealed class SpeedServer : IDisposable
{
    private static readonly byte[] Small = Encoding.UTF8.GetBytes(
        """{"city":"Lisbon","sky":"clear","wind":"light","temperature":21,"humidity":0.52,"days":[{"sky":"clear"},{"sky":"rain"},{"sky":"clouds"}]}""");
    private static readonly byte[] Chunk = Enumerable.Repeat((byte)'x', 64 << 10).ToArray();

    private readonly TcpListener listener;
    private readonly X509Certificate2? certificate;

    public SpeedServer(X509Certificate2? certificate = null)
    {
        this.certificate = certificate;
        listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start(512);
        _ = AcceptAsync();
    }

    public int Port => ((IPEndPoint)listener.LocalEndpoint).Port;

    public void Dispose() => listener.Stop();

    private async Task AcceptAsync()
    {
        while (true)
        {
            TcpClient client;
            try
            {
                client = await listener.AcceptTcpClientAsync();
            }
            catch (Exception error) when (error is SocketException or ObjectDisposedException or InvalidOperationException)
            {
                return;
            }
            _ = ServeAsync(client);
        }
    }

    private async Task ServeAsync(TcpClient client)
    {
        try
        {
            using (client)
            {
                client.NoDelay = true;
                Stream stream = client.GetStream();
                if (certificate is not null)
                {
                    var tls = new SslStream(stream);
                    await tls.AuthenticateAsServerAsync(new SslServerAuthenticationOptions
                    {
                        ServerCertificate = certificate,
                        ApplicationProtocols = [SslApplicationProtocol.Http11],
                    });
                    stream = tls;
                }
                await using (stream)
                {
                    var pending = new List<byte>();
                    var buffer = new byte[8192];
                    while (true)
                    {
                        // A request: its head, up to the blank line. These have no bodies.
                        int end;
                        while ((end = HeadEnd(pending)) < 0)
                        {
                            var count = await stream.ReadAsync(buffer);
                            if (count == 0)
                            {
                                return;
                            }
                            pending.AddRange(buffer.AsSpan(0, count));
                        }
                        var head = Encoding.ASCII.GetString([.. pending.Take(end)]);
                        pending.RemoveRange(0, end + 4);
                        await AnswerAsync(stream, head.Split(' ', 3).ElementAtOrDefault(1) ?? "/");
                    }
                }
            }
        }
        catch (Exception error) when (error is IOException or AuthenticationException or SocketException or ObjectDisposedException)
        {
            // The client went, as clients do once they're done.
        }
    }

    private static async Task AnswerAsync(Stream stream, string target)
    {
        var isBytes = target.StartsWith("/bytes");
        long length = Small.Length;
        if (isBytes && target.Split("n=").ElementAtOrDefault(1) is { } number)
        {
            length = long.Parse(number.Split('&')[0]);
        }
        var head = $"HTTP/1.1 200 OK\r\nContent-Type: {(isBytes ? "application/octet-stream" : "application/json")}\r\n" +
            $"Content-Length: {length}\r\n\r\n";
        await stream.WriteAsync(Encoding.ASCII.GetBytes(head));
        if (!isBytes)
        {
            await stream.WriteAsync(Small);
        }
        for (var left = isBytes ? length : 0; left > 0; left -= Chunk.Length)
        {
            await stream.WriteAsync(Chunk.AsMemory(0, (int)Math.Min(left, Chunk.Length)));
        }
        await stream.FlushAsync();
    }

    /// <summary>Where the head's blank line starts, or -1 before it has come.</summary>
    private static int HeadEnd(List<byte> bytes)
    {
        for (var index = 0; index + 3 < bytes.Count; index++)
        {
            if (bytes[index] == '\r' && bytes[index + 1] == '\n' && bytes[index + 2] == '\r' && bytes[index + 3] == '\n')
            {
                return index;
            }
        }
        return -1;
    }
}
