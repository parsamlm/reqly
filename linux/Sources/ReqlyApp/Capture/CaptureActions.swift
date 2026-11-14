import CGtk
import CoreInterface
import GtkBinding

extension AppModel {
    /// Starts or stops capturing, one change at a time. Starting points your desktop's proxy at
    /// Reqly, unless the run says not to; stopping puts yours back.
    func setCapturing(_ on: Bool) async {
        await changeCapturing { [self] in await switchCapturing(on) }
    }

    private func switchCapturing(_ on: Bool) async {
        guard let session, on != isCapturing else { return }
        if on {
            capture = .starting
            do {
                let listening = try await session.startCapturing(port: port)
                // Which desktop's setting now points at Reqly, before the status line says so.
                await desktopProxy.captureStarted(port: listening)
                listeningPort = listening
                capture = .capturing
                problem = nil
            } catch {
                capture = .stopped
                problem = error.code == .portInUse ? "Reqly couldn't start capturing. \(error.message)" : error.message
            }
        } else {
            capture = .stopping
            do {
                try await session.stopCapturing()
                desktopProxy.captureStopped()
                capture = .stopped
                listeningPort = nil
                problem = nil
            } catch {
                // Your setting still points at Reqly, so it goes on capturing.
                capture = .capturing
                problem = error.message
            }
        }
    }

    /// What the status line says: the port and which desktop's proxy setting points at Reqly, as
    /// on Windows, with what to do for apps to follow it, or what went wrong.
    var statusText: String {
        let stoppedAfterGNOME = capture == .stopped && desktopProxy.stoppedAfterSettingGNOME
        return CaptureStatus(
            capture: capture, port: port, problem: problem,
            proxySet: capture == .capturing ? desktopProxy.proxySet : [], chrome: desktopProxy.chrome,
            terminalsKeepingProxy: stoppedAfterGNOME ? desktopProxy.terminalsFollowingGNOME : [],
            openedTerminalsKeepProxy: capture == .stopped && desktopProxy.hasStopped && openedTerminal
        ).text
    }
}

extension MainWindow {
    /// A click on the capture switch gives it the keyboard's focus, which GTK leaves where it was
    /// on some desktops, such as KDE's and Cinnamon's, so Space and Tab go on from the switch.
    func focusCaptureSwitchOnClick() {
        let captureSwitch = captureSwitch
        let click = gtk_gesture_click_new()!
        gtk_event_controller_set_propagation_phase(cast(click), GTK_PHASE_CAPTURE)
        connect(click, "pressed") {
            if gtk_widget_get_sensitive(captureSwitch) != 0 {
                gtk_widget_grab_focus(captureSwitch)
            }
        }
        gtk_widget_add_controller(captureSwitch, cast(click))
    }

    /// You turned the capture switch on or off, with the pointer or the keyboard. The switch
    /// can't be used while capturing starts or stops, and has the keyboard's focus again after.
    func captureSwitched(on: Bool) {
        let hadFocus = gtk_widget_is_focus(captureSwitch) != 0
        let says = saysCapturing
        saysCapturing = false
        Task {
            await appModel.setCapturing(on)
            if hadFocus, gtk_widget_get_sensitive(captureSwitch) != 0 {
                gtk_widget_grab_focus(captureSwitch)
            }
            // Ctrl+R, away from the switch, which screen readers would have said.
            if says, gtk_widget_is_focus(captureSwitch) == 0 {
                announce(window, appModel.statusText)
            }
        }
    }
}
