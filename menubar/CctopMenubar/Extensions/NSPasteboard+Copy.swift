import AppKit

extension NSPasteboard {
    /// Replaces the general pasteboard's contents with `string`.
    static func copyToClipboard(_ string: String) {
        general.clearContents()
        general.setString(string, forType: .string)
    }
}
