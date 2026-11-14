import Foundation
import GtkBinding

/// This copy of Reqly as a screen reader such as Orca reads it, through the accessibility bus:
/// linux/scripts/accessibility-tree.py, run with pyatspi while the window answers it. The
/// self-check runs with accessibility on for it, on the bus self-check.sh starts; copies of Reqly
/// that parts start run without, with `GTK_A11Y=none`, unless a part asks.
struct AccessibilityTree {
    /// One element: a window, a button, a row, a label.
    struct Node: Decodable {
        /// How far down from the app it is: the app is 0, and its windows 1.
        var depth: Int
        /// AT-SPI's name for its role, such as "frame", "push button" or "table row".
        var role: String
        var name: String
        var description: String
        /// Such as "focusable", "focused", "selected" and "showing".
        var states: [String]
        /// How many children it has, though only the first ones the reader was told of are read.
        var children: Int
        /// Its place among its parent's children, from 0.
        var index: Int
        /// The names of the elements each relation points to, such as `labelled-by`'s.
        var relations: [String: [String]]
        var attributes: [String: String]
        /// What it says, with `--text`, for an element that has text, such as a label.
        var text: String?

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            depth = try values.decode(Int.self, forKey: .depth)
            role = try values.decode(String.self, forKey: .role)
            name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
            description = try values.decodeIfPresent(String.self, forKey: .description) ?? ""
            states = try values.decodeIfPresent([String].self, forKey: .states) ?? []
            children = try values.decodeIfPresent(Int.self, forKey: .children) ?? 0
            index = try values.decodeIfPresent(Int.self, forKey: .index) ?? -1
            relations = try values.decodeIfPresent([String: [String]].self, forKey: .relations) ?? [:]
            attributes = try values.decodeIfPresent([String: String].self, forKey: .attributes) ?? [:]
            text = try values.decodeIfPresent(String.self, forKey: .text)
        }

        private enum CodingKeys: String, CodingKey {
            case depth, role, name, description, states, children, index, relations, attributes, text
        }

        func has(_ state: String) -> Bool { states.contains(state) }

        /// The element in a line: its role, its name in quotes, its description, its states and
        /// how many children it has.
        var line: String {
            var line = String(repeating: "  ", count: depth) + role
            if !name.isEmpty { line += " “\(name)”" }
            if !description.isEmpty { line += " (\(description))" }
            let shown = states.filter { !["enabled", "sensitive", "showing", "visible"].contains($0) }
            if !shown.isEmpty { line += " [\(shown.joined(separator: ", "))]" }
            if children > 0 { line += ", \(children) children" }
            return line
        }
    }

    /// Every element read, in the order Orca walks them.
    var nodes: [Node]

    /// Reads this copy of Reqly's tree, `depth` elements down at most, and at most `children` of
    /// each element's children, with each element's text if `text`. The window can't change while
    /// it's read, as nothing else runs then, but it answers.
    @MainActor
    static func read(depth: Int = 40, children: Int = 100, text: Bool = false, seconds: Int = 30) async throws -> Self {
        let script = try SelfCheck.checkoutFile("linux/scripts/accessibility-tree.py")
        let arguments = [
            "python3", script.path, "--pid", String(getpid()), "--depth", String(depth), "--children", String(children),
        ]
        let ended = try await Program.run(arguments + (text ? ["--text"] : []), seconds: seconds)
        if let problem = ended.problem {
            throw SelfCheck.Failure("the accessibility tree couldn't be read: \(problem)")
        }
        let decoder = JSONDecoder()
        let nodes = try ended.output.split(separator: "\n").map { line in
            do {
                return try decoder.decode(Node.self, from: Data(line.utf8))
            } catch {
                throw SelfCheck.Failure("the accessibility reader wrote \(line.prefix(200)), which isn't an element")
            }
        }
        return Self(nodes: nodes)
    }

    /// Listens for `seconds` to the events of `kinds` this copy of Reqly sends on the accessibility
    /// bus, such as `object:announcement`, while `meanwhile` runs, and gives each event's line:
    /// its kind, its element's role and name, and what it carried, such as an announcement's words.
    /// The reader takes a moment to start, so `meanwhile` should keep at it, or wait first.
    @MainActor
    static func events(
        _ kinds: [String], seconds: Double, meanwhile: @MainActor () async -> Void
    ) async throws -> [Event] {
        let script = try SelfCheck.checkoutFile("linux/scripts/accessibility-tree.py")
        let listening = Task { @MainActor in
            try await Program.run(
                ["python3", script.path, "--pid", String(getpid()), "--events", String(seconds)] + kinds,
                seconds: Int(seconds.rounded(.up)) + 15)
        }
        await meanwhile()
        let ended = try await listening.value
        if let problem = ended.problem {
            throw SelfCheck.Failure("the accessibility bus's events couldn't be read: \(problem)")
        }
        return try ended.output.split(separator: "\n").map { try JSONDecoder().decode(Event.self, from: Data($0.utf8)) }
    }

    /// An event on the accessibility bus.
    struct Event: Decodable {
        /// Such as "object:announcement".
        var type: String
        /// The role and name of the element it came from.
        var role: String
        var name: String
        /// What it carried, such as an announcement's words.
        var detail: String?

        /// Whether it says a toast of `words`: as Reqly does before libadwaita 1.7, or as
        /// libadwaita does from 1.7, "A toast appeared: Copied".
        func saysToast(_ words: String) -> Bool {
            detail == words || detail?.hasSuffix(": \(words)") == true
        }
    }

    /// The tree in lines, one element each, indented by depth, as a part's notes or a file show it.
    var lines: [String] { nodes.map(\.line) }

    /// The elements under the first one `matches` picks, the one itself first: its subtree.
    func subtree(where matches: (Node) -> Bool) -> [Node] {
        guard let start = nodes.firstIndex(where: matches) else { return [] }
        let depth = nodes[start].depth
        let rest = nodes[(start + 1)...].prefix { $0.depth > depth }
        return [nodes[start]] + rest
    }
}
