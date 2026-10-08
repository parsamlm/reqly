import AppKit
import BodyKit
import SwiftUI

/// Edits JavaScript in SF Mono, with its syntax colored as you type and line numbers in the
/// margin. Smart quotes, dashes and other substitutions stay off, since they'd break code.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    /// Moves the insertion point to the start of this line, counting from 1, such as the line
    /// a script failed on.
    var focusLine: Int?

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var focusedLine: Int?
        weak var ruler: LineNumberRuler?

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            CodeEditor.highlight(textView)
            ruler?.textDidChange(textView.string)
        }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        let textView = NSTextView(usingTextLayoutManager: true)
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.drawsBackground = false
        textView.font = CodeStyle.font
        textView.textContainerInset = CodeStyle.inset
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.typingAttributes = Self.baseAttributes
        textView.setAccessibilityLabel("Script")
        textView.delegate = context.coordinator
        textView.string = text
        Self.highlight(textView)
        scrollView.documentView = textView

        let ruler = LineNumberRuler(textView: textView)
        ruler.textDidChange(text)
        context.coordinator.ruler = ruler
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            // Text set from outside, such as an example: one step to undo.
            textView.undoManager?.beginUndoGrouping()
            if textView.shouldChangeText(
                in: NSRange(location: 0, length: (textView.string as NSString).length), replacementString: text)
            {
                textView.string = text
                textView.didChangeText()
            }
            textView.undoManager?.endUndoGrouping()
            Self.highlight(textView)
            context.coordinator.ruler?.textDidChange(text)
        }
        if let focusLine, focusLine != context.coordinator.focusedLine {
            context.coordinator.focusedLine = focusLine
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let offset = lines.prefix(max(0, focusLine - 1)).reduce(0) { $0 + ($1 as Substring).utf16.count + 1 }
            let location = min(offset, (text as NSString).length)
            textView.setSelectedRange(NSRange(location: location, length: 0))
            textView.scrollRangeToVisible(NSRange(location: location, length: 0))
            textView.window?.makeFirstResponder(textView)
        } else if focusLine == nil {
            context.coordinator.focusedLine = nil
        }
    }

    private static var baseAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = CodeStyle.lineHeight
        paragraph.maximumLineHeight = CodeStyle.lineHeight
        return [.font: CodeStyle.font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
    }

    /// Colors the whole script again; scripts are short enough for that on every keystroke.
    static func highlight(_ textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let text = storage.string
        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: whole)
        for token in JavaScriptSyntax.tokens(in: text) where token.location + token.length <= storage.length {
            storage.addAttribute(
                .foregroundColor, value: CodeStyle.color(for: token.kind),
                range: NSRange(location: token.location, length: token.length))
        }
        storage.endEditing()
        textView.typingAttributes = baseAttributes
    }

    /// The editor fills the space it's given.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}
