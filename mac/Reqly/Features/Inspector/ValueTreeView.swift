import AppKit
import BodyKit
import SwiftUI

/// Which rows of a value tree show: the open nodes, or the ones the filter matches.
@Observable
final class ValueTreeModel {
    let tree: any ValueOutline
    private(set) var expanded: Set<Int>
    private(set) var rows: [Int] = []

    var filter = "" {
        didSet { if filter != oldValue { rebuild() } }
    }

    init(tree: any ValueOutline) {
        self.tree = tree
        // The root and its children start open, as in the design.
        var expanded: Set<Int> = [0]
        for child in tree.count > 0 ? tree.node(0).children : [] where !tree.node(child).children.isEmpty {
            expanded.insert(child)
        }
        self.expanded = expanded
        rebuild()
    }

    func toggle(_ id: Int) {
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            expanded.insert(id)
        }
        rebuild()
    }

    private func rebuild() {
        let query = filter.trimmingCharacters(in: .whitespaces)
        var shown: Set<Int>?
        if !query.isEmpty {
            // Matches, and the nodes above them, so each match shows where it is.
            var matched: Set<Int> = []
            for id in 0..<tree.count {
                let node = tree.node(id)
                let matches =
                    node.label.localizedCaseInsensitiveContains(query)
                    || (node.children.isEmpty && node.summary.localizedCaseInsensitiveContains(query))
                guard matches else { continue }
                var current: Int? = id
                while let node = current, matched.insert(node).inserted {
                    current = tree.node(node).parent
                }
            }
            shown = matched
        }
        var rows: [Int] = []
        var pending = tree.count > 0 ? [0] : []
        while let id = pending.popLast() {
            if let shown, !shown.contains(id) { continue }
            rows.append(id)
            let isOpen = shown != nil || expanded.contains(id)
            if isOpen {
                pending.append(contentsOf: tree.node(id).children.reversed())
            }
        }
        self.rows = rows
    }
}

/// A JSON or protobuf body as an outline: keys or fields, values and their types, with a
/// filter and the path to the selected value.
struct ValueTreeView: View {
    let maxHeight: CGFloat
    @State private var model: ValueTreeModel
    @State private var selection: Int?

    private static let rowHeight: CGFloat = 24

    init(tree: any ValueOutline, maxHeight: CGFloat) {
        self.maxHeight = maxHeight
        _model = State(initialValue: ValueTreeModel(tree: tree))
    }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                TextField("Filter keys and values", text: $model.filter)
                    .textFieldStyle(.plain)
            }
            .font(.callout)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 7))

            List(model.rows, id: \.self, selection: $selection) { id in
                ValueTreeRow(
                    node: model.tree.node(id),
                    isExpanded: model.expanded.contains(id) || !model.filter.isEmpty,
                    toggle: { model.toggle(id) }
                )
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, Self.rowHeight)
            .frame(height: min(max(CGFloat(model.rows.count) * Self.rowHeight + 8, 96), maxHeight))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))

            if let selection, selection < model.tree.count {
                pathBar(for: selection)
            }
        }
    }

    private func pathBar(for id: Int) -> some View {
        let node = model.tree.node(id)
        let path = model.tree.path(to: id)
        return HStack(spacing: 12) {
            Text(path.isEmpty ? node.label : path)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Copy Path") { Self.copy(path) }
            Button("Copy Value") { Self.copy(model.tree.copyText(of: id)) }
        }
        .buttonStyle(.link)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct ValueTreeRow: View {
    let node: OutlineNode
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Spacer()
                .frame(width: CGFloat(node.depth) * 14)
            if node.children.isEmpty {
                Spacer()
                    .frame(width: 16)
            } else {
                Button(action: toggle) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Collapse \(node.label)" : "Expand \(node.label)")
            }
            Text(node.label)
                .fontWeight(.medium)
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)
            Text(node.summary)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(node.typeName)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 84, alignment: .trailing)
                .help(node.typeName)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }

    private var valueColor: Color {
        switch node.style {
        case .string, .bytes: Color("CodeString")
        case .number: Color("CodeNumber")
        case .literal: Color("CodeLiteral")
        case .container: .secondary
        }
    }
}
