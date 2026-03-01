import AppKit
import SwiftTerm
import SwiftUI

/// Thin NSViewRepresentable that embeds a `TerminalSession`'s terminal view.
/// The session owns the `LocalProcessTerminalView` and its PTY process —
/// this wrapper only handles embedding and font updates.
struct SwiftTermView: NSViewRepresentable {
    let session: TerminalSession
    @AppStorage(AppSettingsKey.terminalFontSize) private var fontSize = AppSettingsDefault.terminalFontSize

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .zero)

        let terminal = session.terminalView
        terminal.removeFromSuperview()
        terminal.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: container.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        session.startIfNeeded()
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        let newFont = NSFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
        if session.terminalView.font != newFont {
            session.terminalView.font = newFont
        }
    }
}
