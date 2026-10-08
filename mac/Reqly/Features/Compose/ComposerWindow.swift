import ReqlyModel
import SwiftUI

/// A window for writing a request and sending it. The response shows beside it, and the
/// request is recorded in the list like any other.
struct ComposerWindow: View {
    @Environment(AppModel.self) private var model
    let draftID: UUID?
    @State private var draft: ComposerDraft?

    var body: some View {
        if let draft {
            ComposerView(draft: draft)
                .onDisappear {
                    model.composer.close(draft.id)
                }
        } else {
            // A view that's there from the start, so it appears and finds the draft.
            Color.clear
                .onAppear {
                    draft = model.composer.draft(draftID)
                }
        }
    }
}

private struct ComposerView: View {
    @Environment(AppModel.self) private var model
    @Bindable var draft: ComposerDraft

    private static let commonMethods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]

    /// The common methods, and the draft's own if it's another one.
    private var methods: [String] {
        Self.commonMethods.contains(draft.method) ? Self.commonMethods : [draft.method] + Self.commonMethods
    }

    var body: some View {
        HSplitView {
            editor
                .frame(minWidth: 420, idealWidth: 540, maxWidth: .infinity, maxHeight: .infinity)
            response
                .frame(minWidth: 360, idealWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(title)
        #if DEBUG
            .onAppear {
                if DebugLaunch.sendsComposed, draft.sent == nil {
                    send()
                }
            }
        #endif
    }

    private var title: String {
        let path = URL(string: draft.url)?.path() ?? ""
        return path.isEmpty ? "New Request" : "\(draft.method) \(path)"
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Picker("Method", selection: $draft.method) {
                    ForEach(methods, id: \.self) {
                        Text($0).tag($0)
                    }
                }
                .labelsHidden()
                .fixedSize()
                TextField("URL", text: $draft.url, prompt: Text("https://api.example.com/path"))
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .onSubmit(send)
                Button("Send", action: send)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .help("Send (⌘↩)")
            }
            .padding(12)
            if let problem = draft.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    headers
                    requestBody
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var headers: some View {
        DetailSection("Headers", count: draft.headers.filter(\.isOn).count) {
            ForEach($draft.headers) { $header in
                HStack(spacing: 8) {
                    Toggle("Send This Header", isOn: $header.isOn)
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .help("Send this header")
                    TextField("Name", text: $header.name)
                        .frame(width: 170)
                    TextField("Value", text: $header.value)
                    Button("Remove Header", systemImage: "minus.circle") {
                        draft.headers.removeAll { $0.id == header.id }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Remove Header")
                }
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
                .opacity(header.isOn ? 1 : 0.6)
                .padding(.vertical, 3)
            }
            Button("Add Header", systemImage: "plus") {
                draft.headers.append(EditableHeader(name: "", value: ""))
            }
            .buttonStyle(.borderless)
            .padding(.top, 6)
            Text("Reqly sets Host and Content-Length from the URL and the body.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }

    private var requestBody: some View {
        DetailSection("Body") {
            if let binary = draft.binaryBody {
                HStack(spacing: 12) {
                    Text("This body isn't text: \(Format.bytes(binary.count)). It's sent as it was.")
                        .foregroundStyle(.secondary)
                    Button("Remove Body") {
                        draft.binaryBody = nil
                    }
                }
                .font(.callout)
            } else {
                TextEditor(text: $draft.body)
                    .font(.callout.monospaced())
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 200)
                    .background(Color("CodeBackground"), in: .rect(cornerRadius: 10))
            }
        }
    }

    @ViewBuilder
    private var response: some View {
        if let sent = draft.sent {
            InspectorView(exchangeID: sent)
        } else {
            ContentUnavailableView(
                "Nothing Sent Yet",
                systemImage: "paperplane",
                description: Text("Send the request to see its response here. Reqly records it in the list too.")
            )
        }
    }

    private func send() {
        guard let request = draft.request() else { return }
        Task {
            draft.sent = await model.send(request)
        }
    }
}
