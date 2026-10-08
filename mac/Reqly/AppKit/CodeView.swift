import AppKit
import BodyKit
import SwiftUI

/// The font and colors for code, as the design guidelines give them.
enum CodeStyle {
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let lineNumberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    /// Every line is this tall, so a body's height follows from its line count.
    static let lineHeight: CGFloat = 17
    static let inset = NSSize(width: 4, height: 10)

    static func color(for kind: SyntaxKind) -> NSColor {
        switch kind {
        case .key: named("CodeKey")
        case .string, .attributeValue: named("CodeString")
        case .number, .tag: named("CodeNumber")
        // Keywords and literals share a color, as Xcode has them.
        case .literal, .attribute, .keyword: named("CodeLiteral")
        case .comment: .tertiaryLabelColor
        }
    }

    /// The color for punctuation in code. Plain text uses the normal text color instead.
    static var punctuation: NSColor { named("CodePunctuation") }

    static func attributed(_ text: String, tokens: [SyntaxToken], isCode: Bool) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: font, .foregroundColor: isCode ? punctuation : NSColor.labelColor, .paragraphStyle: paragraph,
            ]
        )
        let length = attributed.length
        attributed.beginEditing()
        for token in tokens where token.location + token.length <= length {
            attributed.addAttribute(
                .foregroundColor, value: color(for: token.kind),
                range: NSRange(location: token.location, length: token.length))
        }
        attributed.endEditing()
        return attributed
    }

    private static func named(_ name: String) -> NSColor {
        NSColor(named: name) ?? .labelColor
    }
}

/// Shows code or text in SF Mono, with its syntax colored and line numbers in the margin.
/// TextKit 2 lays out only what's on screen, so long bodies stay quick.
struct CodeView: NSViewRepresentable {
    /// Identifies the content, so the text is set only when it changes.
    let id: AnyHashable
    let text: String
    let tokens: [SyntaxToken]
    var isCode = true
    /// What VoiceOver calls the text.
    var accessibilityName = "Body"

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var shown: AnyHashable?
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = NSTextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = CodeStyle.inset
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.setAccessibilityLabel(accessibilityName)
        setWrapping(!isCode, in: textView, scrollView: scrollView)
        scrollView.documentView = textView

        scrollView.verticalRulerView = LineNumberRuler(textView: textView)
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard context.coordinator.shown != id, let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.shown = id
        setWrapping(!isCode, in: textView, scrollView: scrollView)
        textView.textStorage?.setAttributedString(CodeStyle.attributed(text, tokens: tokens, isCode: isCode))
        (scrollView.verticalRulerView as? LineNumberRuler)?.textDidChange(text)
        textView.scroll(.zero)
    }

    /// Code keeps its lines whole and scrolls sideways, as in Xcode. Plain text wraps.
    private func setWrapping(_ wraps: Bool, in textView: NSTextView, scrollView: NSScrollView) {
        textView.isHorizontallyResizable = !wraps
        textView.textContainer?.widthTracksTextView = wraps
        if !wraps {
            textView.textContainer?.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        }
        scrollView.hasHorizontalScroller = !wraps
    }

    /// The view fills the space it's given, so SwiftUI never needs to measure its text.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

/// Numbers the lines of a code view. A line that wraps keeps one number, on its first row.
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    /// Where each line starts, in UTF-16 code units.
    private var lineStarts: [Int] = [0]

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: nil, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 32
        NotificationCenter.default.addObserver(
            self, selector: #selector(refresh), name: NSView.frameDidChangeNotification, object: textView)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) isn't used")
    }

    // Top down, like the text it numbers.
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Redraw the numbers as the text scrolls.
        if let clipView = scrollView?.contentView {
            clipView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(refresh), name: NSView.boundsDidChangeNotification, object: clipView)
        }
    }

    @objc private func refresh() {
        needsDisplay = true
    }

    func textDidChange(_ text: String) {
        var starts = [0]
        var offset = 0
        for unit in text.utf16 {
            offset += 1
            if unit == 0x0A {
                starts.append(offset)
            }
        }
        lineStarts = starts
        let digits = String(starts.count).count
        let digitWidth = "0".size(withAttributes: [.font: CodeStyle.lineNumberFont]).width
        ruleThickness = max(32, (CGFloat(digits) * digitWidth + 18).rounded())
        needsDisplay = true
    }

    // The margin draws only its numbers, on the code view's own background.
    override func draw(_ dirtyRect: NSRect) {
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.textLayoutManager,
            let content = layoutManager.textContentManager
        else { return }
        let visible = textView.visibleRect
        let origin = textView.textContainerOrigin
        let attributes: [NSAttributedString.Key: Any] = [
            .font: CodeStyle.lineNumberFont, .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let start =
            layoutManager.textViewportLayoutController.viewportRange?.location
            ?? layoutManager.documentRange.location
        layoutManager.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.minY + origin.y > visible.maxY { return false }
            if frame.maxY + origin.y < visible.minY { return true }
            let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            let number = String(self.line(at: offset) + 1)
            let size = number.size(withAttributes: attributes)
            let top = self.convert(NSPoint(x: 0, y: frame.minY + origin.y), from: textView).y
            let y = top + ((CodeStyle.lineHeight - size.height) / 2).rounded()
            number.draw(at: NSPoint(x: self.ruleThickness - size.width - 8, y: y), withAttributes: attributes)
            return true
        }
    }

    /// The zero-based line that holds `offset`.
    private func line(at offset: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= offset {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return low
    }
}
