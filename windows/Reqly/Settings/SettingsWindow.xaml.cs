using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Reqly.Core;
using Reqly.Https;
using Windows.Graphics;

namespace Reqly.Settings;

/// <summary>Reqly's settings, in a window of their own, as on the Mac.</summary>
public sealed partial class SettingsWindow : Window
{
    /// <summary>The pages, so other windows can open Settings on the one they mean.</summary>
    public enum Pane
    {
        General,
        Https,
        UpstreamProxy,
        ReverseProxy,
        ClientCertificates,
        Protobuf,
    }

    private readonly HttpsModel https;
    private readonly MainWindow main;
    private readonly ConnectionsModel? connections;
    /// <summary>Upstream proxy settings you haven't applied, kept while another page shows.</summary>
    private WireUpstreamProxy? upstreamDraft;

    public SettingsWindow(HttpsModel https, MainWindow main, ConnectionsModel? connections)
    {
        this.https = https;
        this.main = main;
        this.connections = connections;
        InitializeComponent();
        AppWindow.Resize(new SizeInt32(900, 700));
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "Reqly.ico"));
        WindowLayout.MatchTitleBar(AppWindow);
        Navigation.SelectedItem = GeneralItem;
    }

    /// <summary>The window's contents, for the self-check's picture of it.</summary>
    public UIElement View => Root;

    public void Show(Pane pane) => Navigation.SelectedItem = pane switch
    {
        Pane.Https => HttpsItem,
        Pane.UpstreamProxy => UpstreamProxyItem,
        Pane.ReverseProxy => ReverseProxyItem,
        Pane.ClientCertificates => ClientCertificatesItem,
        Pane.Protobuf => ProtobufItem,
        _ => GeneralItem,
    };

    /// <summary>The page that shows, for the self-check.</summary>
    public UIElement? PageView => Page.Content as UIElement;

    private void OnPageChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.SelectedItem is not NavigationViewItem item)
        {
            return;
        }
        PageTitle.Text = (string)item.Content;
        var window = () => WinRT.Interop.WindowNative.GetWindowHandle(this);
        Page.Content = (item.Tag as string, connections) switch
        {
            ("https", _) => new HttpsSettingsView(https),
            ("upstreamProxy", { } model) => new UpstreamProxySettingsView(model, upstreamDraft, draft => upstreamDraft = draft),
            ("reverseProxy", { } model) => new ReverseProxySettingsView(model, () => main.CapturingPort is not null),
            ("clientCertificates", { } model) => new ClientCertificateSettingsView(model, window),
            ("protobuf", _) when main.Protobuf is { } protobuf => new ProtobufSettingsView(protobuf, window),
            _ => (UIElement)new GeneralSettingsView(main),
        };
    }
}
