import BodyKit
import Foundation

/// Which nodes of a body's tree show, as the Mac's tree has it: the root and its children open
/// at first, and with a filter, the nodes it matches and the nodes above them, all open. The
/// view opens the rest as you do, so only the filter looks at every node.
enum TreeRows {
    /// The root, and those of its children that hold others: the nodes that start open. A root
    /// with more children than `most` opens alone, so a long array doesn't open every one of its
    /// items at once.
    static func opened(_ tree: any ValueOutline, most: Int = 500) -> [Int] {
        guard tree.count > 0 else { return [] }
        let children = tree.node(0).children
        guard children.count <= most else { return [0] }
        return [0] + children.filter { !tree.node($0).children.isEmpty }
    }

    /// The nodes `query` keeps: each whose key matches it, or whose value does, for a node that
    /// holds no others, and every node above them, so each match shows where it is. `nil` when
    /// the query is empty, which keeps them all.
    static func kept(_ tree: any ValueOutline, by query: String) -> Set<Int>? {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return nil }
        var kept: Set<Int> = []
        for id in 0..<tree.count {
            let node = tree.node(id)
            let matches =
                node.label.localizedCaseInsensitiveContains(query)
                || (node.children.isEmpty && node.summary.localizedCaseInsensitiveContains(query))
            guard matches else { continue }
            var current: Int? = id
            while let node = current, kept.insert(node).inserted {
                current = tree.node(node).parent
            }
        }
        return kept
    }

    /// A node's children that show: all of them, or those `kept`.
    static func children(of id: Int, in tree: any ValueOutline, kept: Set<Int>?) -> [Int] {
        let children = tree.node(id).children
        guard let kept else { return children }
        return children.filter { kept.contains($0) }
    }

    /// A row as a screen reader says it, as one: its key, its value and its type, such as
    /// "city, “Tehran”, string".
    static func words(_ node: OutlineNode) -> String {
        [node.label, node.summary, node.typeName].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}
