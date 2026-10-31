import CoreInterface

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
                listeningPort = try await session.startCapturing(port: port)
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
                capture = .stopped
                listeningPort = nil
                problem = nil
            } catch {
                capture = .capturing
                problem = error.message
            }
        }
    }

    /// What the status line says, as on Windows.
    var statusText: String {
        if let problem {
            return problem
        }
        switch capture {
        case .capturing:
            return "Capturing on port \(port)" + (options.setsSystemProxy ? "" : " · Desktop proxy not set")
        case .starting: return "Starting…"
        case .stopping: return "Stopping…"
        case .stopped: return "Not capturing · Port \(port)"
        }
    }
}

extension MainWindow {
    /// You turned the capture switch on or off.
    func captureSwitched(on: Bool) {
        Task { await model.setCapturing(on) }
    }
}
