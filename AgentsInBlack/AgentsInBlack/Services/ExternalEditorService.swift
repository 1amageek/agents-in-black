import AppKit
import Foundation

@MainActor
final class ExternalEditorService {
    func open(url: URL) {
        NSWorkspace.shared.open(url)
    }
}
