using System.IO.Compression;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;

namespace Reqly.Smoke;

/// <summary>
/// An HTTPS server for the self-check, on this PC's loopback address only, so nothing on the
/// network can reach it. Its certificate comes from a test authority made for the run, which only
/// this run of Reqly trusts; Windows never does.
/// </summary>
public sealed class TestTlsServer : IDisposable
{
    private readonly TcpListener listener;
    private readonly X509Certificate2 certificate;

    /// <summary>The test authority, which issued the server's certificate.</summary>
    public X509Certificate2 Authority { get; }
    /// <summary>The server's certificate, for localhost, with its key, which the speed part's server uses too.</summary>
    public X509Certificate2 Certificate => certificate;
    public int Port => ((IPEndPoint)listener.LocalEndpoint).Port;

    private TestTlsServer(X509Certificate2 authority, X509Certificate2 certificate)
    {
        Authority = authority;
        this.certificate = certificate;
        listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        _ = AcceptAsync();
    }

    public static TestTlsServer Start()
    {
        var now = DateTimeOffset.UtcNow;
        using var authorityKey = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var authorityRequest = new CertificateRequest(
            "CN=Reqly Self-Check Authority", authorityKey, HashAlgorithmName.SHA256);
        authorityRequest.CertificateExtensions.Add(new X509BasicConstraintsExtension(true, false, 0, true));
        authorityRequest.CertificateExtensions.Add(
            new X509KeyUsageExtension(X509KeyUsageFlags.KeyCertSign | X509KeyUsageFlags.CrlSign, true));
        authorityRequest.CertificateExtensions.Add(
            new X509SubjectKeyIdentifierExtension(authorityRequest.PublicKey, false));
        var authority = authorityRequest.CreateSelfSigned(now.AddDays(-1), now.AddDays(7));

        using var serverKey = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var serverRequest = new CertificateRequest("CN=localhost", serverKey, HashAlgorithmName.SHA256);
        var names = new SubjectAlternativeNameBuilder();
        names.AddDnsName("localhost");
        serverRequest.CertificateExtensions.Add(names.Build());
        serverRequest.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
        serverRequest.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature, true));
        serverRequest.CertificateExtensions.Add(
            new X509EnhancedKeyUsageExtension(new OidCollection { new Oid("1.3.6.1.5.5.7.3.1") }, false));
        serverRequest.CertificateExtensions.Add(
            X509AuthorityKeyIdentifierExtension.CreateFromCertificate(authority, true, false));
        var serial = RandomNumberGenerator.GetBytes(16);
        serial[0] &= 0x7F;
        using var issued = serverRequest.Create(authority, now.AddHours(-1), now.AddDays(7), serial);
        using var withKey = issued.CopyWithPrivateKey(serverKey);
        // Windows' TLS looks the key up by name, which loading a PFX gives it. The key is deleted
        // again when the certificate is disposed.
        var certificate = X509CertificateLoader.LoadPkcs12(withKey.Export(X509ContentType.Pfx), null);
        return new TestTlsServer(authority, certificate);
    }

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

    /// <summary>Answers one request with a little JSON, then closes the connection.</summary>
    private async Task ServeAsync(TcpClient client)
    {
        try
        {
            using (client)
            await using (var tls = new SslStream(client.GetStream()))
            {
                await tls.AuthenticateAsServerAsync(new SslServerAuthenticationOptions
                {
                    ServerCertificate = certificate,
                    ApplicationProtocols = [SslApplicationProtocol.Http11],
                });
                var head = new StringBuilder();
                var buffer = new byte[4096];
                while (!head.ToString().Contains("\r\n\r\n"))
                {
                    var count = await tls.ReadAsync(buffer);
                    if (count == 0)
                    {
                        return;
                    }
                    head.Append(Encoding.ASCII.GetString(buffer, 0, count));
                }
                // A page for each kind of status, for the list's dots and filters, a protobuf one, and
                // one packed with Brotli.
                var target = head.ToString().Split(' ', 3).ElementAtOrDefault(1) ?? "/";
                var (status, body, extra) = target switch
                {
                    _ when target.Contains("missing") => ("404 Not Found", """{"error":"No city by that name"}""", ""),
                    _ when target.Contains("broken") => ("500 Internal Server Error", """{"error":"The forecast is late"}""", ""),
                    _ when target.Contains("moved") => ("302 Found", "", "Location: /v1/forecast?city=Lisbon\r\n"),
                    _ => ("200 OK", """{"city":"Lisbon","sky":"clear","wind":"light"}""", ""),
                };
                var contentType = "application/json";
                var bytes = Encoding.UTF8.GetBytes(body);
                if (target.Contains("proto"))
                {
                    // A weather.v1.Forecast: city "Tehran" (field 1) and days 3 (field 2).
                    contentType = "application/x-protobuf";
                    bytes = [0x0A, 0x06, .. Encoding.ASCII.GetBytes("Tehran"), 0x10, 0x03];
                }
                if (target.Contains("brotli"))
                {
                    // Packed the way many servers send their pages, so the details have to unpack it.
                    bytes = Brotli(bytes);
                    extra += "Content-Encoding: br\r\n";
                }
                var response =
                    $"HTTP/1.1 {status}\r\nContent-Type: {contentType}\r\n{extra}" +
                    $"Content-Length: {bytes.Length}\r\nConnection: close\r\n\r\n";
                await tls.WriteAsync(Encoding.ASCII.GetBytes(response));
                await tls.WriteAsync(bytes);
                await tls.FlushAsync();
                await tls.ShutdownAsync();
            }
        }
        catch (Exception error) when (error is IOException or AuthenticationException or SocketException or ObjectDisposedException)
        {
            AppLog.Write($"self-check server: {error.Message}");
        }
    }

    private static byte[] Brotli(byte[] data)
    {
        using var packed = new MemoryStream();
        using (var brotli = new BrotliStream(packed, CompressionLevel.Optimal))
        {
            brotli.Write(data);
        }
        return packed.ToArray();
    }

    public void Dispose()
    {
        listener.Stop();
        certificate.Dispose();
        Authority.Dispose();
    }
}
