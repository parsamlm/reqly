import DeviceTools
import ReqlyModel
import SwiftUI

/// Getting phones, tablets, simulators and emulators to send their traffic through Reqly.
struct DevicesWindow: View {
    enum Pane: String, CaseIterable, Identifiable {
        case network, simulators, emulators

        var id: Self { self }

        var title: String {
            switch self {
            case .network: "Phones and Tablets"
            case .simulators: "Simulators"
            case .emulators: "Android Emulators"
            }
        }

        var symbol: String {
            switch self {
            case .network: "iphone"
            case .simulators: "macbook.and.iphone"
            case .emulators: "smartphone"
            }
        }
    }

    @State private var pane: Pane? = Self.firstPane

    private static var firstPane: Pane {
        #if DEBUG
            if let name = UserDefaults.standard.string(forKey: DefaultsKey.showDevices), let pane = Pane(rawValue: name)
            {
                return pane
            }
        #endif
        return .network
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                ForEach(Pane.allCases) { pane in
                    Label(pane.title, systemImage: pane.symbol)
                        .tag(pane)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            Group {
                switch pane ?? .network {
                case .network: NetworkDevicesPane()
                case .simulators: SimulatorsPane()
                case .emulators: EmulatorsPane()
                }
            }
            .navigationSplitViewColumnWidth(min: 520, ideal: 620)
        }
        .navigationTitle((pane ?? .network).title)
    }
}

/// The port devices connect to: the one Reqly listens on while it captures, or the one it will.
private extension CaptureModel {
    var devicePort: Int {
        if case .capturing(let listening) = status { listening } else { port }
    }
}

// MARK: - Phones and tablets

private struct NetworkDevicesPane: View {
    @Environment(DevicesModel.self) private var devices
    @Environment(CaptureModel.self) private var capture
    @Environment(HTTPSModel.self) private var https
    @Environment(\.openWindow) private var openWindow
    @State private var addresses: [NetworkAddress] = []

    var body: some View {
        Form {
            if let problem = devices.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Section {
                Toggle(
                    isOn: Binding(get: { devices.allowsNetworkDevices }, set: { devices.setAllowsNetworkDevices($0) })
                ) {
                    Text("Allow Devices on This Network")
                    Text(
                        "Phones and tablets on the same Wi-Fi as this Mac can send their traffic through Reqly. Reqly asks before it lets a new device in."
                    )
                }
                .toggleStyle(.switch)
            }
            if !devices.requests.isEmpty {
                Section("Waiting for You") {
                    ForEach(devices.requests) { request in
                        HStack {
                            Label("A device at \(request.address)", systemImage: "iphone.radiowaves.left.and.right")
                            Spacer()
                            Button("Don't Allow") { devices.decide(request, allow: false) }
                            Button("Allow") { devices.decide(request, allow: true) }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
            if devices.allowsNetworkDevices {
                setUp
            }
            Section {
                if devices.known.isEmpty {
                    Text("The devices you let in show up here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(devices.known) { device in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(devices.names[device.id] ?? device.address)
                            Text(details(of: device))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Forget") { devices.forget(device.id) }
                            .help("Reqly asks again the next time this device connects.")
                    }
                }
            } header: {
                Text("Devices You Let In")
            } footer: {
                Text(
                    "The first time devices connect, macOS may ask whether Reqly can accept incoming network connections. Choose Allow, or they can't connect."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            // The Mac can join another network while the window is open.
            while !Task.isCancelled {
                addresses = NetworkAddress.current()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    @ViewBuilder
    private var setUp: some View {
        if let primary = addresses.first {
            Section {
                SetupCode(url: "http://\(primary.address):\(capture.devicePort)/")
                if !capture.isCapturing {
                    HStack {
                        Label("Start capturing, so devices can connect.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Start Capturing") { capture.toggle() }
                            .disabled(capture.isBusy)
                    }
                }
                if https.certificateForDevices == nil {
                    HStack {
                        Label("Set up HTTPS to see the devices' HTTPS traffic.", systemImage: "lock.open")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Set Up HTTPS…") {
                            openWindow(id: "main")
                            https.showSetup()
                        }
                    }
                } else if let certificate = https.certificateDetails {
                    CurrentCertificate(name: certificate.name)
                }
            } header: {
                Text("Set Up a Device")
            }
            Section {
                LabeledContent("Server") {
                    Text(primary.address).font(.body.monospaced()).textSelection(.enabled)
                }
                LabeledContent("Port") {
                    Text(String(capture.devicePort)).font(.body.monospaced()).textSelection(.enabled)
                }
                ForEach(addresses.dropFirst()) { other in
                    LabeledContent("On \(other.name)") {
                        Text(other.address).font(.body.monospaced()).textSelection(.enabled)
                    }
                }
            } header: {
                Text("Proxy Settings")
            } footer: {
                Text(
                    "On the device, enter these in the Wi-Fi network's proxy settings, under Manual. Set the proxy back to Off when you're done."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        } else {
            Section {
                Label("This Mac isn't on a network that devices can reach.", systemImage: "wifi.slash")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func details(of device: DevicesModel.Known) -> String {
        if device.id.hasPrefix("mac:") {
            return "\(device.address) · \(device.id.dropFirst(4))"
        }
        return device.address
    }
}

/// The address devices open to set themselves up, as a QR code and as text.
private struct SetupCode: View {
    let url: String

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            if let image = QRCode.image(for: url) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 128, height: 128)
                    .padding(8)
                    // A QR code reads best dark on light, whatever the appearance.
                    .background(.white, in: .rect(cornerRadius: 10))
                    .accessibilityLabel("QR code for \(url)")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("On the device, scan the code with the camera, or open this address in its browser:")
                HStack(spacing: 6) {
                    Text(url)
                        .font(.title3.monospaced())
                        .textSelection(.enabled)
                    Button("Copy Address", systemImage: "doc.on.doc") {
                        Pasteboard.copy(url)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Copy Address")
                }
                Text("The page there has Reqly's certificate, and the steps for iPhone, iPad and Android.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}

/// Which certificate devices need, since a device keeps the one it was given.
private struct CurrentCertificate: View {
    let name: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("Devices need Reqly's current certificate, “\(name)”.")
                Text(
                    "A device that trusted an earlier Reqly certificate rejects this one. Open the page above on it, install the certificate, and trust it again."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: "checkmark.seal")
                .foregroundStyle(.tint)
        }
    }
}

// MARK: - Simulators

private struct SimulatorsPane: View {
    @Environment(SimulatorsModel.self) private var simulators
    @Environment(HTTPSModel.self) private var https
    @Environment(CaptureModel.self) private var capture

    var body: some View {
        Form {
            Section {
                Text(
                    "Simulators use this Mac's network settings, so their traffic shows up while Reqly captures. To see their HTTPS traffic, install Reqly's certificate in each one."
                )
                if !capture.setsSystemProxy {
                    Label(
                        "Reqly isn't setting the Mac's proxy, so simulators don't reach it.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                }
            }
            Section {
                if let problem = simulators.problem {
                    Text(problem).foregroundStyle(.secondary)
                } else if simulators.simulators.isEmpty {
                    Text("No simulators are running. Start one from Xcode or the Simulator app.")
                        .foregroundStyle(.secondary)
                }
                ForEach(simulators.simulators) { simulator in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(simulator.name)
                            Text(simulator.runtime)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        installation(for: simulator)
                    }
                }
            } header: {
                Text("Running Simulators")
            } footer: {
                HStack {
                    if https.certificateForDevices == nil {
                        Text("Set up HTTPS first, with Capture › Decrypt HTTPS.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if let certificate = https.certificateDetails {
                        Text(
                            "Simulators need the current certificate, “\(certificate.name)”. After you make a new one, install it again."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Refresh") {
                        Task { await simulators.refresh() }
                    }
                    .disabled(simulators.isRefreshing)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            while !Task.isCancelled {
                await simulators.refresh()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    @ViewBuilder
    private func installation(for simulator: Simulator) -> some View {
        switch simulators.installation(on: simulator, of: https.certificateForDevices) {
        case .installing:
            ProgressView()
                .controlSize(.small)
        case .installed:
            Label("Certificate Installed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color("StatusSuccess"))
        case .failed(let message):
            HStack {
                Label("Couldn't Install", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .help(message)
                install(on: simulator, title: "Try Again")
            }
        case nil:
            install(on: simulator, title: "Install Certificate")
        }
    }

    private func install(on simulator: Simulator, title: String) -> some View {
        Button(title) {
            guard let certificate = https.certificateForDevices else { return }
            Task { await simulators.installCertificate(on: simulator, certificate: certificate) }
        }
        .disabled(https.certificateForDevices == nil)
    }
}

// MARK: - Android emulators

private struct EmulatorsPane: View {
    @Environment(EmulatorsModel.self) private var emulators
    @Environment(HTTPSModel.self) private var https
    @Environment(CaptureModel.self) private var capture

    var body: some View {
        Form {
            Section {
                Text(
                    "Android emulators send their traffic through Reqly once their proxy points at this Mac. Reqly sets that up with adb."
                )
                if !capture.isCapturing {
                    Label("Start capturing, so emulators can connect.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            Section {
                if let problem = emulators.problem {
                    Text(problem).foregroundStyle(.secondary)
                } else if emulators.emulators.isEmpty {
                    Text("No emulators are running. Start one from Android Studio's Device Manager.")
                        .foregroundStyle(.secondary)
                }
                ForEach(emulators.emulators) { emulator in
                    EmulatorRow(emulator: emulator)
                }
            } header: {
                Text("Running Emulators")
            } footer: {
                HStack {
                    Spacer()
                    Button("Refresh") {
                        Task { await emulators.refresh() }
                    }
                    .disabled(emulators.isRefreshing || emulators.adb == nil)
                }
            }
            Section("HTTPS") {
                Text(
                    "Copy Certificate puts Reqly's certificate in the emulator's Downloads and opens its security settings. There, choose Encryption & credentials › Install a certificate › CA certificate, then pick Reqly CA. On recent versions of Android, Encryption & credentials is under More security & privacy."
                )
                Text("On Android 7 and later, apps trust it only if they opt in. Debug builds of your own apps can.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            // An emulator that's still starting up is ready a little later.
            while !Task.isCancelled {
                await emulators.refresh()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }
}

private struct EmulatorRow: View {
    @Environment(EmulatorsModel.self) private var emulators
    @Environment(HTTPSModel.self) private var https
    @Environment(CaptureModel.self) private var capture
    let emulator: EmulatorsModel.Emulator

    var body: some View {
        let usesReqly = emulator.proxy == EmulatorsModel.proxy(port: capture.devicePort)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(emulator.name)
                    Text(status(usesReqly: usesReqly))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if emulators.busy.contains(emulator.id) {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(usesReqly ? "Stop Using Reqly" : "Use Reqly") {
                    Task { await emulators.setUsesReqly(!usesReqly, emulator: emulator, port: capture.devicePort) }
                }
                Button("Copy Certificate") {
                    guard let certificate = https.certificateForDevices else { return }
                    Task { await emulators.copyCertificate(to: emulator, certificate: certificate) }
                }
                .disabled(https.certificateForDevices == nil)
                .help(https.certificateForDevices == nil ? "Set up HTTPS first, with Capture › Decrypt HTTPS." : "")
            }
            .disabled(!emulator.isReady || emulators.busy.contains(emulator.id))
            if let note = emulators.notes[emulator.id] {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func status(usesReqly: Bool) -> String {
        guard emulator.isReady else { return "Starting up" }
        if usesReqly {
            return "Sends its traffic through Reqly"
        }
        if let proxy = emulator.proxy {
            return "Uses another proxy, \(proxy)"
        }
        return "Doesn't use Reqly"
    }
}

// MARK: - Letting a device in

/// Asks whether a device that wants to connect may send its traffic through Reqly.
struct DeviceApprovalSheet: View {
    @Environment(DevicesModel.self) private var devices
    let request: DevicesModel.Request
    @State private var name = ""

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "iphone.radiowaves.left.and.right")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            Text("Let this device use Reqly?")
                .font(.headline)
            Text("A device at \(request.address) wants to send its traffic through Reqly. Allow it only if it's yours.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Name", text: $name, prompt: Text("Name it, if you like"))
                .textFieldStyle(.roundedBorder)
            if devices.requests.count > 1 {
                Text(
                    devices.requests.count == 2
                        ? "1 more device is waiting." : "\(devices.requests.count - 1) more devices are waiting."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            HStack {
                Button("Don't Allow", role: .cancel) {
                    devices.decide(request, allow: false)
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Allow") {
                    devices.decide(request, allow: true, name: name)
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 380)
    }
}
