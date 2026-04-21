import SwiftUI
import AppKit

/// An NSTextView wrapper that reports its content height to SwiftUI,
/// enabling a growing input field clamped between min and max heights.
///
/// Modelled after Bob's `TextView` — uses NSScrollView + NSTextView with
/// `layoutManager.usedRect()` for accurate content-height measurement.
struct GrowingTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var contentHeight: CGFloat
    @Binding var isFocused: Bool
    var font: NSFont = .systemFont(ofSize: NSFont.systemFontSize)
    var onReturn: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        if let scroller = scrollView.verticalScroller {
            scroller.controlSize = .mini
        }
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = _GrowingBackingTextView()
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.font = font
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 0, height: 6)
        textView.textContainer?.lineFragmentPadding = 4
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? _GrowingBackingTextView else { return }
        context.coordinator.parent = self
        if textView.string != text {
            textView.string = text
        }
        textView.font = font
        context.coordinator.scheduleRecalcHeight()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GrowingTextView
        weak var textView: _GrowingBackingTextView?

        init(_ parent: GrowingTextView) {
            self.parent = parent
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.isFocused = true
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.isFocused = false
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            recalcHeight()
        }

        /// Called from updateNSView — defers to avoid modifying state during view update.
        func scheduleRecalcHeight() {
            DispatchQueue.main.async { [weak self] in
                self?.recalcHeight()
            }
        }

        func recalcHeight() {
            guard let textView, let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            let newHeight = ceil(usedRect.height) + textView.textContainerInset.height * 2
            if abs(parent.contentHeight - newHeight) > 0.5 {
                parent.contentHeight = newHeight
            }
        }
    }
}

// MARK: - _GrowingBackingTextView

final class _GrowingBackingTextView: NSTextView {
    weak var coordinator: GrowingTextView.Coordinator?

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            DispatchQueue.main.async { [weak self] in
                self?.updateInsertionPointStateAndRestartTimer(true)
            }
        }
        return result
    }

    override func keyDown(with event: NSEvent) {
        // Return without Shift triggers send; Shift+Return inserts newline.
        // Skip when IME composition is in progress — Return must confirm the
        // marked text instead of submitting.
        if event.keyCode == 36
            && !event.modifierFlags.contains(.shift)
            && !hasMarkedText() {
            coordinator?.parent.onReturn?()
            return
        }
        super.keyDown(with: event)
    }
}
