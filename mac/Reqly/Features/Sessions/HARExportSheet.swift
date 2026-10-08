import AppKit
import HAR
import ReqlyModel
import SwiftUI

/// What the Export as HAR sheet was opened for.
struct HARExportRequest: Identifiable {
    let id = UUID()
    /// The request it was opened on, if any.
    var selected: ExchangeID?
}

/// Exports the selected request, or the whole list as filtered, to a HAR file.
struct HARExportSheet: View {
    @Environment(TrafficListModel.self) private var traffic
    @Environment(\.dismiss) private var dismiss
    let request: HARExportRequest

    private enum Scope: Hashable {
        case selected, list
    }

    @State private var scope = Scope.list
    @AppStorage("harIncludesResponseBodies") private var includesBodies = true
    @State private var secrets = SecretsOption(key: "hidesSecretsInHAR", defaultValue: true)
    @State private var exported: Int?
    @State private var problem: String?
    @State private var export: Task<Void, Never>?

    var body: some View {
        let listed = traffic.visible.filter { $0.kind == .http }
        VStack(alignment: .leading, spacing: 14) {
            Text("Export as HAR")
                .font(.title3.weight(.semibold))
            Text("Save requests as a HAR file that you can open in browsers and other tools.")
                .foregroundStyle(.secondary)
            Picker("Export", selection: $scope) {
                if request.selected != nil {
                    Text("Selected request \(Text("1").foregroundStyle(.secondary))").tag(Scope.selected)
                }
                Text("All requests in this list \(Text(listed.count.formatted()).foregroundStyle(.secondary))")
                    .tag(Scope.list)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if traffic.visible.count > listed.count, scope == .list {
                Text("Encrypted connections are left out, since their requests can't be read.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Toggle("Include response bodies", isOn: $includesBodies)
            SecretsToggle(option: secrets)
            Label {
                Text(
                    secrets.isOn
                        ? "Authorization headers and cookies are hidden. Bodies can still hold personal data, so share HAR files with care."
                        : "HAR files contain everything in the requests, including cookies and tokens. Share them with care."
                )
            } icon: {
                Image(systemName: "info.circle")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            HStack {
                if let exported {
                    ProgressView(value: Double(exported), total: Double(max(ids(listed).count, 1)))
                        .frame(width: 160)
                    Text("\(exported.formatted()) of \(Format.requests(ids(listed).count))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Button("Cancel") {
                    export?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Export…") {
                    choose(ids(listed))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(exported != nil || ids(listed).isEmpty)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 500)
        .onAppear {
            if request.selected != nil {
                scope = .selected
            }
        }
    }

    private func ids(_ listed: [ExchangeSummary]) -> [ExchangeID] {
        if scope == .selected, let selected = request.selected {
            return [selected]
        }
        return listed.map(\.id)
    }

    private func choose(_ ids: [ExchangeID]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.har]
        panel.canCreateDirectories = true
        let name = ids.count == 1 ? traffic.summary(ids[0])?.host : nil
        panel.nameFieldStringValue = "\(name ?? "Reqly") \(Format.fileStamp(Date())).har"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let options = HARWriter.Options(includesResponseBodies: includesBodies, hidesSecrets: secrets.isOn)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        exported = 0
        problem = nil
        export = Task {
            do {
                await traffic.settle()
                let writer = try HARWriter(url: url, options: options, creatorVersion: version)
                for (done, id) in ids.enumerated() {
                    try Task.checkCancellation()
                    if let exchange = await traffic.exchange(id) {
                        let messages = exchange.messageCount > 0 ? await traffic.messages(of: id) : []
                        try writer.append(exchange, messages: messages)
                    }
                    if done % 25 == 0 {
                        exported = done
                    }
                }
                try writer.finish()
                dismiss()
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: url)
            } catch {
                exported = nil
                problem = "Reqly couldn't export: \(error.localizedDescription)"
            }
        }
    }
}
