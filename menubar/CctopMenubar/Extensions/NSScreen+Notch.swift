import AppKit

extension NSScreen {
    /// Whether this screen has a physical camera notch.
    var hasPhysicalNotch: Bool {
        safeAreaInsets.top > 0
    }

    /// The CGDirectDisplayID for this screen, extracted from device description.
    var displayID: CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return deviceDescription[key] as? CGDirectDisplayID ?? 0
    }

    /// A stable identifier for this physical display that survives reconnects.
    /// Built-in displays return `"builtin"`. External displays return
    /// `"vendor-model-serial"` or `"vendor-model-WxH"` if serial is 0.
    var screenKey: String {
        let id = displayID
        if CGDisplayIsBuiltin(id) != 0 { return "builtin" }
        let vendor = CGDisplayVendorNumber(id)
        let model = CGDisplayModelNumber(id)
        let serial = CGDisplaySerialNumber(id)
        if serial != 0 {
            return "\(vendor)-\(model)-\(serial)"
        }
        let mode = CGDisplayCopyDisplayMode(id)
        let width = mode?.pixelWidth ?? Int(frame.width)
        let height = mode?.pixelHeight ?? Int(frame.height)
        return "\(vendor)-\(model)-\(width)x\(height)"
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
