import AppKit
import BodyKit
import Presentation
import ReqlyModel
import SwiftUI

extension BodyPresentation {
    /// What the body's header says about it, such as "gRPC · 3 messages · 1.2 KB".
    @MainActor var summary: String {
        var pieces = [kind.name]
        if let messageCount {
            pieces.append(messageCount == 1 ? "1 message" : "\(messageCount.formatted()) messages")
        }
        pieces.append(Format.size(Int64(wireSize)))
        return pieces.joined(separator: " · ")
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
    private var protobufKey: String { ProtobufFiles.key(for: url, isRequest: isRequest) }

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
