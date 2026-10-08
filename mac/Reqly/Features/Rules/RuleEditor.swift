import AppKit
import BodyKit
import ReqlyModel
import SwiftUI
import UniformTypeIdentifiers

/// The sheet for writing a rule: the requests it matches, and what it does with them.
struct RuleEditor: View {
    @Environment(RulesModel.self) private var rules
    @Environment(TrafficListModel.self) private var traffic
    @State private var draft: RuleDraft

    init(draft: RuleDraft) {
        _draft = State(initialValue: draft)
    }

    private static let methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(draft.isNew ? "New" : "Edit") \(draft.kind.ruleTitle)")
                .font(.headline)
            Form {
                LabeledContent("Name") {
                    TextField("Name", text: $draft.name, prompt: Text(draft.defaultName))
                        .labelsHidden()
                }
                LabeledContent("Host") {
                    TextField("Host", text: $draft.host, prompt: Text("Any host"))
                        .labelsHidden()
                        .font(.body.monospaced())
                }
                LabeledContent("Path") {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Path", text: $draft.path, prompt: Text("Any path"))
                            .labelsHidden()
                            .font(.body.monospaced())
                        Text("Use * to match anything.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Method") {
                    Picker("Method", selection: $draft.method) {
                        Text("Any").tag("")
                        Divider()
                        ForEach(methods, id: \.self) { method in
                            Text(method).tag(method)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                kindFields
                LabeledContent {
                    MatchCount(count: matchCount)
                } label: {
                    Text("")
                }
            }
            .formStyle(.columns)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    rules.editing = nil
                }
                .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.rule == nil)
                    .help(draft.problem ?? "")
            }
        }
        .padding(24)
        .frame(width: draft.kind == .rewrite ? 660 : 500)
    }

    /// The common methods, and the draft's own if it's another one.
    private var methods: [String] {
        draft.method.isEmpty || Self.methods.contains(draft.method) ? Self.methods : [draft.method] + Self.methods
    }

    @ViewBuilder
    private var kindFields: some View {
        switch draft.kind {
        case .breakpoint:
            LabeledContent("Pause") {
                Picker("Pause", selection: $draft.phase) {
                    ForEach(BreakpointPhase.allCases, id: \.self) { phase in
                        Text(phase.title).tag(phase)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        case .mapLocal:
            LabeledContent("File") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("File", text: $draft.file, prompt: Text("~/Responses/forecast.json"))
                            .labelsHidden()
                            .font(.body.monospaced())
                        Button("Choose…", action: chooseFile)
                    }
                    if hasResponse {
                        Button("Save the Response as a File…", action: saveResponse)
                            .buttonStyle(.link)
                    }
                }
            }
            LabeledContent("Status") {
                TextField("Status", value: $draft.status, format: .number.grouping(.never))
                    .labelsHidden()
                    .frame(width: 64)
            }
            LabeledContent("Content type") {
                TextField("Content Type", text: $draft.contentType, prompt: Text("From the file's extension"))
                    .labelsHidden()
            }
        case .mapRemote:
            LabeledContent("Send to") {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Send To", text: $draft.destination, prompt: Text("https://staging.weatherly.dev"))
                        .labelsHidden()
                        .font(.body.monospaced())
                    Text("A path here replaces the request's path. The query stays.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .rewrite:
            LabeledContent("Changes") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach($draft.changes) { $change in
                        RewriteRow(change: $change) {
                            draft.changes.removeAll { $0.id == change.id }
                        }
                    }
                    Button("Add Change", systemImage: "plus") {
                        draft.changes.append(RewriteDraft())
                    }
                    .buttonStyle(.borderless)
                    if draft.changes.contains(where: { $0.change == .replaceBody }) {
                        Text("Reqly asks servers not to compress the bodies it changes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        case .block:
            LabeledContent("Answer") {
                Picker("Answer", selection: $draft.closesConnection) {
                    Text("With a status").tag(false)
                    Text("By closing the connection, as a failing network would").tag(true)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
            LabeledContent("Status") {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Status", value: $draft.blockStatus, format: .number.grouping(.never))
                        .labelsHidden()
                        .frame(width: 64)
                    Text(
                        "HTTPS paths show only for hosts Reqly decrypts. Elsewhere, a rule for any path blocks the host."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(draft.closesConnection)
        case .script, .slowNetwork:
            // Scripts have an editor of their own.
            EmptyView()
        }
    }

    /// The requests captured so far that the rule would act on.
    private var matchCount: Int {
        let match = draft.match
        // An encrypted connection has no path or method to match, only its host.
        let matchesTunnels = draft.kind == .block && match.path == "*" && match.method == nil
        return traffic.all.count { summary in
            (summary.kind == .http || matchesTunnels) && match.matches(summary)
        }
    }

    private var hasResponse: Bool {
        guard let id = draft.exchange, let summary = traffic.summary(id) else { return false }
        return summary.kind == .http && summary.status != nil
    }

    private func save() {
        guard let rule = draft.rule else { return }
        rules.save(rule)
        // A rule you just made should act, so its kind comes on with it.
        if draft.isNew {
            rules.setOn(true, for: rule.kind)
        }
        rules.editing = nil
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.prompt = "Choose"
        panel.message = "Choose the file to answer with."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.file = (url.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
    }

    /// Saves the response as it arrived, unpacked, so you can change the file and answer with it.
    private func saveResponse() {
        guard let id = draft.exchange else { return }
        Task {
            guard let exchange = await traffic.exchange(id), let response = exchange.response else { return }
            let body =
                response.headers["Content-Encoding"].flatMap {
                    BodyDecoder.decode(exchange.responseBody, contentEncoding: $0)
                } ?? exchange.responseBody
            let contentType = response.headers["Content-Type"]
            let panel = NSSavePanel()
            panel.nameFieldStringValue = Self.fileName(for: exchange.request, contentType: contentType)
            panel.message = "Save the response. Change the file to change what Reqly answers with."
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try body.write(to: url, options: .atomic)
            } catch {
                NSAlert(error: error).runModal()
                return
            }
            draft.file = (url.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
            draft.status = response.status
            draft.contentType = contentType ?? ""
        }
    }

    /// A name for a response's file, such as `forecast.json`.
    private static func fileName(for request: RequestHead, contentType: String?) -> String {
        let last = (request.path as NSString).lastPathComponent
        let name = last.isEmpty || last == "/" ? request.host : last
        guard (name as NSString).pathExtension.isEmpty,
            let type = contentType?.split(separator: ";").first.map({ $0.trimmingCharacters(in: .whitespaces) }),
            let ext = UTType(mimeType: type)?.preferredFilenameExtension
        else { return name }
        return "\(name).\(ext)"
    }
}

/// How many requests captured so far a rule matches, as you edit it.
private struct MatchCount: View {
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(count > 0 ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                .frame(width: 7, height: 7)
            Text(text)
                .font(.callout.weight(.medium))
                .foregroundStyle(count > 0 ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
    }

    private var text: String {
        switch count {
        case 0: "Matches no requests captured so far"
        case 1: "Matches 1 request captured so far"
        default: "Matches \(count.formatted()) requests captured so far"
        }
    }
}

/// One change of a Rewrite rule: what it changes, and how.
private struct RewriteRow: View {
    @Binding var change: RewriteDraft
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Picker("Change", selection: $change.change) {
                ForEach(RewriteDraft.Change.allCases) { change in
                    Text(change.title).tag(change)
                }
            }
            .labelsHidden()
            .fixedSize()
            if change.change.hasPart {
                Picker("Part", selection: $change.part) {
                    Text("Request").tag(MessagePart.request)
                    Text("Response").tag(MessagePart.response)
                }
                .labelsHidden()
                .fixedSize()
            }
            fields
            Button("Remove Change", systemImage: "minus.circle", action: remove)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Remove Change")
        }
        .font(.body)
    }

    @ViewBuilder
    private var fields: some View {
        switch change.change {
        case .setHeader:
            field("Header", $change.name)
            field("Value", $change.value)
        case .removeHeader:
            field("Header", $change.name)
        case .setQueryParameter:
            field("Parameter", $change.name)
            field("Value", $change.value)
        case .removeQueryParameter:
            field("Parameter", $change.name)
        case .replaceBody:
            field("Find", $change.name)
            field("Replace with", $change.value)
        case .setStatus:
            TextField("Status", value: $change.status, format: .number.grouping(.never))
                .labelsHidden()
                .frame(width: 64)
            Spacer(minLength: 0)
        }
    }

    private func field(_ title: String, _ text: Binding<String>) -> some View {
        TextField(title, text: text, prompt: Text(title))
            .labelsHidden()
            .font(.body.monospaced())
    }
}
