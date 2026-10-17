using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Reqly.Core;
using Reqly.Inspector;
using Windows.System;

namespace Reqly.Settings;

/// <summary>
/// The Upstream Proxy page of Settings, as the Mac's: another proxy that Reqly sends its own
/// traffic through. You edit a draft; nothing changes until you click Apply, since applying
/// reconnects what's open. A draft you haven't applied stays while Settings shows other pages.
/// </summary>
public sealed partial class UpstreamProxySettingsView : UserControl
{
    private readonly ConnectionsModel connections;
    private readonly Action<WireUpstreamProxy?> keepDraft;
    private WireUpstreamProxy draft;
    private string? problem;
    private bool isShowing;
    private int checks;

    public UpstreamProxySettingsView(ConnectionsModel connections, WireUpstreamProxy? unapplied, Action<WireUpstreamProxy?> keepDraft)
    {
        this.connections = connections;
        this.keepDraft = keepDraft;
        draft = unapplied ?? connections.Connections.UpstreamProxy;
        InitializeComponent();
        ShowDraft();
        Loaded += async (_, _) =>
        {
            connections.Changed += ShowState;
            await CheckAsync(++checks);
        };
        Unloaded += (_, _) => connections.Changed -= ShowState;
    }

    private WireUpstreamProxy Saved => connections.Connections.UpstreamProxy;

    /// <summary>What the page shows, for the self-check.</summary>
    public string Describe() => $"{(draft.IsOn ? "on" : "off")} {draft.Host}:{draft.Port} · {problem ?? "no problem"} · Apply {(ApplyButton.IsEnabled ? "on" : "off")}";

    private void ShowDraft()
    {
        isShowing = true;
        IsOn.IsOn = draft.IsOn;
        Server.Text = draft.Host;
        Port.Text = draft.Port;
        Username.Text = draft.Username;
        Password.Password = draft.Password;
        Bypass.Text = draft.Bypass;
        LocalAddresses.IsOn = draft.BypassesLocalAddresses;
        isShowing = false;
        ShowState();
    }

    /// <summary>The fields on or off, what's wrong, and whether there's anything to apply.</summary>
    private void ShowState()
    {
        foreach (var field in new Control[] { Server, Port, Username, Bypass, LocalAddresses })
        {
            field.IsEnabled = draft.IsOn;
        }
        Password.IsEnabled = draft.IsOn && draft.Username.Trim().Length > 0;
        Problems.Children.Clear();
        foreach (var shown in new[] { problem, connections.Connections.Problem })
        {
            if (shown is not null)
            {
                Problems.Children.Add(Blocks.Failure(shown));
            }
        }
        var hasChanges = draft != Saved;
        RevertButton.IsEnabled = hasChanges;
        ApplyButton.IsEnabled = hasChanges && problem is null;
    }

    private void OnChanged(object sender, RoutedEventArgs e)
    {
        if (isShowing)
        {
            return;
        }
        draft = new WireUpstreamProxy
        {
            IsOn = IsOn.IsOn,
            Host = Server.Text,
            Port = Port.Text,
            Username = Username.Text,
            Password = Password.Password,
            Bypass = Bypass.Text,
            BypassesLocalAddresses = LocalAddresses.IsOn,
        };
        keepDraft(draft == Saved ? null : draft);
        ShowState();
        _ = ScheduleCheckAsync();
    }

    private async Task ScheduleCheckAsync()
    {
        var check = ++checks;
        await Task.Delay(150);
        if (check == checks)
        {
            await CheckAsync(check);
        }
    }

    private async Task CheckAsync(int check)
    {
        string? found;
        try
        {
            found = await connections.CheckUpstreamProxyAsync(draft);
        }
        catch (CoreProblem failure)
        {
            AppLog.Write($"couldn't check the upstream proxy: {failure.Message}");
            return;
        }
        if (check == checks)
        {
            problem = found;
            ShowState();
        }
    }

    private void OnFieldKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Enter && ApplyButton.IsEnabled)
        {
            e.Handled = true;
            _ = ApplyAsync();
        }
    }

    private void OnRevertClicked(object sender, RoutedEventArgs e)
    {
        draft = Saved;
        keepDraft(null);
        problem = null;
        ShowDraft();
    }

    private void OnApplyClicked(object sender, RoutedEventArgs e) => _ = ApplyAsync();

    public async Task ApplyAsync()
    {
        if (await connections.SetUpstreamProxyAsync(draft) is { } failure)
        {
            problem = failure;
            ShowState();
            return;
        }
        // The draft starts again from what was saved, without the bypass entries that weren't hosts.
        draft = Saved;
        keepDraft(null);
        ShowDraft();
    }
}
