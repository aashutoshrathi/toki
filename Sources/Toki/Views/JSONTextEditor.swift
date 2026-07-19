import AppKit
import SwiftUI

// Minimal JSON syntax highlighter over NSTextView - SwiftUI's TextEditor has no rich-text
// hook, and pulling in a dependency for a once-in-a-while config edit box isn't worth it.
struct JSONTextEditor: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont = .monospacedSystemFont(ofSize: 10, weight: .regular)

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = font
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.drawsBackground = false
        textView.string = text
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        Coordinator.applyHighlighting(to: textView.textStorage!, font: font)

        context.coordinator.textView = textView

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
            Coordinator.applyHighlighting(to: textView.textStorage!, font: font)
        }
        context.coordinator.textView = textView
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        weak var textView: NSTextView?

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            Coordinator.applyHighlighting(to: textView.textStorage!, font: textView.font ?? .monospacedSystemFont(ofSize: 10, weight: .regular))
        }

        @MainActor @objc func selectAll(_ sender: Any?) {
            textView?.selectAll(sender)
        }

        // Colors attribute runs in place rather than replacing the string, so the cursor
        // position and undo stack survive re-highlighting on every keystroke.
        static func applyHighlighting(to storage: NSTextStorage, font: NSFont) {
            let fullRange = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes([.foregroundColor: NSColor.labelColor, .font: font], range: fullRange)

            func highlight(_ pattern: String, color: NSColor) {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
                regex.enumerateMatches(in: storage.string, range: fullRange) { match, _, _ in
                    guard let range = match?.range else { return }
                    storage.addAttribute(.foregroundColor, value: color, range: range)
                }
            }

            // Order matters only for readability here, not correctness - each pattern only
            // matches its own token kind, so overlapping recolors can't happen.
            highlight("\"(?:[^\"\\\\]|\\\\.)*\"(?=\\s*:)", color: .systemPurple) // keys
            highlight("\"(?:[^\"\\\\]|\\\\.)*\"(?!\\s*:)", color: .systemGreen) // string values (object values and array elements alike)
            highlight("(?<![\\w\"])-?\\d+(?:\\.\\d+)?(?:[eE][+-]?\\d+)?", color: .systemOrange) // numbers
            highlight("\\btrue\\b|\\bfalse\\b|\\bnull\\b", color: .systemPink) // literals

            storage.endEditing()
        }
    }
}
