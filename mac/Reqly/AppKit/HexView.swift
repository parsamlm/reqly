import AppKit
import BodyKit
import SwiftUI

/// Shows bytes as a hex dump: offsets, sixteen bytes a row in hex, and the same bytes as text.
/// It draws only the rows on screen, so any size of body stays quick. Drag to select bytes, and
/// copy them as hex.
struct HexView: NSViewRepresentable {
    /// Identifies the content, so the bytes are set only when they change.
    let id: AnyHashable
    let data: Data
    @Binding var selection: Range<Int>?

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    final class Coordinator {
        var selection: Binding<Range<Int>?>
        var shown: AnyHashable?

        init(selection: Binding<Range<Int>?>) {
            self.selection = selection
        }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        let document = HexDocumentView()
        scrollView.hasHorizontalScroller = true
        let coordinator = context.coordinator
        document.onSelectionChange = { coordinator.selection.wrappedValue = $0 }
        scrollView.documentView = document
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.selection = $selection
        guard context.coordinator.shown != id, let document = scrollView.documentView as? HexDocumentView else {
            return
        }
        context.coordinator.shown = id
        document.show(data)
        scrollView.contentView.scroll(to: .zero)
    }

    /// The view fills the space it's given, so SwiftUI never needs to measure it.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

final class HexDocumentView: NSView {
    static let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    static let rowHeight: CGFloat = 18
    private static let inset = NSSize(width: 8, height: 8)
    /// The space between the offset, hex and text columns.
    private static let gap: CGFloat = 10
    /// A byte's two digits and a space; there's one more space after the eighth byte.
    private static let hexColumns = HexDump.bytesPerRow * 3 + 1

    var onSelectionChange: ((Range<Int>?) -> Void)?

    private var data = Data()
    private var selection: Range<Int>? {
        didSet {
            needsDisplay = true
            onSelectionChange?(selection)
        }
    }
    private var anchor: Int?
    private let characterWidth = "0".size(withAttributes: [.font: HexDocumentView.font]).width

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// As wide as a row, so a narrow pane scrolls sideways instead of cutting the text column off.
    func show(_ data: Data) {
        self.data = data
        selection = nil
        let rows = CGFloat(HexDump.rowCount(forSize: data.count))
        let width = textX + CGFloat(HexDump.bytesPerRow) * characterWidth + Self.inset.width
        frame = NSRect(x: 0, y: 0, width: width.rounded(.up), height: rows * Self.rowHeight + 2 * Self.inset.height)
        needsDisplay = true
    }

    /// Offsets take six digits below 16 MB, which leaves room for all sixteen bytes in a
    /// detail pane of usual width.
    private var offsetDigits: Int { data.count > 0xFF_FFFF ? 8 : 6 }
    private var hexX: CGFloat { Self.inset.width + CGFloat(offsetDigits) * characterWidth + Self.gap }
    private var textX: CGFloat { hexX + CGFloat(Self.hexColumns - 1) * characterWidth + Self.gap }

    override func draw(_ dirtyRect: NSRect) {
        let rowCount = HexDump.rowCount(forSize: data.count)
        guard rowCount > 0 else { return }
        let first = max(0, Int((dirtyRect.minY - Self.inset.height) / Self.rowHeight))
        let last = min(rowCount - 1, Int((dirtyRect.maxY - Self.inset.height) / Self.rowHeight))
        guard first <= last else { return }
        let offsetStyle: [NSAttributedString.Key: Any] = [
            .font: Self.font, .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let hexStyle: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: NSColor.labelColor]
        let textStyle: [NSAttributedString.Key: Any] = [
            .font: Self.font, .foregroundColor: NSColor.secondaryLabelColor,
        ]
        for row in first...last {
            let y = Self.inset.height + CGFloat(row) * Self.rowHeight
            drawSelection(inRow: row, y: y)
            let line = HexDump.row(row, of: data)
            String(line.offset.suffix(offsetDigits)).draw(
                at: NSPoint(x: Self.inset.width, y: y + 2), withAttributes: offsetStyle)
            line.hex.draw(at: NSPoint(x: hexX, y: y + 2), withAttributes: hexStyle)
            line.text.draw(at: NSPoint(x: textX, y: y + 2), withAttributes: textStyle)
        }
    }

    private func drawSelection(inRow row: Int, y: CGFloat) {
        guard let selection else { return }
        let rowStart = row * HexDump.bytesPerRow
        let start = max(selection.lowerBound, rowStart)
        let end = min(selection.upperBound, rowStart + HexDump.bytesPerRow)
        guard start < end else { return }
        let first = start - rowStart
        let last = end - rowStart - 1
        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
        let hexStart = hexX + CGFloat(Self.hexColumn(of: first)) * characterWidth
        let hexEnd = hexX + CGFloat(Self.hexColumn(of: last) + 2) * characterWidth
        NSBezierPath(
            roundedRect: NSRect(x: hexStart - 2, y: y, width: hexEnd - hexStart + 4, height: Self.rowHeight),
            xRadius: 3, yRadius: 3
        ).fill()
        let textStart = textX + CGFloat(first) * characterWidth
        NSBezierPath(
            roundedRect: NSRect(
                x: textStart, y: y, width: CGFloat(last - first + 1) * characterWidth,
                height: Self.rowHeight), xRadius: 3, yRadius: 3
        ).fill()
    }

    /// The column where a byte's two hex digits start.
    private static func hexColumn(of byte: Int) -> Int {
        byte * 3 + (byte >= 8 ? 1 : 0)
    }

    /// The byte under a point, in the hex or text column, or `nil` between them.
    private func byte(at point: NSPoint) -> Int? {
        let row = Int((point.y - Self.inset.height) / Self.rowHeight)
        let column: Int
        if point.x >= textX {
            column = Int((point.x - textX) / characterWidth)
        } else if point.x >= hexX {
            let position = Int((point.x - hexX) / characterWidth)
            column = position >= 25 ? 8 + (position - 25) / 3 : position / 3
        } else {
            return nil
        }
        guard row >= 0, (0..<HexDump.bytesPerRow).contains(column) else { return nil }
        let byte = row * HexDump.bytesPerRow + column
        return byte < data.count ? byte : nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        anchor = byte(at: convert(event.locationInWindow, from: nil))
        selection = anchor.map { $0..<$0 + 1 }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor, let byte = byte(at: convert(event.locationInWindow, from: nil)) else { return }
        selection = min(anchor, byte)..<max(anchor, byte) + 1
        autoscroll(with: event)
    }

    // The keyboard does what dragging does: the arrow keys move a byte at a time, or a row at a
    // time up and down, and with Shift the selection grows. Page Up and Down, Home and End
    // scroll, and Select All takes every byte.

    override func keyDown(with event: NSEvent) {
        interpretKeyEvents([event])
    }

    override func moveLeft(_ sender: Any?) { move(by: -1, extending: false) }
    override func moveRight(_ sender: Any?) { move(by: 1, extending: false) }
    override func moveUp(_ sender: Any?) { move(by: -HexDump.bytesPerRow, extending: false) }
    override func moveDown(_ sender: Any?) { move(by: HexDump.bytesPerRow, extending: false) }
    override func moveLeftAndModifySelection(_ sender: Any?) { move(by: -1, extending: true) }
    override func moveRightAndModifySelection(_ sender: Any?) { move(by: 1, extending: true) }
    override func moveUpAndModifySelection(_ sender: Any?) { move(by: -HexDump.bytesPerRow, extending: true) }
    override func moveDownAndModifySelection(_ sender: Any?) { move(by: HexDump.bytesPerRow, extending: true) }

    override func selectAll(_ sender: Any?) {
        guard !data.isEmpty else { return }
        anchor = 0
        selection = 0..<data.count
    }

    override func scrollPageUp(_ sender: Any?) { scrollBy(-visibleRect.height) }
    override func scrollPageDown(_ sender: Any?) { scrollBy(visibleRect.height) }
    override func pageUp(_ sender: Any?) { scrollBy(-visibleRect.height) }
    override func pageDown(_ sender: Any?) { scrollBy(visibleRect.height) }
    override func scrollToBeginningOfDocument(_ sender: Any?) { scrollBy(-bounds.height) }
    override func scrollToEndOfDocument(_ sender: Any?) { scrollBy(bounds.height) }

    /// Moves the selection's moving end by `offset` bytes. Without a selection, it starts at the
    /// first byte.
    private func move(by offset: Int, extending: Bool) {
        guard !data.isEmpty else { return }
        let target: Int
        if let selection, let anchor {
            let end = selection.lowerBound == anchor ? selection.upperBound - 1 : selection.lowerBound
            target = min(
                max((extending ? end : offset < 0 ? selection.lowerBound : selection.upperBound - 1) + offset, 0),
                data.count - 1)
        } else {
            target = 0
        }
        if extending, let anchor {
            selection = min(anchor, target)..<max(anchor, target) + 1
        } else {
            anchor = target
            selection = target..<target + 1
        }
        let row = CGFloat(target / HexDump.bytesPerRow)
        scrollToVisible(
            NSRect(x: visibleRect.minX, y: Self.inset.height + row * Self.rowHeight, width: 1, height: Self.rowHeight))
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    private func scrollBy(_ distance: CGFloat) {
        var visible = visibleRect
        visible.origin.y = min(max(visible.minY + distance, 0), max(0, bounds.height - visible.height))
        scrollToVisible(visible)
    }

    // VoiceOver reads the rows in view, as the screen shows them.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilityRoleDescription() -> String? { "hex view" }
    override func accessibilityLabel() -> String? { "Hex, \(Format.bytes(data.count))" }

    override func accessibilityValue() -> Any? {
        let rowCount = HexDump.rowCount(forSize: data.count)
        let first = max(0, Int((visibleRect.minY - Self.inset.height) / Self.rowHeight))
        let last = min(rowCount - 1, Int((visibleRect.maxY - Self.inset.height) / Self.rowHeight))
        guard first <= last else { return "" }
        return (first...last).map { row in
            let line = HexDump.row(row, of: data)
            return "\(line.offset.suffix(offsetDigits)) \(line.hex) \(line.text)"
        }.joined(separator: "\n")
    }

    /// Copies the selected bytes, or all of them, as hex.
    @objc func copy(_ sender: Any?) {
        let range = selection ?? 0..<data.count
        let hex = data[data.startIndex + range.lowerBound..<data.startIndex + range.upperBound]
            .map { String(format: "%02X", $0) }.joined(separator: " ")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hex, forType: .string)
    }
}
