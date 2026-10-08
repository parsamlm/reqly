import Capture
import ReqlyModel
import SwiftUI

/// The sheet for writing a script: the requests it matches, its JavaScript, and a way to try
/// it on a request captured earlier.
struct ScriptEditor: View {
    @Environment(RulesModel.self) private var rules
    @Environment(TrafficListModel.self) private var traffic
    @State private var draft: RuleDraft
    @State private var syntaxProblem: String?
    @State private var isChecking = false
    @State private var trialRequest: ExchangeID?
    @State private var trials: [ScriptTrial]?
    @State private var isTrying = false
    @State private var showsReference = false

    init(draft: RuleDraft) {
        _draft = State(initialValue: draft)
        _trialRequest = State(initialValue: draft.exchange)
    }

    private static let methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("\(draft.isNew ? "New" : "Edit") Script")
                    .font(.headline)
                Spacer()
                Menu("Examples") {
                    ForEach(ScriptExamples.all) { example in
                        Button(example.title) { useExample(example) }
                    }
                }
                .menuStyle(.button)
                .fixedSize()
                Button("Script Reference", systemImage: "questionmark.circle") { showsReference.toggle() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Script Reference")
                    .popover(isPresented: $showsReference, arrowEdge: .bottom) { ScriptReference() }
            }
            match
            editor
            trySection
            HStack {
                MatchCountLabel(count: matchingRequests.count)
                Spacer()
                Button("Cancel", role: .cancel) {
                    rules.editing = nil
                }
                .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.rule == nil || syntaxProblem != nil)
                    .help(draft.problem ?? syntaxProblem ?? "")
            }
        }
        .padding(24)
        .frame(width: 860, height: 720)
        .task(id: draft.code) {
            // Checked a moment after typing stops.
            isChecking = true
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            syntaxProblem = await rules.checkScript(draft.code)
            isChecking = false
        }
        .onChange(of: draft.code) { trials = nil }
    }

    private var match: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("Name").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                TextField("Name", text: $draft.name, prompt: Text(draft.defaultName))
                    .labelsHidden()
                Text("Method").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                Picker("Method", selection: $draft.method) {
                    Text("Any").tag("")
                    Divider()
                    ForEach(Self.methods, id: \.self) { method in
                        Text(method).tag(method)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            GridRow {
                Text("Host").foregroundStyle(.secondary)
                TextField("Host", text: $draft.host, prompt: Text("Any host"))
                    .labelsHidden()
                    .font(.body.monospaced())
                Text("Path").foregroundStyle(.secondary)
                TextField("Path", text: $draft.path, prompt: Text("Any path"))
                    .labelsHidden()
                    .font(.body.monospaced())
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            CodeEditor(text: $draft.code, focusLine: problemLine)
                .background(Color("CodeBackground"), in: .rect(cornerRadius: 10))
                .clipShape(.rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
            HStack(spacing: 6) {
                if let problem = syntaxProblem ?? draft.problem {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(problem)
                        .lineLimit(2)
                } else if isChecking {
                    Text("Checking…")
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color("StatusSuccess"))
                    Text("No problems")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .font(.callout)
        }
    }

    @ViewBuilder
    private var trySection: some View {
        let requests = matchingRequests
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Try it on").foregroundStyle(.secondary)
                Picker("Request", selection: $trialRequest) {
                    if requests.isEmpty {
                        Text("No matching requests yet").tag(ExchangeID?.none)
                    }
                    ForEach(requests) { summary in
                        Text(Self.describe(summary)).tag(ExchangeID?.some(summary.id))
                    }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(requests.isEmpty)
                Button(isTrying ? "Trying…" : "Try It") { tryIt() }
                    .disabled(trialRequest == nil || isTrying || syntaxProblem != nil)
                Spacer()
            }
            if let trials {
                ScriptTrialResults(trials: trials)
            } else {
                Text("Runs the script on a request captured earlier, and shows what it would change. Nothing is sent.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            if trialRequest == nil {
                trialRequest = requests.first?.id
            }
            #if DEBUG
                let defaults = UserDefaults.standard
                if let title = defaults.string(forKey: DefaultsKey.scriptExample),
                    let example = ScriptExamples.all.first(where: { $0.title == title })
                {
                    useExample(example)
                }
                if defaults.bool(forKey: DefaultsKey.tryScript) {
                    Task {
                        try? await Task.sleep(for: .milliseconds(800))
                        tryIt()
                    }
                }
            #endif
        }
    }

    /// The captured requests the rule matches, newest first.
    private var matchingRequests: [ExchangeSummary] {
        let match = draft.match
        return Array(traffic.all.reversed().lazy.filter { $0.kind == .http && match.matches($0) }.prefix(50))
    }

    /// The line a syntax error is on, to put the insertion point there.
    private var problemLine: Int? {
        guard let problem = syntaxProblem, let range = problem.range(of: #"on line (\d+)"#, options: .regularExpression)
        else { return nil }
        return Int(problem[range].split(separator: " ").last ?? "")
    }

    private static func describe(_ summary: ExchangeSummary) -> String {
        let status = summary.status.map { " · \($0)" } ?? ""
        var address = summary.displayHost + summary.target
        if address.count > 72 {
            address = address.prefix(71) + "…"
        }
        return "\(summary.method) \(address)\(status)"
    }

    private func useExample(_ example: ScriptExamples.Example) {
        draft.code = example.code
        if draft.name.trimmingCharacters(in: .whitespaces).isEmpty {
            draft.name = example.title
        }
    }

    private func tryIt() {
        guard let id = trialRequest else { return }
        isTrying = true
        let code = draft.code
        Task {
            trials = await rules.tryScript(code, on: id)
            isTrying = false
        }
    }

    private func save() {
        guard let rule = draft.rule else { return }
        rules.save(rule)
        // A script you just wrote should run, so scripts come on with it.
        if draft.isNew {
            rules.setOn(true, for: .script)
        }
        rules.editing = nil
    }
}

/// What a script would do, for each part it runs on, with what it printed.
private struct ScriptTrialResults: View {
    let trials: [ScriptTrial]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if trials.isEmpty {
                Text("The request isn't there anymore.")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(trials.enumerated()), id: \.offset) { _, trial in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(trial.part == .request ? "onRequest" : "onResponse")
                            .font(.callout.monospaced().weight(.medium))
                        Text(trial.detail)
                            .foregroundStyle(trial.failed ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                            .textSelection(.enabled)
                    }
                    if !trial.logs.isEmpty {
                        Text(trial.logs.joined(separator: "\n"))
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(6)
                    }
                }
            }
        }
        .font(.callout)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
    }
}

/// What scripts can use, in a few lines.
private struct ScriptReference: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Scripts").font(.headline)
            entry(
                "onRequest(request)",
                "Runs before a matching request goes to the server. Change its method, url, headers or body, or return respond(status, body, headers) to answer it yourself."
            )
            entry(
                "onResponse(response, request)",
                "Runs before a matching response goes back to the app. Change its status, reason, headers or body.")
            entry("request.json, response.json", "A JSON body, parsed. Change it, and the body changes too.")
            entry(
                "headers",
                "Work as in the Fetch API: get, getAll, set, append, delete and has. Go through them with forEach or for…of. Names match in any case."
            )
            entry("shared", "Keeps what you put in it from one run of the script to the next, while Reqly runs.")
            entry("console.log", "Writes to the Overview of the request the script ran on.")
            entry("atob, btoa", "Decode and encode Base64.")
            Text(
                "Each run has 1 second, and can't reach files or the network. A script that fails leaves the traffic as it was."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 420, alignment: .leading)
    }

    private func entry(_ name: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.callout.monospaced().weight(.medium))
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// How many captured requests a rule matches, for a sheet's footer.
private struct MatchCountLabel: View {
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(count > 0 ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                .frame(width: 7, height: 7)
            Text(
                count == 0
                    ? "Matches no requests captured so far"
                    : count >= 50
                        ? "Matches 50 or more requests captured so far"
                        : count == 1 ? "Matches 1 request captured so far" : "Matches \(count) requests captured so far"
            )
            .font(.callout.weight(.medium))
            .foregroundStyle(count > 0 ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
    }
}
