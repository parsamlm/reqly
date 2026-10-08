import AppKit
import BodyKit
import SwiftUI
import UniformTypeIdentifiers

/// The Protobuf pane of Settings: the `.proto` files and folders Reqly reads bodies with, and
/// what it couldn't use in them.
struct ProtobufSettings: View {
    @Environment(ProtobufModel.self) private var protobuf
    @State private var selection: ProtobufModel.Source.ID?

    var body: some View {
        Form {
            Section {
                if protobuf.sources.isEmpty {
                    Text("No .proto files yet. Without them, fields show by their numbers.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    ForEach(protobuf.sources) { source in
                        SourceRow(source: source, fileCount: protobuf.fileCounts[source.id])
                            .contentShape(.rect)
                            .onTapGesture { selection = source.id }
                            .selectedRow(selection == source.id)
                            .accessibilityAddTraits(selection == source.id ? .isSelected : [])
                            .contextMenu {
                                Button("Show in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([source.url])
                                }
                                Divider()
                                Button("Remove") { remove(source.id) }
                            }
                    }
                }
                HStack(spacing: 0) {
                    ListBarButton("Add .proto Files or Folders", systemImage: "plus") {
                        ProtoFilePanel.choose(for: protobuf)
                    }
                    ListBarButton("Remove", systemImage: "minus") {
                        if let selection { remove(selection) }
                    }
                    .disabled(selection == nil)
                    Spacer()
                    if protobuf.isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.trailing, 8)
                    }
                    Button("Reload") { protobuf.reload() }
                        .controlSize(.small)
                        .disabled(protobuf.sources.isEmpty)
                        .help("Read the files again, after you change them")
                }
            } header: {
                Text(".proto Files")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(summary)
                    Text(
                        "Reqly reads protobuf and gRPC bodies with these files, to show each field's name and type. Add a folder to include the files that others import. Reqly reads the files again each time it opens, or when you click Reload."
                    )
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            if !protobuf.problems.isEmpty || protobuf.saveProblem != nil {
                Section("Problems") {
                    if let problem = protobuf.saveProblem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    ForEach(Array(protobuf.problems.prefix(200).enumerated()), id: \.offset) { _, problem in
                        ProblemRow(problem: problem)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onDeleteCommand {
            if let selection { remove(selection) }
        }
    }

    /// What the files hold, such as "14 message types and 2 services".
    private var summary: String {
        let messages = protobuf.schema.messageNames.count
        let services = protobuf.schema.services.count
        guard messages > 0 else { return protobuf.sources.isEmpty ? "" : "These files have no message types yet." }
        let types = messages == 1 ? "1 message type" : "\(messages.formatted()) message types"
        switch services {
        case 0: return "\(types)."
        case 1: return "\(types) and 1 service."
        default: return "\(types) and \(services.formatted()) services."
        }
    }

    private func remove(_ id: ProtobufModel.Source.ID) {
        protobuf.remove([id])
        if selection == id {
            selection = nil
        }
    }
}

private struct SourceRow: View {
    let source: ProtobufModel.Source
    let fileCount: Int?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: source.isFolder ? "folder" : "doc.text")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.url.lastPathComponent)
                    .lineLimit(1)
                Text((source.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(countText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var countText: String {
        switch fileCount {
        case nil, 0?: "Missing"
        case 1?: "1 file"
        case let count?: "\(count.formatted()) files"
        }
    }
}

private struct ProblemRow: View {
    let problem: ProtoFileProblem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(problem.line > 0 ? "\(problem.file), line \(problem.line)" : problem.file)
                .font(.callout.weight(.medium))
            Text(problem.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .textSelection(.enabled)
    }
}

/// The open panel for adding `.proto` files and folders of them.
enum ProtoFilePanel {
    static func choose(for protobuf: ProtobufModel) {
        let panel = NSOpenPanel()
        panel.message = "Choose .proto files, or folders that hold them."
        panel.prompt = "Add"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "proto") ?? .plainText, .folder]
        panel.begin { response in
            guard response == .OK else { return }
            protobuf.add(panel.urls)
        }
    }
}
