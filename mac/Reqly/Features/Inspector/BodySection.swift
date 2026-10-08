import AppKit
import BodyKit
import ReqlyModel
import SwiftUI

/// The ways to look at a body. Which ones a body offers depends on what it holds.
nonisolated enum BodyMode: Hashable, Sendable {
    case formatted, tree, raw, preview, form, hex
}

/// What reading a protobuf body takes: the types of the `.proto` files, and which of them the
/// body holds, when that's known.
nonisolated struct ProtobufReading: Sendable {
    var schema: ProtobufSchema
    /// The request's path, which names a gRPC call's method, such as `/weather.v1.Forecasts/Get`.
    var path: String?
    var isRequest: Bool
    /// The message type chosen for bodies like this one.
    var chosenType: String?

    /// The type to read a message as: the one chosen, the one the method takes or returns,
    /// or the one the `Content-Type` names. `nil` reads it without a schema.
    func messageType(contentType: String?) -> String? {
        if let chosenType, schema.message(named: chosenType) != nil {
            return chosenType
        }
        if let path, let method = schema.method(forPath: path) {
            return isRequest ? method.input : method.output
        }
        if let named = BodyKind.protobufMessageType(contentType), schema.message(named: named) != nil {
            return named
        }
        return nil
    }
}

/// A body made ready to show: unpacked, recognized, and laid out for each way of viewing it.
/// It's made in the background, since formatting a big body takes a moment.
nonisolated struct BodyPresentation: Sendable {
    /// Text past this isn't shown, so the view stays quick.
    static let displayLimit = 16 << 20
    /// Bodies past this aren't formatted, shown as a tree or read as forms.
    static let formatLimit = 8 << 20

    var kind: BodyKind
    /// The body as the app received it: unpacked when it came compressed.
    var content: Data
    var wireSize: Int
    /// The encoding the body was unpacked from, such as gzip.
    var unpackedFrom: String?
    /// Why the body is shown differently than its type suggests, such as JSON that isn't valid.
    var note: String?
    var modes: [BodyMode] = [.hex]
    var formatted: Code?
    var raw: Code?
    var tree: (any ValueOutline)?
    var fields: [FormField]?
    var parts: [MultipartPart]?
    /// Whether the text stops at ``displayLimit``.
    var isTruncated = false
    /// The body was read as protobuf messages.
    var readsAsProtobuf = false
    /// The message type a protobuf body was read as, or `nil` when it was read without one.
    var protobufType: String?
    /// How many messages a gRPC body holds.
    var messageCount: Int?
    /// The status at the end of a gRPC-Web response.
    var grpcStatus: GRPCStatus?
    /// More to say below the body, such as a stream that's still going.
    var details: [String] = []

    /// Text to show in a code view, with its line count, which sets the view's height.
    struct Code: Sendable {
        var text: String
        var tokens: [SyntaxToken]
        var isCode: Bool
        /// How many rows the text takes. Code keeps its lines whole; plain text wraps, about
        /// every hundred characters in a detail pane of usual width.
        var rowCount: Int

        init(_ text: String, tokens: [SyntaxToken] = [], isCode: Bool = true) {
            self.text = text
            // Coloring a very long body would take too long.
            self.tokens = text.utf16.count <= HighlightedText.highlightLimit ? tokens : []
            self.isCode = isCode
            var rows = 0
            var lineLength = 0
            for byte in text.utf8 {
                if byte == 0x0A {
                    rows += isCode ? 1 : max(1, (lineLength + 99) / 100)
                    lineLength = 0
                } else if byte & 0xC0 != 0x80 {
                    lineLength += 1
                }
            }
            rowCount = rows + (isCode ? 1 : max(1, (lineLength + 99) / 100))
        }

        init(_ highlighted: HighlightedText) {
            self.init(highlighted.text, tokens: highlighted.tokens)
        }
    }

    init(data: Data, headers: Headers, rootLabel: String, protobuf: ProtobufReading? = nil) {
        wireSize = data.count
        let encoding = headers["Content-Encoding"].flatMap { $0.lowercased() == "identity" ? nil : $0 }
        content = data
        if let encoding {
            if let unpacked = BodyDecoder.decode(data, contentEncoding: encoding) {
                content = unpacked
                unpackedFrom = encoding
            } else {
                note = "Reqly can't unpack \(encoding), or the body is cut short, so it shows the bytes as they came."
                kind = .binary
                return
            }
        }
        let contentType = headers["Content-Type"]
        kind = BodyKind.detect(content, contentType: contentType)
        if case .image = kind {
            modes = [.preview, .hex]
            return
        }
        if kind == .binary {
            return
        }
        if kind == .protobuf || GRPCFraming(contentType: contentType) != nil {
            readProtobuf(headers: headers, rootLabel: rootLabel, reading: protobuf)
            return
        }
        guard let text = text(contentType: contentType) else {
            kind = .binary
            return
        }
        let canFormat = content.count <= Self.formatLimit
        switch kind {
        case .json:
            raw = Code(text, tokens: JSONSyntax.tokens(in: text))
            if canFormat {
                do {
                    let value = try JSONValue.parse(content)
                    formatted = Code(value.formatted())
                    tree = JSONTree(value, rootLabel: rootLabel)
                    modes = [.formatted, .tree, .raw, .hex]
                } catch let error as JSONError {
                    note = "This isn't valid JSON: \(error.message)"
                    modes = [.raw, .hex]
                } catch {
                    modes = [.raw, .hex]
                }
            } else {
                modes = [.raw, .hex]
            }
        case .xml:
            raw = Code(text, tokens: MarkupSyntax.tokens(in: text))
            if canFormat {
                let laidOut = MarkupSyntax.formattedXML(text)
                formatted = Code(laidOut, tokens: MarkupSyntax.tokens(in: laidOut))
                modes = [.formatted, .raw, .hex]
            } else {
                modes = [.raw, .hex]
            }
        case .html:
            raw = Code(text, tokens: MarkupSyntax.tokens(in: text))
            modes = [.raw, .hex]
        case .form:
            raw = Code(text, isCode: false)
            fields = URLEncodedForm.fields(text)
            modes = [.form, .raw, .hex]
        case .multipart(let boundary):
            parts = canFormat ? MultipartForm.parts(content, boundary: boundary) : nil
            modes = parts == nil ? [.hex] : [.form, .hex]
        default:
            raw = Code(text, isCode: false)
            modes = [.raw, .hex]
        }
    }

    /// A protobuf message, or gRPC's messages, as text format and as a tree.
    private mutating func readProtobuf(headers: Headers, rootLabel: String, reading: ProtobufReading?) {
        let contentType = headers["Content-Type"]
        guard content.count <= Self.formatLimit else {
            note = "This body is too big to read as protobuf, so it shows as bytes."
            return
        }
        let schema = reading?.schema ?? ProtobufSchema()
        let type = reading?.messageType(contentType: contentType)
        guard let framing = GRPCFraming(contentType: contentType) else {
            guard let message = Protobuf.decode(content, as: type, schema: schema) else {
                note = "This isn't a protobuf message Reqly can read, so it shows as bytes."
                return
            }
            formatted = Code(message.formatted())
            tree = ProtobufTree(message, rootLabel: rootLabel)
            protobufType = message.typeName
            readsAsProtobuf = true
            modes = [.formatted, .tree, .hex]
            return
        }

        let body = GRPCBody.read(content, framing: framing, encoding: headers["grpc-encoding"])
        messageCount = body.messages.count
        note = body.problem
        if !body.trailers.isEmpty {
            grpcStatus = GRPCStatus(fields: Headers(body.trailers.map { HeaderField(name: $0.name, value: $0.value) }))
        }
        if let end = body.endOfStream {
            details.append("The stream ended with \(end)")
        }
        if body.incompleteBytes > 0 {
            details.append("The body ends partway through a message. It shows once the rest of it arrives.")
        }
        guard !body.messages.isEmpty else { return }
        if GRPCFraming.carriesJSON(contentType) {
            // gRPC can carry JSON messages instead of protobuf ones.
            let values = body.messages.map {
                (try? JSONValue.parse($0.data)) ?? .string(String(decoding: $0.data, as: UTF8.self))
            }
            let value = values.count == 1 ? values[0] : .array(values)
            formatted = Code(value.formatted())
            tree = JSONTree(value, rootLabel: rootLabel)
            modes = [.formatted, .tree, .hex]
            return
        }
        let messages = body.messages.map { Protobuf.decode($0.data, as: type, schema: schema) ?? .unreadable($0.data) }
        formatted = Code(ProtobufMessage.formatted(messages, sizes: body.messages.map(\.wireSize)))
        tree = ProtobufTree(messages: messages, rootLabel: rootLabel)
        protobufType = type
        readsAsProtobuf = true
        modes = [.formatted, .tree, .hex]
    }

    /// The body as text, up to the display limit. A cut at the limit may split a character, so
    /// up to three bytes may go.
    private mutating func text(contentType: String?) -> String? {
        if case .multipart = kind {
            return ""
        }
        isTruncated = content.count > Self.displayLimit
        let shown = content.prefix(Self.displayLimit)
        for trim in 0...(isTruncated ? 3 : 0) {
            if let text = BodyText.decode(shown.dropLast(trim), contentType: contentType) {
                return text
            }
        }
        return nil
    }

    /// What the body's header says about it, such as "gRPC · 3 messages · 1.2 KB".
    @MainActor var summary: String {
        var pieces = [kind.name]
        if let messageCount {
            pieces.append(messageCount == 1 ? "1 message" : "\(messageCount.formatted()) messages")
        }
        pieces.append(Format.size(Int64(wireSize)))
        return pieces.joined(separator: " · ")
    }

    /// The text the copy button copies in a given mode.
    func copyableText(in mode: BodyMode) -> String? {
        switch mode {
        case .formatted, .tree: (formatted ?? raw)?.text
        case .raw, .form: raw?.text
        case .preview, .hex: nil
        }
    }
}

/// Which body, and how much of it, so a growing body is shown again as more of it arrives.
struct BodyID: Hashable {
    var exchange: ExchangeID
    var part: String
    var size: Int
}

extension EnvironmentValues {
    /// How tall a body viewer may grow: about the height of the detail pane, so a long body
    /// scrolls inside its viewer instead of making the pane endless.
    @Entry var bodyViewerHeight: CGFloat = 480
}

/// The body of a request or a response, with a viewer that suits what it holds.
struct BodySection: View {
    let id: BodyID
    let data: Data
    let headers: Headers
    let emptyText: String
    /// What the JSON tree calls its root, such as "Response".
    let rootLabel: String
    let url: URL?

    @Environment(\.bodyViewerHeight) private var maxHeight
    @Environment(ProtobufModel.self) private var protobuf: ProtobufModel?
    @State private var presentation: BodyPresentation?
    @State private var mode = Self.firstMode

    private static var firstMode: BodyMode {
        #if DEBUG
            let modes: [String: BodyMode] = [
                "formatted": .formatted, "tree": .tree, "raw": .raw, "preview": .preview, "form": .form, "hex": .hex,
            ]
            if let name = UserDefaults.standard.string(forKey: DefaultsKey.bodyMode), let mode = modes[name] {
                return mode
            }
        #endif
        return .formatted
    }
    @State private var hexSelection: Range<Int>?

    /// What makes the body be read again: more of it, other `.proto` files, or another
    /// message type chosen for it.
    private struct Reading: Hashable {
        var id: BodyID
        var schemaVersion: Int
        var chosenType: String?
    }

    private var isRequest: Bool { id.part == "request" }
    private var protobufKey: String { ProtobufModel.key(for: url, isRequest: isRequest) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if data.isEmpty {
                Text(emptyText).foregroundStyle(.secondary)
            } else if let presentation, presentation.wireSize == data.count {
                if let note = presentation.note {
                    Label(note, systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if presentation.readsAsProtobuf, presentation.protobufType == nil {
                    SchemaHint()
                }
                viewer(presentation)
                footnote(presentation)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: Reading(id: id, schemaVersion: protobuf?.version ?? 0, chosenType: chosenType)) {
            guard !data.isEmpty else { return }
            let data = data
            let headers = headers
            let rootLabel = rootLabel
            let reading = protobuf.map {
                ProtobufReading(
                    schema: $0.schema, path: url?.path(percentEncoded: false), isRequest: isRequest,
                    chosenType: chosenType)
            }
            let made = await Task.detached(priority: .userInitiated) {
                BodyPresentation(data: data, headers: headers, rootLabel: rootLabel, protobuf: reading)
            }.value
            guard !Task.isCancelled else { return }
            presentation = made
            hexSelection = nil
            if !made.modes.contains(mode) {
                mode = made.modes[0]
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Body").font(.headline)
            if let presentation, !data.isEmpty {
                Text(presentation.summary)
                    .foregroundStyle(.secondary)
                Spacer()
                if presentation.readsAsProtobuf, let protobuf {
                    MessageTypeMenu(protobuf: protobuf, readAs: presentation.protobufType, key: protobufKey)
                }
                if presentation.modes.count > 1 {
                    Picker("View", selection: $mode) {
                        ForEach(presentation.modes, id: \.self) { mode in
                            Text(title(of: mode, in: presentation)).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                }
                Button("Copy Body", systemImage: "doc.on.doc") {
                    copy(presentation)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Copy Body")
            }
        }
    }

    private var chosenType: String? {
        protobuf?.chosenType(for: protobufKey)
    }

    private func title(of mode: BodyMode, in presentation: BodyPresentation) -> String {
        switch mode {
        case .formatted: "Formatted"
        case .tree: "Tree"
        case .raw: presentation.raw?.isCode == false && presentation.kind != .form ? "Text" : "Raw"
        case .preview: "Preview"
        case .form: "Form"
        case .hex: "Hex"
        }
    }

    @ViewBuilder
    private func viewer(_ presentation: BodyPresentation) -> some View {
        switch mode {
        case .formatted, .raw:
            if let code = mode == .formatted ? presentation.formatted : presentation.raw {
                CodeView(
                    id: [AnyHashable(id), AnyHashable(mode)], text: code.text, tokens: code.tokens, isCode: code.isCode
                )
                .frame(
                    height: min(CGFloat(code.rowCount) * CodeStyle.lineHeight + 2 * CodeStyle.inset.height, maxHeight)
                )
                .background(Color("CodeBackground"), in: .rect(cornerRadius: 10))
                .clipShape(.rect(cornerRadius: 10))
            }
        case .tree:
            if let tree = presentation.tree {
                ValueTreeView(tree: tree, maxHeight: maxHeight)
                    .id([AnyHashable(id), AnyHashable(presentation.protobufType)])
            }
        case .preview:
            if case .image(let format) = presentation.kind {
                ImagePreview(data: presentation.content, format: format, url: url)
            }
        case .form:
            FormView(fields: presentation.fields, parts: presentation.parts)
        case .hex:
            VStack(alignment: .leading, spacing: 6) {
                let rows = CGFloat(HexDump.rowCount(forSize: presentation.content.count))
                HexView(id: id, data: presentation.content, selection: $hexSelection)
                    .frame(height: min(rows * HexDocumentView.rowHeight + 16, maxHeight))
                    .background(Color("CodeBackground"), in: .rect(cornerRadius: 10))
                    .clipShape(.rect(cornerRadius: 10))
                HStack {
                    if let hexSelection {
                        Text(
                            "\(Format.bytes(hexSelection.count)) selected at offset \(hexSelection.lowerBound.formatted())"
                        )
                    }
                    Spacer()
                    Text(Format.bytes(presentation.content.count))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        }
    }

    @ViewBuilder
    private func footnote(_ presentation: BodyPresentation) -> some View {
        Group {
            if let status = presentation.grpcStatus {
                Text(
                    "gRPC status: \(status.code) \(status.name)\(status.message.map { ". \($0)" } ?? "")"
                )
            }
            ForEach(presentation.details, id: \.self) { detail in
                Text(detail)
            }
            if let encoding = presentation.unpackedFrom {
                Text(
                    "Unpacked from \(encoding): \(Format.size(Int64(presentation.wireSize))) became \(Format.size(Int64(presentation.content.count)))."
                )
            }
            if presentation.isTruncated {
                Text(
                    "Showing the first \(Format.size(Int64(BodyPresentation.displayLimit))) of \(Format.size(Int64(presentation.content.count)))."
                )
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private func copy(_ presentation: BodyPresentation) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let text = presentation.copyableText(in: mode) {
            pasteboard.setString(text, forType: .string)
        } else if case .image = presentation.kind, let image = NSImage(data: presentation.content) {
            pasteboard.writeObjects([image])
        } else {
            let range = hexSelection ?? 0..<min(presentation.content.count, 1 << 20)
            let bytes = presentation.content[
                presentation.content.startIndex + range.lowerBound..<presentation.content.startIndex + range.upperBound]
            pasteboard.setString(bytes.map { String(format: "%02X", $0) }.joined(separator: " "), forType: .string)
        }
    }
}

/// Chooses the message type a protobuf body is read as, among those in the `.proto` files.
/// The choice holds for bodies like it, such as every response from the same path.
private struct MessageTypeMenu: View {
    let protobuf: ProtobufModel
    /// The type the body was read as.
    let readAs: String?
    let key: String
    @Environment(SettingsNavigation.self) private var settings
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let names = protobuf.schema.messageNames
        Menu {
            Picker("Message Type", selection: choice) {
                Text("Automatic").tag(String?.none)
            }
            .pickerStyle(.inline)
            if !names.isEmpty {
                Divider()
                // Many types are easier to find by package.
                if names.count > 24 {
                    ForEach(packages(of: names), id: \.name) { package in
                        Picker(package.name, selection: choice) {
                            ForEach(package.types, id: \.self) { name in
                                Text(name).tag(String?.some(name))
                            }
                        }
                        .pickerStyle(.menu)
                    }
                } else {
                    Picker("Message Types", selection: choice) {
                        ForEach(names, id: \.self) { name in
                            Text(name).tag(String?.some(name))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            Divider()
            Button("Add .proto Files…") { ProtoFilePanel.choose(for: protobuf) }
            Button("Protobuf Settings…") { settings.open(.protobuf, with: openSettings) }
        } label: {
            Text(readAs.map { $0.split(separator: ".").last.map(String.init) ?? $0 } ?? "No Schema")
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize()
        .help(
            readAs.map { "Read as \($0). Choose another message type." }
                ?? "Fields show by number. Choose a message type.")
    }

    private var choice: Binding<String?> {
        Binding(
            get: { protobuf.chosenType(for: key) },
            set: { protobuf.choose($0, for: key) }
        )
    }

    private func packages(of names: [String]) -> [(name: String, types: [String])] {
        var packages: [String: [String]] = [:]
        for name in names {
            let package = name.split(separator: ".").dropLast().joined(separator: ".")
            packages[package.isEmpty ? "No Package" : package, default: []].append(name)
        }
        return packages.keys.sorted().map { ($0, packages[$0] ?? []) }
    }
}

/// Says why a protobuf body's fields show by number, and how to see their names.
private struct SchemaHint: View {
    @Environment(ProtobufModel.self) private var protobuf: ProtobufModel?

    var body: some View {
        if let protobuf {
            HStack(spacing: 8) {
                Label(
                    protobuf.hasMessageTypes
                        ? "Fields show by number. Choose the body's message type to see their names."
                        : "Fields show by number. Add the .proto files to see their names and types.",
                    systemImage: "info.circle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                if !protobuf.hasMessageTypes {
                    Button("Add .proto Files…") { ProtoFilePanel.choose(for: protobuf) }
                        .controlSize(.small)
                }
            }
        }
    }
}
