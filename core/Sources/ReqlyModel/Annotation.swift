import Foundation

/// What you've added to an exchange, to find it again: a pin, a color and a comment.
public struct Annotation: Hashable, Sendable, Codable {
    /// Pinned exchanges stay when the session is cleared, and the sidebar lists them.
    public var isPinned: Bool
    public var color: MarkColor?
    /// Never empty: no comment is `nil`.
    public var comment: String?

    public init(isPinned: Bool = false, color: MarkColor? = nil, comment: String? = nil) {
        self.isPinned = isPinned
        self.color = color
        self.comment = comment
    }
}

/// The colors an exchange can be marked with: the ones Finder offers for tags.
public enum MarkColor: String, Hashable, Sendable, Codable, CaseIterable {
    case red, orange, yellow, green, blue, purple, gray
}
