import ReqlyModel
import SwiftUI

/// Narrows the request list to all traffic, the pinned requests, one app, one device or one host.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(TrafficListModel.self) private var traffic
    @Environment(\.trafficFile) private var file
    /// The device being renamed, and the name so far.
    @State private var renaming: Device?
    @State private var newName = ""
    /// The devices whose apps and hosts are folded away.
    @State private var collapsed: Set<DeviceChoice> = []
    // Which sections are open, which Reqly remembers.
    @AppStorage(DefaultsKey.sidebarShowsApps) private var showsApps = true
    @AppStorage(DefaultsKey.sidebarShowsDevices) private var showsDevices = true
    @AppStorage(DefaultsKey.sidebarShowsHosts) private var showsHosts = true

    var body: some View {
        list
            .alert("Rename \(renaming?.name ?? "Device")", isPresented: isRenaming) {
                TextField("Name", text: $newName)
                Button("Rename") {
                    if let renaming {
                        model.renameDevice(renaming, to: newName)
                    }
                }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Its traffic shows with this name.")
            }
    }

    private var list: some View {
        List(selection: scope) {
            Label("All Traffic", systemImage: "arrow.left.arrow.right")
                .countBadge(.all)
                .tag(TrafficListModel.Scope.all)
            // Shown once something is pinned, and while it's selected.
            if traffic.pinnedCount > 0 || traffic.scope == .pinned {
                Label("Pinned", systemImage: "pin")
                    .countBadge(.pinned)
                    .tag(TrafficListModel.Scope.pinned)
                    .contextMenu {
                        Button("Unpin All Requests") {
                            traffic.unpinAll()
                        }
                        .disabled(traffic.pinnedCount == 0)
                    }
            }

            if traffic.devices.isEmpty {
                // All of it came from this Mac.
                if !traffic.sources.isEmpty {
                    Section(isExpanded: $showsApps) {
                        ForEach(traffic.apps(on: .thisMac), id: \.self) { source in
                            AppRow(source: source, device: .thisMac)
                                .tag(TrafficListModel.Scope.source(source, on: .thisMac))
                        }
                    } header: {
                        Text("Apps")
                    }
                }
            } else {
                // A phone, a simulator or an emulator sent some: the Mac and each device show
                // with their own apps, then the hosts of traffic no app is known for. One flat
                // run of rows, each device followed by its own: rows inside DisclosureGroups,
                // whose shape changes as traffic arrives, left stale rows drawn over others.
                Section(isExpanded: $showsDevices) {
                    ForEach(deviceRows) { row in
                        switch row.kind {
                        case .device(let entry, let hasChildren):
                            deviceRow(entry, hasChildren: hasChildren)
                        case .app(let source, let device):
                            AppRow(source: source, device: device)
                                .padding(.leading, 22)
                                .tag(TrafficListModel.Scope.source(source, on: device))
                        case .host(let host, let device):
                            Label(host, systemImage: "network")
                                .countBadge(.deviceHost(host, on: device))
                                .padding(.leading, 22)
                                .tag(TrafficListModel.Scope.deviceHost(host, on: device))
                        }
                    }
                } header: {
                    Text("Devices")
                }
            }

            Section(isExpanded: $showsHosts) {
                if traffic.hosts.isEmpty {
                    Text("Hosts show up here as apps talk to them.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                }
                ForEach(traffic.hosts, id: \.self) { host in
                    Label(host, systemImage: "network")
                        .countBadge(.host(host))
                        .tag(TrafficListModel.Scope.host(host))
                }
            } header: {
                Text("Hosts")
            }
        }
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            handleArrow(press.key)
        }
    }

    /// Each device, then its apps and the hosts of its other traffic, unless they're folded away.
    private var deviceRows: [SidebarRow] {
        traffic.devices.flatMap { entry -> [SidebarRow] in
            let apps = traffic.apps(on: entry.choice)
            let hosts = traffic.otherHosts(on: entry.choice)
            let device = SidebarRow(kind: .device(entry, hasChildren: !apps.isEmpty || !hosts.isEmpty))
            guard !collapsed.contains(entry.choice) else { return [device] }
            return [device] + apps.map { SidebarRow(kind: .app($0, on: entry.choice)) }
                + hosts.map { SidebarRow(kind: .host($0, on: entry.choice)) }
        }
    }

    private func deviceRow(_ entry: DeviceEntry, hasChildren: Bool) -> some View {
        let isExpanded = !collapsed.contains(entry.choice)
        return HStack(spacing: 4) {
            // A chevron like a disclosure triangle's, which folds the device's apps and hosts away.
            Button {
                setExpanded(!isExpanded, entry.choice)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 14, height: 14)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .opacity(hasChildren ? 1 : 0)
            .disabled(!hasChildren)
            .accessibilityLabel(isExpanded ? "Collapse \(entry.name)" : "Expand \(entry.name)")
            .accessibilityHidden(!hasChildren)
            Label(entry.name, systemImage: entry.device?.symbol ?? "laptopcomputer")
        }
        .countBadge(.device(entry.choice))
        .tag(TrafficListModel.Scope.device(entry.choice))
        .contextMenu {
            if hasChildren {
                Button(isExpanded ? "Collapse" : "Expand") {
                    setExpanded(!isExpanded, entry.choice)
                }
            }
            // Names belong to the devices of the traffic being captured.
            if let device = entry.device, file == nil {
                Button("Rename…") {
                    newName = device.name
                    renaming = device
                }
            }
        }
    }

    private func setExpanded(_ isExpanded: Bool, _ device: DeviceChoice) {
        if isExpanded {
            collapsed.remove(device)
        } else {
            collapsed.insert(device)
            // A hidden row can't stay selected: the device takes its place.
            switch traffic.scope {
            case .source(_, let selected), .deviceHost(_, let selected):
                if selected == device {
                    traffic.scope = .device(device)
                }
            default:
                break
            }
        }
    }

    private func hasChildren(_ device: DeviceChoice) -> Bool {
        !traffic.apps(on: device).isEmpty || !traffic.otherHosts(on: device).isEmpty
    }

    /// Left and right arrows fold and unfold a device, as in Finder. On an app or a host under
    /// a device, left goes up to the device.
    private func handleArrow(_ key: KeyEquivalent) -> KeyPress.Result {
        // The rows are hidden while their section is closed.
        guard showsDevices else { return .ignored }
        switch (key, traffic.scope) {
        case (.leftArrow, .device(let device)) where !collapsed.contains(device) && hasChildren(device):
            setExpanded(false, device)
        case (.leftArrow, .source(_, let device)) where !traffic.devices.isEmpty,
            (.leftArrow, .deviceHost(_, let device)):
            traffic.scope = .device(device)
        case (.rightArrow, .device(let device)) where collapsed.contains(device):
            setExpanded(true, device)
        default:
            return .ignored
        }
        return .handled
    }

    private var isRenaming: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    /// The list selects an optional value; the traffic model always has a scope.
    private var scope: Binding<TrafficListModel.Scope?> {
        Binding(
            get: { traffic.scope },
            set: { traffic.scope = $0 ?? .all }
        )
    }
}

extension Device {
    /// The symbol for the kind of device.
    var symbol: String {
        switch kind {
        case .network: "iphone"
        case .simulator: "macbook.and.iphone"
        case .emulator: "smartphone"
        }
    }

    /// The device and what kind it is, such as "iPhone 17 Pro · Simulator".
    var fullName: String {
        switch kind {
        case .network: address.map { $0 == name ? name : "\(name) · \($0)" } ?? name
        case .simulator: "\(name) · Simulator"
        case .emulator: "\(name) · Android emulator"
        }
    }
}

/// A row of the Devices section: a device, or one of its apps or hosts.
private struct SidebarRow: Identifiable {
    enum Kind {
        case device(DeviceEntry, hasChildren: Bool)
        case app(Source, on: DeviceChoice)
        /// A host the device's traffic from no known app went to.
        case host(String, on: DeviceChoice)
    }

    let kind: Kind

    /// What the row selects, which is unique in the list and stays the same as traffic arrives.
    var id: TrafficListModel.Scope {
        switch kind {
        case .device(let entry, _): .device(entry.choice)
        case .app(let source, let device): .source(source, on: device)
        case .host(let host, let device): .deviceHost(host, on: device)
        }
    }
}

/// An app and how much traffic it sent.
private struct AppRow: View {
    let source: Source
    let device: DeviceChoice

    var body: some View {
        Label {
            Text(source.name)
        } icon: {
            SourceIcon(source: source)
        }
        .countBadge(.source(source, on: device))
    }
}

extension View {
    /// The badge with how many exchanges a sidebar row covers. Only this part of the row
    /// updates as traffic arrives, and only when its count changes.
    fileprivate func countBadge(_ scope: TrafficListModel.Scope) -> some View {
        modifier(CountBadge(scope: scope))
    }
}

private struct CountBadge: ViewModifier {
    @Environment(TrafficListModel.self) private var traffic
    let scope: TrafficListModel.Scope

    func body(content: Content) -> some View {
        content.badge(traffic.count(of: scope))
    }
}

/// An app's or tool's icon, at the size of a symbol in a list.
struct SourceIcon: View {
    let source: Source?

    var body: some View {
        if let icon = SourceIcons.icon(for: source) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "app.dashed")
        }
    }
}
