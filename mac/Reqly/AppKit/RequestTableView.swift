import AppKit
import ReqlyModel
import SwiftUI

/// The request list. It's an `NSTableView` because it has to stay smooth with many thousands
/// of live rows. New rows appear without animation, and the list only follows new traffic
/// while it's scrolled to the bottom.
///
/// The table makes the same changes to its rows as the traffic model made to its own, so new
/// traffic costs about as much as the rows it changes, however many there are.
struct RequestTableView: NSViewRepresentable {
    var traffic: TrafficListModel
    /// The version of the rows to show. When it changes, SwiftUI updates the table.
    var rowsVersion: Int
    /// While nothing matches, the table hides and keeps the rows it had, so when rows come
    /// back, as they mostly do when a filter comes off, it changes only the ones that differ.
    var isHidden: Bool
    @Binding var selection: ExchangeID?
    var actions: RowActions

    /// What the menu on a row can do with its exchange.
    struct RowActions {
        var copyURL: (ExchangeID) -> Void
        var copyCurl: (ExchangeID) -> Void
        var copyResponseBody: (ExchangeID) -> Void
        var resend: (ExchangeID) -> Void
        var editAndResend: (ExchangeID) -> Void
        var exportHAR: (ExchangeID) -> Void
        var togglePin: (ExchangeID) -> Void
        var setColor: (MarkColor?, ExchangeID) -> Void
        var editComment: (ExchangeID) -> Void
        /// Opens the Rules window on a new rule of a kind, filled in from the request.
        var addRule: (RuleKind, ExchangeID) -> Void
        /// Decrypting a request's host, or stopping. Without it, as in a file's window, the
        /// menu leaves the item out.
        var decryption: Decryption?
    }

    struct Decryption {
        var isDecrypting: (String) -> Bool
        var toggle: (String) -> Void
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(traffic: traffic, selection: $selection, actions: actions)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .fullWidth
        table.rowHeight = 24
        table.intercellSpacing = NSSize(width: 8, height: 0)
        table.usesAlternatingRowBackgroundColors = true
        table.allowsColumnReordering = false
        // FillingScrollView sizes the request column itself; AppKit's autoresizing would fight it.
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.setAccessibilityLabel("Requests")
        for column in Column.allCases {
            table.addTableColumn(column.makeTableColumn())
        }
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu
        context.coordinator.table = table
        #if DEBUG
            PerfProbe.table = table
        #endif

        let scrollView = FillingScrollView()
        scrollView.flexibleColumn = table.tableColumn(
            withIdentifier: NSUserInterfaceItemIdentifier(Column.request.rawValue))
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        return scrollView
    }

    /// The list fills whatever space its column gives it, so SwiftUI never needs to measure it.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.selection = $selection
        context.coordinator.actions = actions
        context.coordinator.update(selection: selection, isHidden: isHidden)
    }

    enum Column: String, CaseIterable {
        case status, method, request, app, time, duration, size

        var title: String {
            switch self {
            case .status: "Status"
            case .method: "Method"
            case .request: "Request"
            case .app: "App"
            case .time: "Time"
            case .duration: "Duration"
            case .size: "Size"
            }
        }

        var width: CGFloat {
            switch self {
            // Wide enough for "Failed" and "Paused".
            case .status: 70
            case .method: 64
            case .request: 180
            case .app: 96
            case .time: 70
            case .duration: 70
            case .size: 64
            }
        }

        var alignment: NSTextAlignment {
            switch self {
            case .duration, .size: .right
            default: .left
            }
        }

        func makeTableColumn() -> NSTableColumn {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(rawValue))
            column.title = title
            column.width = width
            column.minWidth = self == .request ? 120 : 44
            column.headerCell.alignment = alignment
            // The request column takes whatever width the others leave, so only they can be dragged.
            column.resizingMask = self == .request ? [] : .userResizingMask
            return column
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        let traffic: TrafficListModel
        var selection: Binding<ExchangeID?>
        var actions: RowActions
        weak var table: NSTableView?
        /// The exchanges the table shows, as of `version`. The table asks about rows between
        /// updates too, so it reads them here, not from the model, which may be ahead.
        private var rows: [ExchangeID] = []
        private var version = -1
        /// Set once the table missed changes to the rows, as while it was hidden.
        private var isBehind = false
        /// Set while the list changes rows itself, so those changes don't count as the user's selection.
        private var isUpdating = false

        init(traffic: TrafficListModel, selection: Binding<ExchangeID?>, actions: RowActions) {
            self.traffic = traffic
            self.selection = selection
            self.actions = actions
        }

        func update(selection: ExchangeID?, isHidden: Bool) {
            guard let table, let scrollView = table.enclosingScrollView else { return }
            if isHidden {
                // The table keeps the rows it had while it's hidden, and catches up when rows
                // come back.
                scrollView.isHidden = true
                isBehind = true
                return
            }
            // Back from hiding, it shows the newest requests, as a new table would.
            let wasHidden = scrollView.isHidden
            if wasHidden {
                scrollView.isHidden = false
            }
            isUpdating = true
            defer { isUpdating = false }
            #if DEBUG
                let started = ContinuousClock.now
            #endif

            let oldRows = rows
            let oldCount = rows.count
            let followsNewRows = wasHidden || isScrolledToBottom(table)
            var onlyGrew = true
            var isTrimmed = false
            if version != traffic.rowsVersion {
                let changes = isBehind ? nil : traffic.rowChanges(since: version)
                rows = traffic.rows
                version = traffic.rowsVersion
                if let changes, table.numberOfRows == oldCount {
                    var changed: Set<ExchangeID> = []
                    for case .changed(let ids) in changes {
                        changed.formUnion(ids)
                    }
                    let steps = changes.filter(\.isRowsChange)
                    if steps.count == 2, case .inserted(let added) = steps[0], case .removed(let removed) = steps[1],
                        let between = Self.rows(oldRows, adding: added, thenRemoving: removed, toEndAs: rows)
                    {
                        // Past the session's size limit, the oldest rows go as new ones come.
                        // Adding the new ones and following them first, then taking the old ones
                        // out, moves the rows the table shows instead of making them again.
                        let final = rows
                        rows = between
                        insert(added, after: oldCount)
                        if followsNewRows {
                            table.scrollRowToVisible(rows.count - 1)
                        }
                        rows = final
                        table.removeRows(at: removed, withAnimation: [])
                        isTrimmed = true
                        onlyGrew = false
                    } else {
                        // The changes come in order, each from where the one before left the
                        // rows. Grouping them makes the table swap its header's views in and out
                        // and draw the header again, so a single change, as new traffic mostly
                        // makes, isn't grouped.
                        let isGrouped = steps.count > 1
                        if isGrouped {
                            table.beginUpdates()
                        }
                        for change in steps {
                            switch change {
                            case .removed(let removed):
                                table.removeRows(at: removed, withAnimation: [])
                                onlyGrew = false
                            case .inserted(let inserted):
                                insert(inserted, after: isGrouped ? nil : oldCount)
                            case .changed:
                                break
                            }
                        }
                        if isGrouped {
                            table.endUpdates()
                        }
                    }
                    if table.numberOfRows == rows.count {
                        reload(changed)
                    } else {
                        table.reloadData()
                    }
                } else if table.numberOfRows == oldCount {
                    // A new table, or one that missed changes, as while it was hidden: it still
                    // shows the rows it had, and the model works out how they changed since.
                    let changes = traffic.rowChanges(from: oldRows)
                    table.beginUpdates()
                    for case .removed(let removed) in changes {
                        table.removeRows(at: removed, withAnimation: [])
                        onlyGrew = false
                    }
                    for case .inserted(let inserted) in changes {
                        table.insertRows(at: inserted, withAnimation: [])
                    }
                    table.endUpdates()
                    // The rows that stayed may show something new by now.
                    reloadMadeRows()
                } else {
                    onlyGrew = false
                    table.reloadData()
                }
                traffic.forgetRowChanges(through: version)
                isBehind = false
            }

            let selectedRow = selection.flatMap(traffic.row(of:))
            if let selectedRow {
                if table.selectedRow != selectedRow {
                    table.selectRowIndexes([selectedRow], byExtendingSelection: false)
                }
            } else if table.selectedRow != -1 {
                table.deselectAll(nil)
            }
            if followsNewRows, rows.count > oldCount || wasHidden || isTrimmed, !rows.isEmpty {
                table.scrollRowToVisible(rows.count - 1)
            }
            #if DEBUG
                PerfProbe.tableUpdated(rows: rows.count, grew: onlyGrew, took: .now - started)
            #endif
        }

        /// Puts rows in. When they all go after `count` rows, the rows the table shows already
        /// stay as they are, so they keep their drawing.
        private func insert(_ inserted: IndexSet, after count: Int?) {
            guard let table else { return }
            var kept: [RequestRowView] = []
            if let count, inserted.first == count {
                table.enumerateAvailableRowViews { view, _ in
                    if let view = view as? RequestRowView {
                        view.keepsDrawing = true
                        kept.append(view)
                    }
                }
            }
            table.insertRows(at: inserted, withAnimation: [])
            for view in kept {
                view.keepsDrawing = false
            }
        }

        /// The rows between adding some at the end and removing some of those there before, or
        /// `nil` when the changes aren't only that.
        private static func rows(
            _ old: [ExchangeID], adding added: IndexSet, thenRemoving removed: IndexSet, toEndAs final: [ExchangeID]
        ) -> [ExchangeID]? {
            guard added.first == old.count, added.last == old.count + added.count - 1,
                let lastRemoved = removed.last, lastRemoved < old.count,
                final.count == old.count + added.count - removed.count
            else { return nil }
            return old + final.suffix(added.count)
        }

        /// Shows the latest summaries of rows that stay.
        private func reload(_ changed: Set<ExchangeID>) {
            guard let table, !changed.isEmpty else { return }
            let changedRows = IndexSet(changed.compactMap(traffic.row(of:)))
            guard !changedRows.isEmpty else { return }
            table.reloadData(forRowIndexes: changedRows, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
            // Reloading redraws the cells but not the rows, which carry the color.
            for row in changedRows {
                (table.rowView(atRow: row, makeIfNecessary: false) as? RequestRowView)?.mark =
                    summary(at: row)?.annotation.color
            }
        }

        /// Shows the latest summaries in every row the table has made.
        private func reloadMadeRows() {
            guard let table else { return }
            var made = IndexSet()
            table.enumerateAvailableRowViews { _, row in made.insert(row) }
            guard !made.isEmpty else { return }
            table.reloadData(forRowIndexes: made, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
            table.enumerateAvailableRowViews { rowView, row in
                (rowView as? RequestRowView)?.mark = summary(at: row)?.annotation.color
            }
        }

        /// The summary of the exchange a row shows.
        private func summary(at row: Int) -> ExchangeSummary? {
            rows.indices.contains(row) ? traffic.rowSummary(rows[row]) : nil
        }

        private func isScrolledToBottom(_ table: NSTableView) -> Bool {
            guard let clipView = table.enclosingScrollView?.contentView else { return true }
            return clipView.bounds.maxY >= table.bounds.height - table.rowHeight
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        func tableViewColumnDidResize(_ notification: Notification) {
            (table?.enclosingScrollView as? FillingScrollView)?.scheduleFill()
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isUpdating, let table else { return }
            let row = table.selectedRow
            selection.wrappedValue = rows.indices.contains(row) ? rows[row] : nil
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view =
                tableView.makeView(withIdentifier: RequestRowView.identifier, owner: nil) as? RequestRowView
                ?? RequestRowView()
            view.mark = summary(at: row)?.annotation.color
            return view
        }

        // MARK: The menu on a row

        /// Fills the menu for the row that was clicked, which may not be the selected one.
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table, let summary = summary(at: table.clickedRow) else { return }
            let annotation = summary.annotation
            // An encrypted connection has no request to copy or send.
            let isReadable = summary.kind == .http

            func item(_ title: String, _ action: Selector, enabled: Bool = true) -> NSMenuItem {
                let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
                item.representedObject = summary.id
                return item
            }
            // The Request menu's groups, in its order.
            menu.addItem(item("Copy URL", #selector(copyURL(_:))))
            menu.addItem(item("Copy as cURL", #selector(copyCurl(_:)), enabled: isReadable))
            let hasResponse = isReadable && summary.status != nil
            menu.addItem(item("Copy Response Body", #selector(copyResponseBody(_:)), enabled: hasResponse))
            menu.addItem(item("Export as HAR…", #selector(exportHAR(_:)), enabled: isReadable))
            menu.addItem(.separator())
            menu.addItem(item("Resend", #selector(resend(_:)), enabled: isReadable))
            menu.addItem(item("Edit and Resend…", #selector(editAndResend(_:)), enabled: isReadable))
            menu.addItem(.separator())

            let pin = NSMenuItem(
                title: annotation.isPinned ? "Unpin Request" : "Pin Request", action: #selector(togglePin(_:)),
                keyEquivalent: "")
            pin.representedObject = summary.id
            menu.addItem(pin)

            let colors = NSMenu()
            for color in [nil] + MarkColor.allCases.map(Optional.some) {
                let item = NSMenuItem(title: color?.title ?? "None", action: #selector(setColor(_:)), keyEquivalent: "")
                item.representedObject = ColorChoice(exchange: summary.id, color: color)
                item.image = color?.menuImage
                item.state = color == annotation.color ? .on : .off
                colors.addItem(item)
                if color == nil {
                    colors.addItem(.separator())
                }
            }
            let color = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
            color.submenu = colors
            menu.addItem(color)

            let comment = NSMenuItem(
                title: annotation.comment == nil ? "Add Comment…" : "Edit Comment…",
                action: #selector(editComment(_:)), keyEquivalent: "")
            comment.representedObject = summary.id
            menu.addItem(comment)
            menu.addItem(.separator())

            let rules = NSMenu()
            for kind in RuleKind.rules {
                let rule = NSMenuItem(title: kind.menuTitle, action: #selector(addRule(_:)), keyEquivalent: "")
                rule.representedObject = RuleChoice(exchange: summary.id, kind: kind)
                // An encrypted connection shows only its host, so all a rule can do is block it.
                if !isReadable, kind != .block {
                    rule.action = nil
                }
                rule.target = self
                rules.addItem(rule)
            }
            let addRule = NSMenuItem(title: "Add Rule", action: nil, keyEquivalent: "")
            addRule.submenu = rules
            menu.addItem(addRule)

            // HTTPS is all there is to decrypt, from a tunnel or a request already decrypted.
            if let decryption = actions.decryption, summary.scheme == "https" {
                let host = summary.host
                let decrypt = NSMenuItem(
                    title: decryption.isDecrypting(host) ? "Stop Decrypting \(host)" : "Decrypt \(host)",
                    action: #selector(toggleDecryption(_:)), keyEquivalent: "")
                decrypt.representedObject = host
                menu.addItem(decrypt)
            }

            for item in menu.items + colors.items {
                item.target = self
            }
        }

        private struct ColorChoice {
            var exchange: ExchangeID
            var color: MarkColor?
        }

        private struct RuleChoice {
            var exchange: ExchangeID
            var kind: RuleKind
        }

        @objc private func addRule(_ sender: NSMenuItem) {
            guard let choice = sender.representedObject as? RuleChoice else { return }
            actions.addRule(choice.kind, choice.exchange)
        }

        @objc private func copyURL(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? ExchangeID else { return }
            actions.copyURL(id)
        }

        @objc private func copyCurl(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? ExchangeID else { return }
            actions.copyCurl(id)
        }

        @objc private func copyResponseBody(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? ExchangeID else { return }
            actions.copyResponseBody(id)
        }

        @objc private func resend(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? ExchangeID else { return }
            actions.resend(id)
        }

        @objc private func editAndResend(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? ExchangeID else { return }
            actions.editAndResend(id)
        }

        @objc private func exportHAR(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? ExchangeID else { return }
            actions.exportHAR(id)
        }

        @objc private func toggleDecryption(_ sender: NSMenuItem) {
            guard let host = sender.representedObject as? String else { return }
            actions.decryption?.toggle(host)
        }

        @objc private func togglePin(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? ExchangeID else { return }
            actions.togglePin(id)
        }

        @objc private func setColor(_ sender: NSMenuItem) {
            guard let choice = sender.representedObject as? ColorChoice else { return }
            actions.setColor(choice.color, choice.exchange)
        }

        @objc private func editComment(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? ExchangeID else { return }
            actions.editComment(id)
        }

        // MARK: Cells

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let identifier = tableColumn?.identifier,
                let column = Column(rawValue: identifier.rawValue),
                let summary = summary(at: row)
            else { return nil }
            switch column {
            case .status:
                let cell =
                    tableView.makeView(withIdentifier: identifier, owner: nil) as? StatusCell
                    ?? StatusCell(identifier: identifier)
                cell.show(summary)
                return cell
            case .request:
                let cell =
                    tableView.makeView(withIdentifier: identifier, owner: nil) as? RequestCell
                    ?? RequestCell(identifier: identifier)
                cell.show(summary)
                return cell
            case .app:
                let cell =
                    tableView.makeView(withIdentifier: identifier, owner: nil) as? SourceCell
                    ?? SourceCell(identifier: identifier)
                cell.show(summary.source, device: summary.device)
                return cell
            case .method, .time, .duration, .size:
                let cell =
                    tableView.makeView(withIdentifier: identifier, owner: nil) as? TextCell
                    ?? TextCell(
                        identifier: identifier, alignment: column.alignment, style: column == .method ? .code : .number)
                cell.show(text: Self.text(for: column, summary))
                return cell
            }
        }

        /// What a column says for a request.
        private static func text(for column: Column, _ summary: ExchangeSummary) -> String {
            switch column {
            case .method:
                return summary.method
            case .time:
                return Format.time(summary.started)
            case .duration:
                return Format.duration(summary.duration)
            case .size:
                return summary.bytesReceived > 0 || summary.state == .completed
                    ? Format.size(summary.bytesReceived) : ""
            case .status:
                return StatusCell.look(summary).text
            case .request:
                let text = RequestCell.text(summary)
                return text.host + text.rest
            case .app:
                return SourceCell.name(summary.source, device: summary.device)
            }
        }

        /// Typing selects the next row that starts with what was typed in any column, as the
        /// table does by itself when its cells hold text fields.
        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            guard let identifier = tableColumn?.identifier, let column = Column(rawValue: identifier.rawValue),
                let summary = summary(at: row)
            else { return nil }
            return Self.text(for: column, summary)
        }
    }
}

/// A scroll view whose table gives one column all the width the other columns leave, so the
/// list always fills its space.
final class FillingScrollView: NSScrollView {
    weak var flexibleColumn: NSTableColumn?
    private var fillIsScheduled = false

    override func tile() {
        super.tile()
        scheduleFill()
    }

    /// Resizes the column once the current layout pass is over, never during it. Resizing a
    /// column resizes the table, and doing that mid-pass can make AppKit lay the window out
    /// again and again until it gives up.
    func scheduleFill() {
        guard !fillIsScheduled else { return }
        fillIsScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            fillIsScheduled = false
            fillFlexibleColumn()
        }
    }

    private func fillFlexibleColumn() {
        guard let table = documentView as? NSTableView, let flexible = flexibleColumn else { return }
        let others = table.tableColumns.reduce(0) { $1 === flexible ? $0 : $0 + $1.width }
        let spacing = table.intercellSpacing.width * CGFloat(table.numberOfColumns)
        // Rounded down, so a fraction of a point never makes the table wider than the list.
        let width = max(flexible.minWidth, (contentView.bounds.width - others - spacing).rounded(.down))
        if abs(flexible.width - width) >= 1 {
            flexible.width = width
        }
    }
}

/// A table cell with one line of text, which it draws itself.
///
/// The list has a few hundred cells on screen, and each view in it costs time whenever new
/// traffic makes the list grow, whether it changed or not. So rather than hold a text field, a
/// cell draws its text with one, a label that's never on screen. And it draws again only when
/// what it shows changes, not each time the table reuses it for a row that shows the same.
class ListCell: NSTableCellView {
    /// Draws the text, set up as each kind of cell needs.
    let label = NSTextField(labelWithString: "")
    /// Where the text goes. Subclasses set it as they lay out.
    var textFrame = NSRect.zero {
        didSet {
            guard textFrame != oldValue else { return }
            text.setAccessibilityFrameInParentSpace(textFrame)
            needsDisplay = true
        }
    }
    /// The label's height, which depends only on its font, as it shows one line.
    let textHeight: CGFloat
    /// What VoiceOver reads, as it would read the label.
    private let text = CellText()
    /// What the text says, which tells it apart from other text.
    private var shownText = ""
    /// What the cell showed when it last drew.
    private var drawn: Drawing?

    private struct Drawing: Equatable {
        var text: String
        var frame: NSRect
        var size: NSSize
        var style: NSView.BackgroundStyle
        var appearance: NSAppearance.Name
        var scale: CGFloat
    }

    /// - Parameter setUp: Sets the label up, such as its font, before the cell measures it.
    init(identifier: NSUserInterfaceItemIdentifier, setUp: (NSTextField) -> Void) {
        setUp(label)
        textHeight = label.intrinsicContentSize.height
        super.init(frame: .zero)
        self.identifier = identifier
        text.setAccessibilityElement(true)
        text.setAccessibilityParent(self)
        text.setAccessibilityValue("")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) isn't used")
    }

    /// Shows the text.
    func show(text string: String) {
        guard string != shownText else { return }
        label.stringValue = string
        showing(string, saying: string)
    }

    /// Shows text in more than one style. It's only made when `key`, which tells it apart from
    /// other text, changes.
    func show(_ attributed: @autoclosure () -> NSAttributedString, key: String) {
        guard key != shownText else { return }
        let attributed = attributed()
        label.attributedStringValue = attributed
        showing(key, saying: attributed.string)
    }

    private func showing(_ key: String, saying string: String) {
        shownText = key
        text.setAccessibilityValue(string)
        needsDisplay = true
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            // On a selected row the text turns white, as a label's does.
            guard backgroundStyle != oldValue else { return }
            label.cell?.backgroundStyle = backgroundStyle
            needsDisplay = true
        }
    }

    private var current: Drawing {
        Drawing(
            text: shownText, frame: textFrame, size: bounds.size, style: backgroundStyle,
            appearance: effectiveAppearance.name, scale: layer?.contentsScale ?? 0)
    }

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        // The table asks each cell it reuses to draw again, even when the new row shows the same,
        // such as "GET" or "200". Its drawing is still right then.
        if let drawn, drawn == current, layer?.contents != nil {
            return
        }
        super.setNeedsDisplay(invalidRect)
    }

    // On a screen with another scale, or in dark mode, the text draws again.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        drawn = nil
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        drawn = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        drawn = current
        label.cell?.draw(withFrame: textFrame, in: self)
    }

    override func accessibilityChildren() -> [Any]? {
        [text]
    }
}

/// A cell's text as VoiceOver reads it, which a label on screen would answer for.
private nonisolated final class CellText: NSAccessibilityElement {
    private var string: String {
        accessibilityValue() as? String ?? ""
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .staticText
    }

    // VoiceOver knows the cell by the element the table makes for it, not by the cell view, so
    // that's the parent, as it's a label's.
    override func accessibilityParent() -> Any? {
        super.accessibilityParent().flatMap { NSAccessibility.unignoredAncestor(of: $0) }
    }

    // Pointing at the text finds the cell, as it does with a label, so VoiceOver reads what the
    // cell says too, such as "pinned".
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        accessibilityParent()
    }

    override func accessibilityNumberOfCharacters() -> Int {
        (string as NSString).length
    }

    override func accessibilityVisibleCharacterRange() -> NSRange {
        NSRange(location: 0, length: accessibilityNumberOfCharacters())
    }

    override func accessibilityString(for range: NSRange) -> String? {
        let string = string as NSString
        guard NSMaxRange(range) <= string.length else { return nil }
        return string.substring(with: range)
    }

    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        accessibilityString(for: range).map { NSAttributedString(string: $0) }
    }

    override func accessibilityLine(for index: Int) -> Int {
        0
    }

    override func accessibilityRange(forLine line: Int) -> NSRange {
        line == 0 ? accessibilityVisibleCharacterRange() : NSRange(location: NSNotFound, length: 0)
    }

    override func accessibilityFrame(for range: NSRange) -> NSRect {
        accessibilityFrame()
    }
}

/// The method, time, duration and size columns: their text alone.
final class TextCell: ListCell {
    enum Style {
        case body, code, number
    }

    init(identifier: NSUserInterfaceItemIdentifier, alignment: NSTextAlignment = .left, style: Style = .body) {
        super.init(identifier: identifier) { label in
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.cell?.usesSingleLineMode = true
            label.alignment = alignment
            switch style {
            case .body:
                label.font = .preferredFont(forTextStyle: .body)
            case .code:
                label.font = .monospacedSystemFont(
                    ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular)
                label.textColor = .secondaryLabelColor
            case .number:
                label.font = .monospacedDigitSystemFont(
                    ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)
                label.textColor = .secondaryLabelColor
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) isn't used")
    }

    // Cells lay out with frames, not constraints. That keeps the table out of Auto Layout, so
    // its growing with every new row doesn't make SwiftUI lay the window out again.
    override func layout() {
        super.layout()
        textFrame = NSRect(
            x: 2, y: ((bounds.height - textHeight) / 2).rounded(), width: bounds.width - 4, height: textHeight)
    }
}

extension NSView {
    /// Moves or resizes the view, unless it's there already, which would cost a layout pass for nothing.
    fileprivate func setFrameIfChanged(_ frame: NSRect) {
        if self.frame != frame {
            self.frame = frame
        }
    }
}

/// The SF Symbols the list shows, made once each, so a reused cell showing the same symbol
/// keeps its drawing.
@MainActor
private enum ListSymbols {
    private static var images: [String: NSImage] = [:]

    static func image(_ name: String) -> NSImage? {
        if let image = images[name] {
            return image
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        images[name] = image
        return image
    }
}

/// A row marked with a color: a stripe in it along the leading edge, as Calendar marks events,
/// and a light tint behind the row. The stripe stays while the row is selected, so a marked row
/// never looks like a selected one.
final class RequestRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("RequestRow")

    var mark: MarkColor? {
        didSet {
            if mark != oldValue { needsDisplay = true }
        }
    }

    /// Set while the table adds rows after this one, which leave it as it is.
    var keepsDrawing = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) isn't used")
    }

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        // Adding rows, the table asks every row it shows to draw again, though rows added after
        // one don't change it.
        if keepsDrawing {
            return
        }
        super.setNeedsDisplay(invalidRect)
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard let mark else { return }
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        mark.nsColor.withAlphaComponent(isDark ? 0.14 : 0.1).setFill()
        dirtyRect.fill(using: .sourceOver)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let mark else { return }
        mark.nsColor.setFill()
        NSRect(x: 0, y: 0, width: 4, height: bounds.height).fill()
    }
}

/// The request column: the host and path, then a pin and a speech bubble for requests that
/// are pinned or have a comment. The comment shows as the cell's tooltip.
final class RequestCell: ListCell {
    /// The pin and the speech bubble, made once a request that has them shows. Most never
    /// do, and every view in a row costs something each time a row appears.
    private var pin: NSImageView?
    private var comment: NSImageView?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(identifier: identifier) { label in
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.cell?.usesSingleLineMode = true
            label.font = Self.font
        }
    }

    private func makeIcon(_ name: String) -> NSImageView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        // The cell's own label says it's pinned or has a comment. An image view answers
        // VoiceOver through its cell, so that's what's hidden.
        icon.cell?.setAccessibilityElement(false)
        icon.contentTintColor = iconColor
        addSubview(icon)
        return icon
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) isn't used")
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { tintIcons() }
    }

    /// What the column says for a request: the host, then the rest.
    static func text(_ summary: ExchangeSummary) -> (host: String, rest: String) {
        (summary.displayHost, summary.kind == .tunnel ? "  Encrypted connection" : summary.target)
    }

    func show(_ summary: ExchangeSummary) {
        let (host, rest) = Self.text(summary)
        // The host can't have a line break in it, so this tells each host and rest apart.
        show(Self.text(host: host, rest: rest), key: host + "\n" + rest)
        let annotation = summary.annotation
        if annotation.isPinned, pin == nil {
            pin = makeIcon("pin.fill")
        }
        if annotation.comment != nil, comment == nil {
            comment = makeIcon("text.bubble")
        }
        if let pin, pin.isHidden == annotation.isPinned {
            pin.isHidden = !annotation.isPinned
        }
        if let comment, comment.isHidden != (annotation.comment == nil) {
            comment.isHidden = annotation.comment == nil
        }
        if toolTip != annotation.comment {
            toolTip = annotation.comment
        }
        var description = [host + rest]
        if annotation.isPinned {
            description.append("pinned")
        }
        if let color = annotation.color {
            description.append("marked \(color.title.lowercased())")
        }
        if let note = annotation.comment {
            description.append("comment: \(note)")
        }
        setAccessibilityLabel(description.joined(separator: ", "))
        needsLayout = true
    }

    private static let font = NSFont.preferredFont(forTextStyle: .body)
    private static let attributes: (host: [NSAttributedString.Key: Any], rest: [NSAttributedString.Key: Any]) = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        return (
            [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph],
            [.font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph]
        )
    }()

    /// The host in the normal text color, then the path in secondary color, as in the design.
    private static func text(host: String, rest: String) -> NSAttributedString {
        let text = NSMutableAttributedString(string: host, attributes: attributes.host)
        text.append(NSAttributedString(string: rest, attributes: attributes.rest))
        return text
    }

    private var iconColor: NSColor {
        backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
    }

    private func tintIcons() {
        pin?.contentTintColor = iconColor
        comment?.contentTintColor = iconColor
    }

    // Frames, not constraints, for the same reason as TextCell.
    override func layout() {
        super.layout()
        var trailing = bounds.width - 2
        for case let icon? in [comment, pin] where !icon.isHidden {
            icon.setFrameIfChanged(
                NSRect(x: trailing - 14, y: ((bounds.height - 14) / 2).rounded(), width: 14, height: 14))
            trailing -= 18
        }
        textFrame = NSRect(
            x: 2, y: ((bounds.height - textHeight) / 2).rounded(), width: max(0, trailing - 4), height: textHeight)
    }
}

/// The status column: a colored dot and the status code. The code stays in the normal text
/// color, because orange or red text is too faint to read on a light background.
final class StatusCell: ListCell {
    private let symbol = NSImageView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(identifier: identifier) { label in
            label.font = .monospacedDigitSystemFont(
                ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)
        }
        symbol.symbolConfiguration = .init(pointSize: 8, weight: .regular)
        // The cell's label names the status, so VoiceOver doesn't read the dot as "circle".
        symbol.cell?.setAccessibilityElement(false)
        addSubview(symbol)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) isn't used")
    }

    // Frames, not constraints, for the same reason as TextCell.
    override func layout() {
        super.layout()
        symbol.setFrameIfChanged(NSRect(x: 4, y: ((bounds.height - 12) / 2).rounded(), width: 12, height: 12))
        textFrame = NSRect(
            x: 20, y: ((bounds.height - textHeight) / 2).rounded(), width: max(0, bounds.width - 22),
            height: textHeight)
    }

    /// The dot and the text for a request's status.
    static func look(_ summary: ExchangeSummary) -> (symbol: String, color: NSColor, text: String) {
        switch summary.state {
        case .failed:
            ("exclamationmark.triangle.fill", .systemRed, "Failed")
        case .paused:
            ("pause.circle.fill", .controlAccentColor, "Paused")
        case _ where summary.kind == .tunnel:
            ("lock.fill", .secondaryLabelColor, "")
        case _ where summary.status != nil:
            ("circle.fill", summary.statusClass?.nsColor ?? .systemGray, String(summary.status!))
        default:
            ("circle.dotted", .tertiaryLabelColor, "")
        }
    }

    func show(_ summary: ExchangeSummary) {
        let look = Self.look(summary)
        // A cell the table reuses often shows the same, and keeps its drawing then.
        let image = ListSymbols.image(look.symbol)
        if symbol.image !== image {
            symbol.image = image
        }
        if symbol.contentTintColor != look.color {
            symbol.contentTintColor = look.color
        }
        show(text: look.text)
        setAccessibilityLabel(summary.statusDescription)
        // A gRPC call can fail while its HTTP status is 200; the dot's color says so, and this names it.
        let help = summary.grpcStatus.flatMap { $0 == 0 ? nil : summary.statusDescription }
        if toolTip != help {
            toolTip = help
        }
    }
}

/// The app column: the icon and name of the app or tool that sent the request, or the device's
/// when the app isn't known, as for a phone on the network.
final class SourceCell: ListCell {
    private let icon = NSImageView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(identifier: identifier) { label in
            label.font = .preferredFont(forTextStyle: .body)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.cell?.usesSingleLineMode = true
        }
        icon.imageScaling = .scaleProportionallyUpOrDown
        // The name beside it says which app it is.
        icon.cell?.setAccessibilityElement(false)
        addSubview(icon)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) isn't used")
    }

    // Frames, not constraints, for the same reason as TextCell.
    override func layout() {
        super.layout()
        icon.setFrameIfChanged(NSRect(x: 2, y: ((bounds.height - 16) / 2).rounded(), width: 16, height: 16))
        let x: CGFloat = icon.image == nil ? 2 : 22
        textFrame = NSRect(
            x: x, y: ((bounds.height - textHeight) / 2).rounded(), width: max(0, bounds.width - x - 2),
            height: textHeight)
    }

    /// The name the column shows: the app's, or the device's when the app isn't known.
    static func name(_ source: Source?, device: Device?) -> String {
        if source == nil, let device {
            device.name
        } else {
            source?.name ?? ""
        }
    }

    func show(_ source: Source?, device: Device?) {
        let image: NSImage?
        let tint: NSColor?
        if source == nil, let device {
            image = ListSymbols.image(device.symbol)
            tint = .secondaryLabelColor
        } else if let source {
            // An app on a phone has a plain icon, unless this Mac has the same app.
            let appIcon = SourceIcons.icon(for: source)
            image = appIcon ?? ListSymbols.image("app.dashed")
            tint = appIcon == nil ? .secondaryLabelColor : nil
        } else {
            image = nil
            tint = icon.contentTintColor
        }
        // A cell the table reuses often shows the same app, and keeps its drawing then.
        if icon.image !== image {
            icon.image = image
        }
        if icon.contentTintColor != tint {
            icon.contentTintColor = tint
        }
        show(text: Self.name(source, device: device))
        let help = device.map { device in source.map { "\($0.name) on \(device.fullName)" } ?? device.fullName }
        if toolTip != help {
            toolTip = help
        }
        needsLayout = true
    }
}
