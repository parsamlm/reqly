using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Graphics;

namespace Reqly.Devices;

/// <summary>The Devices window, as the Mac's: phones and tablets on the network, and Android emulators.</summary>
public sealed partial class DevicesWindow : Window
{
    private readonly MainWindow main;
    private readonly DevicesModel devices;

    public DevicesWindow(MainWindow main, DevicesModel devices)
    {
        this.main = main;
        this.devices = devices;
        InitializeComponent();
        AppWindow.Resize(new SizeInt32(960, 760));
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "Reqly.ico"));
        WindowLayout.MatchTitleBar(AppWindow);
        Navigation.SelectedItem = PhonesItem;
    }

    /// <summary>The window's contents, for the self-check's picture of it.</summary>
    public UIElement View => Root;

    public UIElement? PageView => Page.Content as UIElement;

    public void ShowEmulators() => Navigation.SelectedItem = EmulatorsItem;

    private void OnSectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.SelectedItem is not NavigationViewItem item)
        {
            return;
        }
        PageTitle.Text = (string)item.Content;
        Page.Content = item.Tag as string == "emulators"
            ? new EmulatorsView(main)
            : new PhonesView(main, devices, () => WinRT.Interop.WindowNative.GetWindowHandle(this));
    }
}
