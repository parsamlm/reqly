import ReqlyModel
import SwiftUI

/// The bar above the request list: chips for the kinds of status, a token for each filter
/// that's set, and the Filters button.
struct FilterBar: View {
    @Environment(TrafficListModel.self) private var traffic
    @State private var isShowingFilters = Self.showsFiltersAtFirst

    private static var showsFiltersAtFirst: Bool {
        #if DEBUG
            UserDefaults.standard.bool(forKey: DefaultsKey.showFilters)
        #else
            false
        #endif
    }

    var body: some View {
        HStack(spacing: 6) {
            FilterChip("All", isOn: traffic.filter.statuses.isEmpty, help: "Show every status") {
                traffic.filter.statuses = []
            }
            ForEach(StatusFilter.allCases, id: \.self) { status in
                FilterChip(status.title, isOn: traffic.filter.statuses.contains(status), help: status.help) {
                    traffic.filter.statuses.formSymmetricDifference([status])
                } icon: {
                    StatusFilterIcon(status: status)
                }
            }
            Divider()
                .frame(height: 16)
                .padding(.horizontal, 4)
            if !chosen.isEmpty {
                // One token for each filter when they fit, or else one for them all.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        ForEach(chosen, id: \.kind) { choice in
                            FilterToken(choice.title, kind: choice.kind) { choice.clear(&traffic.filter) }
                        }
                    }
                    .fixedSize()
                    FilterToken(
                        chosen.count == 1 ? "1 filter" : "\(chosen.count) filters",
                        kind: "Filters",
                        help: chosen.map { "\($0.kind): \($0.title)" }.joined(separator: "\n")
                    ) {
                        var filter = traffic.filter
                        for choice in chosen {
                            choice.clear(&filter)
                        }
                        traffic.filter = filter
                    }
                    .fixedSize()
                }
            }
            Button {
                isShowingFilters.toggle()
            } label: {
                Label("Filters", systemImage: "line.3.horizontal.decrease")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(.quaternary, in: .capsule)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help("Filter by app, host, method or content type")
            .popover(isPresented: $isShowingFilters, arrowEdge: .bottom) {
                FiltersPopover()
            }
        }
        .padding(.horizontal, 12)
        // The tokens are the only part that can shrink, so they get all the room that's left.
        .frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40, alignment: .leading)
    }

    /// A filter set in the popover, for its token.
    private struct Choice {
        var kind: String
        var title: String
        /// Takes this filter off.
        var clear: (inout TrafficFilter) -> Void
    }

    private var chosen: [Choice] {
        var chosen: [Choice] = []
        if let source = traffic.filter.source {
            chosen.append(Choice(kind: "App", title: source.name) { $0.source = nil })
        }
        if let device = traffic.filter.device {
            chosen.append(Choice(kind: "Device", title: traffic.deviceName(device)) { $0.device = nil })
        }
        if let host = traffic.filter.host {
            chosen.append(Choice(kind: "Host", title: host) { $0.host = nil })
        }
        if let method = traffic.filter.method {
            chosen.append(Choice(kind: "Method", title: method) { $0.method = nil })
        }
        if !traffic.filter.contents.isEmpty {
            chosen.append(Choice(kind: "Content type", title: contentTitle) { $0.contents = [] })
        }
        return chosen
    }

    /// The chosen kinds of content, in the popover's order, such as "JSON or Images".
    private var contentTitle: String {
        ContentGroup.allCases.filter(traffic.filter.contents.contains).map(\.title).formatted(.list(type: .or))
    }
}

/// A status chip. Each turns on and off by itself, and All turns them all off.
private struct FilterChip<Icon: View>: View {
    let title: String
    let isOn: Bool
    let help: String
    let action: () -> Void
    let icon: Icon

    init(
        _ title: String, isOn: Bool, help: String, action: @escaping () -> Void, @ViewBuilder icon: () -> Icon
    ) {
        self.title = title
        self.isOn = isOn
        self.help = help
        self.action = action
        self.icon = icon()
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                icon
                // The bold title sets the width, so the chips don't shift as they turn on and off.
                ZStack {
                    Text(title).fontWeight(.semibold).hidden()
                    Text(title).fontWeight(isOn ? .semibold : .regular)
                }
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(isOn ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(help)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

extension FilterChip where Icon == EmptyView {
    init(_ title: String, isOn: Bool, help: String, action: @escaping () -> Void) {
        self.init(title, isOn: isOn, help: help, action: action) { EmptyView() }
    }
}

/// The status color's dot, or a warning symbol for failures, as in the request list.
private struct StatusFilterIcon: View {
    let status: StatusFilter

    var body: some View {
        switch status {
        case .success: dot(StatusClass.success.color)
        case .redirection: dot(StatusClass.redirection.color)
        case .clientError: dot(StatusClass.clientError.color)
        case .serverError: dot(StatusClass.serverError.color)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .imageScale(.small)
                .foregroundStyle(.red)
        }
    }

    private func dot(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
    }
}

/// A filter that's set, with a button that removes it.
private struct FilterToken: View {
    let title: String
    /// What the filter is on, such as "Host", for VoiceOver.
    let kind: String
    let help: String
    let remove: () -> Void

    init(_ title: String, kind: String, help: String? = nil, remove: @escaping () -> Void) {
        self.title = title
        self.kind = kind
        self.help = help ?? "\(kind): \(title)"
        self.remove = remove
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .lineLimit(1)
            Button("Remove \(kind) Filter", systemImage: "xmark", action: remove)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .imageScale(.small)
                .foregroundStyle(.secondary)
                .help("Remove this filter")
        }
        .font(.callout.weight(.medium))
        .padding(.leading, 10)
        .padding(.trailing, 7)
        .frame(height: 24)
        .background(.tint.opacity(0.15), in: .capsule)
        .help(help)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(kind): \(title)")
    }
}

/// Filters by app, device, host, method and kind of content. The status chips stay in the bar.
private struct FiltersPopover: View {
    @Environment(TrafficListModel.self) private var traffic

    var body: some View {
        @Bindable var traffic = traffic
        VStack(alignment: .leading, spacing: 12) {
            Text("Filters")
                .font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("App").foregroundStyle(.secondary)
                    Picker("App", selection: $traffic.filter.source) {
                        Text("Any app").tag(Source?.none)
                        Divider()
                        ForEach(choices(traffic.sources, keeping: traffic.filter.source), id: \.self) {
                            Text($0.name).tag(Source?.some($0))
                        }
                    }
                    .labelsHidden()
                }
                // Shown once a phone, a simulator or an emulator sent traffic, or while one is chosen.
                if !traffic.devices.isEmpty || traffic.filter.device != nil {
                    GridRow {
                        Text("Device").foregroundStyle(.secondary)
                        Picker("Device", selection: $traffic.filter.device) {
                            Text("Any device").tag(DeviceChoice?.none)
                            Divider()
                            ForEach(deviceChoices, id: \.self) { choice in
                                Text(traffic.deviceName(choice)).tag(DeviceChoice?.some(choice))
                            }
                        }
                        .labelsHidden()
                    }
                }
                GridRow {
                    Text("Host").foregroundStyle(.secondary)
                    Picker("Host", selection: $traffic.filter.host) {
                        Text("Any host").tag(String?.none)
                        Divider()
                        ForEach(choices(traffic.hosts, keeping: traffic.filter.host), id: \.self) {
                            Text($0).tag(String?.some($0))
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("Method").foregroundStyle(.secondary)
                    Picker("Method", selection: $traffic.filter.method) {
                        Text("Any method").tag(String?.none)
                        Divider()
                        ForEach(choices(traffic.methods, keeping: traffic.filter.method), id: \.self) {
                            Text($0).tag(String?.some($0))
                        }
                    }
                    .labelsHidden()
                }
                GridRow(alignment: .top) {
                    Text("Content type").foregroundStyle(.secondary)
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                        ForEach(Self.contentRows, id: \.self) { row in
                            GridRow {
                                ForEach(row, id: \.self) { group in
                                    Toggle(group.title, isOn: isOn(group))
                                        .toggleStyle(.checkbox)
                                }
                            }
                        }
                    }
                }
            }
            Divider()
            HStack {
                Button("Clear All") {
                    traffic.clearFilters()
                }
                .buttonStyle(.link)
                .disabled(!traffic.filter.isActive)
                Spacer()
                Text(Format.requests(traffic.visibleCount))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .font(.callout)
        .padding(14)
        .frame(width: 300)
    }

    /// This Mac and the devices that sent traffic, and the chosen one even if it's gone.
    private var deviceChoices: [DeviceChoice] {
        let choices = traffic.devices.map(\.choice)
        guard let chosen = traffic.filter.device, !choices.contains(chosen) else { return choices }
        return choices + [chosen]
    }

    /// The kinds of content, two to a row.
    private static let contentRows: [[ContentGroup]] = stride(from: 0, to: ContentGroup.allCases.count, by: 2).map {
        Array(ContentGroup.allCases[$0..<min($0 + 2, ContentGroup.allCases.count)])
    }

    /// What a menu offers: what the session has, plus the current choice, so it still shows
    /// after its traffic is cleared.
    private func choices<Choice: Hashable>(_ available: [Choice], keeping chosen: Choice?) -> [Choice] {
        guard let chosen, !available.contains(chosen) else { return available }
        return available + [chosen]
    }

    private func isOn(_ group: ContentGroup) -> Binding<Bool> {
        Binding(
            get: { traffic.filter.contents.contains(group) },
            set: { isOn in
                if isOn {
                    traffic.filter.contents.insert(group)
                } else {
                    traffic.filter.contents.remove(group)
                }
            }
        )
    }
}

extension StatusFilter {
    var title: String {
        switch self {
        case .success: "2xx"
        case .redirection: "3xx"
        case .clientError: "4xx"
        case .serverError: "5xx"
        case .failed: "Failed"
        }
    }

    var help: String {
        switch self {
        case .success: "Show successful responses (2xx)"
        case .redirection: "Show redirects (3xx)"
        case .clientError: "Show client errors (4xx)"
        case .serverError: "Show server errors (5xx)"
        case .failed: "Show requests that failed"
        }
    }
}

extension ContentGroup {
    var title: String {
        switch self {
        case .json: "JSON"
        case .xml: "XML"
        case .html: "HTML"
        case .javascript: "JavaScript"
        case .css: "CSS"
        case .image: "Images"
        case .media: "Media"
        case .other: "Other"
        }
    }
}
