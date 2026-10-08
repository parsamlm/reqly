import ReqlyModel
import SwiftUI

/// The main window: the sidebar, the request list and the selected request's details. A file
/// you open gets the same window, without the controls for capturing.
struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(CaptureModel.self) private var capture
    @Environment(TrafficListModel.self) private var traffic
    @Environment(DevicesModel.self) private var devices
    @Environment(\.trafficFile) private var file
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @FocusState private var isSearching: Bool

    var body: some View {
        @Bindable var traffic = traffic
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 232, max: 320)
        } content: {
            RequestListView()
                // Wide enough for every column, with room left for the request.
                .navigationSplitViewColumnWidth(min: 640, ideal: 720)
        } detail: {
            InspectorView()
                .navigationSplitViewColumnWidth(min: 320, ideal: 420, max: 640)
        }
        .navigationTitle(title)
        // The subtitle changes with every batch of traffic. Set from a view of its own behind
        // the window's content, it updates only itself, not the whole window.
        .background { TrafficSubtitle() }
        .searchable(text: $traffic.searchText, placement: .toolbar, prompt: "Search requests")
        .searchFocused($isSearching)
        .sheet(isPresented: waitingForApproval) {
            ApprovalSheet()
        }
        .sheet(item: $traffic.harExport) { request in
            HARExportSheet(request: request)
        }
        .sheet(item: deviceRequest) { request in
            DeviceApprovalSheet(request: request)
        }
        .focusedSceneValue(\.traffic, traffic)
        .focusedSceneValue(\.findRequests) { isSearching = true }
        .onAppear {
            guard file == nil else { return }
            // The first-run guide opens once, the first time Reqly does.
            let defaults = UserDefaults.standard
            if !defaults.bool(forKey: DefaultsKey.hasSeenWelcome) {
                defaults.set(true, forKey: DefaultsKey.hasSeenWelcome)
                openWindow(id: "welcome")
            }
        }
        .onChange(of: model.crashes.report, initial: true) {
            if file == nil, model.crashes.report != nil {
                openWindow(id: "crash-report")
            }
        }
        .onChange(of: model.filesToOpen, initial: true) {
            // Files opened from Finder open in windows of their own, from the live window only.
            guard file == nil, !model.filesToOpen.isEmpty else { return }
            for url in model.filesToOpen {
                openWindow(id: "file", value: url)
            }
            model.filesToOpen.removeAll()
        }
        #if DEBUG
            .onAppear {
                if file == nil, UserDefaults.standard.bool(forKey: DefaultsKey.showHelp) {
                    openWindow(id: "help")
                }
                if file == nil, UserDefaults.standard.bool(forKey: DefaultsKey.showWelcome) {
                    openWindow(id: "welcome")
                }
                if file == nil, UserDefaults.standard.bool(forKey: DefaultsKey.showMenuBarPanel) {
                    openWindow(id: "menu-bar-panel")
                }
                if file == nil, let path = UserDefaults.standard.string(forKey: DefaultsKey.auditAccessibility) {
                    Task {
                        try? await Task.sleep(for: .seconds(6))
                        DebugLaunch.auditAccessibility(to: path)
                    }
                }
                if file == nil, let path = UserDefaults.standard.string(forKey: DefaultsKey.auditKeyboard) {
                    Task {
                        try? await Task.sleep(for: .seconds(7))
                        await DebugLaunch.auditKeyboard(to: path)
                    }
                }
                if file == nil, let path = UserDefaults.standard.string(forKey: DefaultsKey.dumpMenus) {
                    // Once the test traffic has come in, so the Request menu has a request.
                    Task {
                        try? await Task.sleep(for: .seconds(5))
                        DebugLaunch.dumpMenus(to: path)
                    }
                }
                if file == nil, UserDefaults.standard.string(forKey: DefaultsKey.showDevices) != nil {
                    openWindow(id: "devices")
                }
                if file == nil, UserDefaults.standard.string(forKey: DefaultsKey.showSettings) != nil {
                    openSettings()
                }
                if file == nil, let name = UserDefaults.standard.string(forKey: DefaultsKey.showRules),
                    let kind = RuleKind(rawValue: name)
                {
                    model.rules.section = kind
                    openWindow(id: "rules")
                }
            }
            .background { LaunchHooks() }
        #endif
        .toolbar {
            if file == nil {
                ToolbarItem(placement: .primaryAction) {
                    CaptureButton()
                }
                ToolbarItem(placement: .primaryAction) {
                    RuleSwitch(kind: .breakpoint)
                }
                ToolbarItem(placement: .primaryAction) {
                    RuleSwitch(kind: .slowNetwork)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Clear Traffic", systemImage: "trash") {
                    traffic.clear()
                }
                .help(traffic.pinnedCount > 0 ? "Clear Traffic (⌘K). Pinned requests stay." : "Clear Traffic (⌘K)")
                .disabled(!traffic.canClear)
            }
        }
    }

    /// The first device waiting to be let in. Its sheet decides, so closing it does nothing else.
    private var deviceRequest: Binding<DevicesModel.Request?> {
        Binding(get: { file == nil ? devices.requests.first : nil }, set: { _ in })
    }

    private var waitingForApproval: Binding<Bool> {
        Binding(
            get: { file == nil && capture.status == .waitingForApproval },
            set: { if !$0 { capture.cancelApproval() } }
        )
    }

    private var title: String {
        switch traffic.scope {
        case .all: file?.lastPathComponent ?? "All Traffic"
        case .pinned: "Pinned"
        case .source(let source, .thisMac): source.name
        case .source(let source, let device): "\(source.name) on \(traffic.deviceName(device))"
        case .device(let choice): traffic.deviceName(choice)
        case .host(let host): host
        case .deviceHost(let host, let device): "\(host) on \(traffic.deviceName(device))"
        }
    }
}

/// The window's subtitle: how many requests the list shows.
private struct TrafficSubtitle: View {
    @Environment(CaptureModel.self) private var capture
    @Environment(TrafficListModel.self) private var traffic
    @Environment(\.trafficFile) private var file

    var body: some View {
        Color.clear
            .navigationSubtitle(subtitle)
    }

    private var subtitle: String {
        if let problem = traffic.storageProblem {
            return problem
        }
        if traffic.isEmpty {
            if file != nil {
                return "No requests"
            }
            return capture.isCapturing ? "Waiting for traffic" : "Not capturing"
        }
        let total = traffic.scopeCount
        if traffic.visibleCount == total {
            return Format.requests(total)
        }
        return "\(traffic.visibleCount.formatted()) of \(Format.requests(total))"
    }
}

#if DEBUG
    /// Runs the launch arguments that wait for traffic, as it arrives.
    private struct LaunchHooks: View {
        @Environment(AppModel.self) private var model
        @Environment(TrafficListModel.self) private var traffic
        @Environment(\.trafficFile) private var file
        @Environment(\.openWindow) private var openWindow

        var body: some View {
            Color.clear
                .onChange(of: traffic.totalCount) {
                    if file == nil {
                        DebugLaunch.trafficChanged(traffic, model: model, openWindow: openWindow)
                    }
                }
        }
    }
#endif

/// Starts and stops capturing. While capturing it shows a dot in the status color.
struct CaptureButton: View {
    @Environment(CaptureModel.self) private var capture

    var body: some View {
        Group {
            if capture.isCapturing {
                Button {
                    capture.toggle()
                } label: {
                    Label {
                        Text("Capturing")
                    } icon: {
                        Image(systemName: "circle.fill")
                            .foregroundStyle(Color("StatusSuccess"))
                    }
                    .labelStyle(.titleAndIcon)
                }
                .help("Stop Capturing (⌘R)")
            } else {
                Button {
                    capture.toggle()
                } label: {
                    Text("Start Capturing")
                        .readableOnAccent()
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .help("Start Capturing (⌘R)")
            }
        }
        .disabled(capture.isBusy)
    }
}
