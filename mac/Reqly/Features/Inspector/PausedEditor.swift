import BodyKit
import ReqlyModel
import SwiftUI

/// A request or a response held at a breakpoint, as you edit it before it goes on.
struct PausedDraft {
    let original: PausedMessage
    /// The name of the breakpoint's rule.
    let breakpoint: String
    var method = ""
    var url = ""
    var status = ""
    var reason = ""
    var headers: [EditableHeader] = []
    var body = ""
    /// A body that isn't text. It goes on as it was.
    let binaryBody: Data?
    /// Each header as it was, to mark the ones you change.
    let originalHeaders: [UUID: HeaderField]
    /// The body's text as the editor first showed it. A body still the same goes on byte for byte.
    private let originalText: String
    /// Why the message can't go on as it is, after the last try.
    var problem: String?

    /// Reqly sets these from the body as the message goes on, so they aren't for editing.
    static let framingHeaders: Set<String> = ["content-length", "transfer-encoding"]

    init(_ message: PausedMessage, breakpoint: String) {
        original = message
        self.breakpoint = breakpoint
        let fields: Headers
        let data: Data
        switch message {
        case .request(let request, let body):
            method = request.method
            url = request.url?.absoluteString ?? ""
            (fields, data) = (request.headers, body)
        case .response(let response, let body):
            status = String(response.status)
            reason = response.reason
            (fields, data) = (response.headers, body)
        }
        let editable = fields.filter { !Self.framingHeaders.contains($0.name.lowercased()) }
            .map { EditableHeader(name: $0.name, value: $0.value) }
        headers = editable
        originalHeaders = Dictionary(
            uniqueKeysWithValues: editable.map { ($0.id, HeaderField(name: $0.name, value: $0.value)) })
        let contentType = fields["Content-Type"]
        if data.isEmpty {
            binaryBody = nil
            originalText = ""
        } else if let text = BodyText.decode(data, contentType: contentType) {
            // JSON is easier to edit laid out.
            let shown =
                BodyKind.detect(data, contentType: contentType) == .json
                ? ((try? JSONValue.parse(data))?.formatted().text ?? text) : text
            body = shown
            binaryBody = nil
            originalText = shown
        } else {
            binaryBody = data
            originalText = ""
        }
    }

    var part: MessagePart { original.part }

    func isEdited(_ header: EditableHeader) -> Bool {
        guard let original = originalHeaders[header.id] else { return true }
        return original.name != header.name || original.value != header.value
    }

    /// The body to go on with: the original bytes unless you changed the text.
    private var editedBody: Data {
        switch original {
        case .request(_, let data), .response(_, let data):
            if let binaryBody { return binaryBody }
            return body == originalText ? data : Data(body.utf8)
        }
    }

    private var editedHeaders: Headers {
        Headers(
            headers.compactMap { header in
                let name = header.name.trimmingCharacters(in: .whitespaces)
                return name.isEmpty ? nil : HeaderField(name: name, value: header.value)
            })
    }

    /// The message as you edited it, or `nil` with ``problem`` saying what to fix.
    mutating func edited() -> PausedMessage? {
        switch original {
        case .request(let request, _):
            guard let url = URLComponents(string: url.trimmingCharacters(in: .whitespaces)),
                let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                let host = url.host, !host.isEmpty
            else {
                problem = "Enter a URL that starts with http:// or https://."
                return nil
            }
            var edited = request
            edited.method = method
            edited.scheme = scheme
            edited.host = host.lowercased()
            edited.port = url.port ?? (scheme == "https" ? 443 : 80)
            let path = url.percentEncodedPath.isEmpty ? "/" : url.percentEncodedPath
            edited.target = url.percentEncodedQuery.map { "\(path)?\($0)" } ?? path
            var fields = editedHeaders
            // The Host header follows the URL to another server, unless you set it yourself.
            if edited.authority != request.authority, fields["Host"] == request.authority {
                fields = Headers(
                    fields.map {
                        $0.name.lowercased() == "host" ? HeaderField(name: $0.name, value: edited.authority) : $0
                    })
            }
            edited.headers = fields
            problem = nil
            return .request(edited, body: editedBody)
        case .response(let response, _):
            guard let code = Int(status.trimmingCharacters(in: .whitespaces)), (100...599).contains(code) else {
                problem = "Enter a status from 100 to 599."
                return nil
            }
            var edited = response
            edited.status = code
            edited.reason = reason
            edited.headers = editedHeaders
            problem = nil
            return .response(edited, body: editedBody)
        }
    }
}

/// The detail pane while the selected request or response waits at a breakpoint: what it
/// holds, ready to edit, and the choice to continue or cancel.
struct PausedEditor: View {
    @Environment(TrafficListModel.self) private var traffic
    let id: ExchangeID
    let summary: ExchangeSummary?

    private static let methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]

    var body: some View {
        if let draft = traffic.paused[id] {
            VStack(alignment: .leading, spacing: 0) {
                banner(draft)
                if let summary {
                    header(summary)
                }
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if draft.part == .request {
                            requestLine
                        } else {
                            statusLine
                        }
                        headers
                        bodyEditor
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                actions(draft)
            }
        }
    }

    /// The draft being edited. It's gone once the exchange goes on, so the editor shows only
    /// while it's there.
    private var draft: Binding<PausedDraft> {
        Binding(
            get: { traffic.paused[id] ?? Self.gone },
            set: { if traffic.paused[id] != nil { traffic.paused[id] = $0 } }
        )
    }

    private static let gone = PausedDraft(
        .request(RequestHead(method: "GET", scheme: "http", host: "", port: 80, target: "/"), body: Data()),
        breakpoint: "")

    private func banner(_ draft: PausedDraft) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "pause.circle")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Paused by breakpoint “\(draft.breakpoint)”")
                    .font(.body.weight(.semibold))
                Text(waitingText(draft))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.12))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.accentColor.opacity(0.25)).frame(height: 1)
        }
    }

    private func waitingText(_ draft: PausedDraft) -> String {
        let waiting = "The \(draft.part.rawValue) is waiting. Edit it, then continue."
        let others = traffic.paused.count - 1
        switch others {
        case 0: return waiting
        case 1: return waiting + " 1 more is paused."
        default: return waiting + " \(others) more are paused."
        }
    }

    private func header(_ summary: ExchangeSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(summary.method)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                Text(summary.path)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(summary.source.map { "\(summary.displayHost) · \($0.name)" } ?? summary.displayHost)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var requestLine: some View {
        DetailSection("Request") {
            HStack(spacing: 8) {
                Picker("Method", selection: draft.method) {
                    ForEach(methods, id: \.self) { method in
                        Text(method).tag(method)
                    }
                }
                .labelsHidden()
                .fixedSize()
                TextField("URL", text: draft.url)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
            }
        }
    }

    /// The common methods, and the request's own if it's another one.
    private var methods: [String] {
        let method = draft.wrappedValue.method
        return Self.methods.contains(method) ? Self.methods : [method] + Self.methods
    }

    private var statusLine: some View {
        DetailSection("Status") {
            HStack(spacing: 8) {
                TextField("Status", text: draft.status)
                    .font(.callout.monospaced())
                    .frame(width: 64)
                TextField("Reason", text: draft.reason)
            }
            .textFieldStyle(.roundedBorder)
        }
    }

    private var headers: some View {
        DetailSection("Headers", count: draft.wrappedValue.headers.count) {
            ForEach(draft.headers) { $header in
                HStack(spacing: 8) {
                    TextField("Name", text: $header.name)
                        .frame(width: 150)
                    TextField("Value", text: $header.value)
                        .font(.callout.monospaced())
                        .background(
                            draft.wrappedValue.isEdited(header) ? Color.accentColor.opacity(0.12) : .clear,
                            in: .rect(cornerRadius: 5))
                    Button("Remove Header", systemImage: "minus.circle") {
                        draft.wrappedValue.headers.removeAll { $0.id == header.id }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Remove Header")
                }
                .textFieldStyle(.roundedBorder)
                .font(.callout)
                .padding(.vertical, 3)
            }
            Button("Add Header", systemImage: "plus") {
                draft.wrappedValue.headers.append(EditableHeader(name: "", value: ""))
            }
            .buttonStyle(.borderless)
            .padding(.top, 6)
            Text("Reqly sets Content-Length from the body.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }

    private var bodyEditor: some View {
        DetailSection("Body") {
            if let binary = draft.wrappedValue.binaryBody {
                Text("This body isn't text: \(Format.bytes(binary.count)). It goes on as it is.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                TextEditor(text: draft.body)
                    .font(.callout.monospaced())
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 220)
                    .background(Color("CodeBackground"), in: .rect(cornerRadius: 10))
            }
        }
    }

    private func actions(_ draft: PausedDraft) -> some View {
        HStack(spacing: 8) {
            if let problem = draft.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            } else {
                Text("⌘↩ to continue")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel \(draft.part == .request ? "Request" : "Response")") {
                traffic.decide(id, .cancel)
            }
            Button("Continue", action: resume)
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func resume() {
        guard var edited = traffic.paused[id] else { return }
        if let message = edited.edited() {
            traffic.decide(id, .resume(message))
        } else {
            traffic.paused[id] = edited
        }
    }
}
