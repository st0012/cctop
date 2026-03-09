import AppKit

extension NSScreen {
    /// Whether this screen has a physical camera notch.
    var hasPhysicalNotch: Bool {
        safeAreaInsets.top > 0
    }

    /// The CGDirectDisplayID for this screen, extracted from device description.
    private var displayID: CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return deviceDescription[key] as? CGDirectDisplayID ?? 0
    }

    /// Whether this is the built-in (laptop) display.
    var isBuiltinDisplay: Bool {
        CGDisplayIsBuiltin(displayID) != 0
    }

    /// The size of the notch cutout in points.
    var notchSize: CGSize {
        guard hasPhysicalNotch else { return .zero }
        let leftWidth = auxiliaryTopLeftArea?.width ?? 0
        let rightWidth = auxiliaryTopRightArea?.width ?? 0
        let notchWidth = frame.width - leftWidth - rightWidth
        let notchHeight = safeAreaInsets.top
        return CGSize(width: max(notchWidth, 0), height: notchHeight)
    }

    /// The built-in screen, if present and active.
    static var builtin: NSScreen? {
        screens.first { $0.isBuiltinDisplay }
    }
}
