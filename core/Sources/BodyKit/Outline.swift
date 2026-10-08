import Foundation

/// How the tree viewer colors a value.
public enum OutlineStyle: Hashable, Sendable {
    case string, number, literal, bytes
    /// An object, an array or a message: a value that holds others.
    case container
}

/// One row of a value outline.
public struct OutlineNode: Hashable, Sendable {
    /// A key, a field's name or number, an index, or the root's label.
    public var label: String
    /// The value itself, or what a container holds, such as "3 keys".
    public var summary: String
    /// The value's type, such as "string" or "Forecast".
    public var typeName: String
    public var style: OutlineStyle
    public var parent: Int?
    public var children: [Int]
    public var depth: Int
}

/// A value laid out as numbered rows, as the tree viewer shows it: the keys and values of
/// JSON, or the fields of protobuf messages. Row 0 is the root.
public protocol ValueOutline: Sendable {
    var count: Int { get }
    func node(_ id: Int) -> OutlineNode
    /// How to reach a row from the root, such as `current.temperature` or `hourly[0].time`.
    func path(to id: Int) -> String
    /// The row's value to copy: a scalar as it reads, or a container formatted as text.
    func copyText(of id: Int) -> String
}

extension JSONTree: ValueOutline {
    public var count: Int { nodes.count }

    public func node(_ id: Int) -> OutlineNode {
        let node = nodes[id]
        let style: OutlineStyle =
            switch node.value {
            case .string: .string
            case .number: .number
            case .bool, .null: .literal
            case .object, .array: .container
            }
        return OutlineNode(
            label: node.label, summary: node.summary, typeName: node.typeName, style: style, parent: node.parent,
            children: node.children, depth: node.depth)
    }

    public func copyText(of id: Int) -> String {
        let value = nodes[id].value
        // A string is copied without the quotes and escapes JSON puts around it.
        if case .string(let text) = value {
            return text
        }
        return value.scalarText ?? value.formatted().text
    }
}
