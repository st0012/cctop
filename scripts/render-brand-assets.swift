#!/usr/bin/env swift

import AppKit
import Foundation

private let fileManager = FileManager.default
private let root = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)

private let background = NSColor(
    srgbRed: 0x0C / 255,
    green: 0x0D / 255,
    blue: 0x0F / 255,
    alpha: 1
)
private let brandSegments: [(fraction: CGFloat, color: NSColor)] = [
    (52 / 96, NSColor(srgbRed: 0x8C / 255, green: 0xBF / 255, blue: 0x6A / 255, alpha: 1)),
    (19 / 96, NSColor(srgbRed: 0xE0 / 255, green: 0x9B / 255, blue: 0x56 / 255, alpha: 1)),
    (12 / 96, NSColor(srgbRed: 0xDB / 255, green: 0x6E / 255, blue: 0x6E / 255, alpha: 1)),
    (13 / 96, NSColor(srgbRed: 0x4D / 255, green: 0x50 / 255, blue: 0x58 / 255, alpha: 1)),
]
private let liveStatusSegments: [(fraction: CGFloat, color: NSColor)] = [
    (52 / 96, NSColor(srgbRed: 0x9E / 255, green: 0xCE / 255, blue: 0x6A / 255, alpha: 1)),
    (19 / 96, NSColor(srgbRed: 0xFF / 255, green: 0x9E / 255, blue: 0x64 / 255, alpha: 1)),
    (12 / 96, NSColor(srgbRed: 0xF7 / 255, green: 0x76 / 255, blue: 0x8E / 255, alpha: 1)),
    (13 / 96, NSColor(srgbRed: 0x69 / 255, green: 0x71 / 255, blue: 0x8E / 255, alpha: 1)),
]

private func bitmap(size: NSSize, draw: () -> Void) throws -> NSBitmapImageRep {
    guard let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size.width),
        pixelsHigh: Int(size.height),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: representation) else {
        throw CocoaError(.fileWriteUnknown)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    NSColor.clear.setFill()
    NSRect(origin: .zero, size: size).fill()
    draw()
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return representation
}

private func writePNG(_ representation: NSBitmapImageRep, to relativePath: String) throws {
    guard let data = representation.representation(using: .png, properties: [.compressionFactor: 1]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: root.appendingPathComponent(relativePath))
}

private func appIcon(size: CGFloat) throws -> NSBitmapImageRep {
    try bitmap(size: NSSize(width: size, height: size)) {
        let scale = size / 128
        let canvas = NSRect(x: 0, y: 0, width: size, height: size)
        background.setFill()
        NSBezierPath(roundedRect: canvas, xRadius: 28.6336 * scale, yRadius: 28.6336 * scale).fill()

        let bar = NSRect(x: 16 * scale, y: 57 * scale, width: 96 * scale, height: 14 * scale)
        let clip = NSBezierPath(roundedRect: bar, xRadius: 7 * scale, yRadius: 7 * scale)
        NSGraphicsContext.current?.saveGraphicsState()
        clip.addClip()
        var x = bar.minX
        for (index, segment) in brandSegments.enumerated() {
            let width = index == brandSegments.count - 1
                ? bar.maxX - x
                : bar.width * segment.fraction
            segment.color.setFill()
            NSRect(x: x, y: bar.minY, width: width, height: bar.height).fill()
            x += width
        }
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}

private func streamDeckLockup(size: CGFloat) throws -> NSBitmapImageRep {
    try bitmap(size: NSSize(width: size, height: size)) {
        let scale = size / 144
        let lockupScale: CGFloat = 1.56
        let canvas = NSRect(x: 0, y: 0, width: size, height: size)
        background.setFill()
        NSBezierPath(
            roundedRect: canvas,
            xRadius: 23.04 * scale,
            yRadius: 23.04 * scale
        ).fill()

        let outline = NSBezierPath(
            roundedRect: canvas.insetBy(dx: 0.75 * scale, dy: 0.75 * scale),
            xRadius: 22.29 * scale,
            yRadius: 22.29 * scale
        )
        NSColor.white.withAlphaComponent(0.05).setStroke()
        outline.lineWidth = 1.5 * scale
        outline.stroke()

        let groupHeight = (7 + 11 + 15) * lockupScale
        let groupTop = (144 - groupHeight) / 2
        let barWidth = 40 * lockupScale
        let barHeight = 7 * lockupScale
        let bar = NSRect(
            x: ((144 - barWidth) / 2) * scale,
            y: (144 - groupTop - barHeight) * scale,
            width: barWidth * scale,
            height: barHeight * scale
        )
        let clip = NSBezierPath(roundedRect: bar, xRadius: barHeight * scale / 2, yRadius: barHeight * scale / 2)
        NSGraphicsContext.current?.saveGraphicsState()
        clip.addClip()
        let segmentWidths: [CGFloat] = [21, 8, 5, 6].map { $0 * lockupScale }
        var x = bar.minX
        for (index, segment) in brandSegments.enumerated() {
            segment.color.setFill()
            NSRect(
                x: x,
                y: bar.minY,
                width: segmentWidths[index] * scale,
                height: bar.height
            ).fill()
            x += segmentWidths[index] * scale
        }
        NSGraphicsContext.current?.restoreGraphicsState()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.minimumLineHeight = 15 * lockupScale * scale
        paragraph.maximumLineHeight = 15 * lockupScale * scale
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 15 * lockupScale * scale, weight: .semibold),
            .foregroundColor: NSColor(srgbRed: 0xE8 / 255, green: 0xEC / 255, blue: 0xF1 / 255, alpha: 1),
            .kern: 0.45 * lockupScale * scale,
            .paragraphStyle: paragraph,
        ]
        NSAttributedString(string: "cctop", attributes: attributes).draw(
            with: NSRect(
                x: 0,
                y: groupTop * scale,
                width: size,
                height: 15 * lockupScale * scale
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
    }
}

private func hairline(width: CGFloat, height: CGFloat, color: NSColor) throws -> NSBitmapImageRep {
    try bitmap(size: NSSize(width: width, height: height)) {
        let barHeight: CGFloat = width == 44 ? 6 : height / 3
        let horizontalInset: CGFloat = width == 44 ? 4 : 0
        let rect = NSRect(
            x: horizontalInset,
            y: (height - barHeight) / 2,
            width: width - horizontalInset * 2,
            height: barHeight
        )
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
    }
}

private func rgbaData(_ representation: NSBitmapImageRep) -> Data {
    var data = Data(capacity: representation.pixelsWide * representation.pixelsHigh * 4)
    for y in stride(from: representation.pixelsHigh - 1, through: 0, by: -1) {
        for x in 0..<representation.pixelsWide {
            let color = (representation.colorAt(x: x, y: y) ?? .clear).usingColorSpace(.sRGB) ?? .clear
            data.append(UInt8((color.redComponent * 255).rounded()))
            data.append(UInt8((color.greenComponent * 255).rounded()))
            data.append(UInt8((color.blueComponent * 255).rounded()))
            data.append(UInt8((color.alphaComponent * 255).rounded()))
        }
    }
    return data
}

private func drawStatusBar(in rect: NSRect, mixed: Bool) {
    let clip = NSBezierPath(
        roundedRect: rect,
        xRadius: rect.height / 2,
        yRadius: rect.height / 2
    )
    NSGraphicsContext.current?.saveGraphicsState()
    clip.addClip()

    let segments = mixed ? liveStatusSegments : [(1, liveStatusSegments[0].color)]
    var x = rect.minX
    for (index, segment) in segments.enumerated() {
        let width = index == segments.count - 1
            ? rect.maxX - x
            : rect.width * segment.fraction
        segment.color.setFill()
        NSRect(x: x, y: rect.minY, width: width, height: rect.height).fill()
        x += width
    }
    NSGraphicsContext.current?.restoreGraphicsState()
}

private func drawMenuUtilities(baselineY: CGFloat) {
    let foreground = NSColor(srgbRed: 0.91, green: 0.90, blue: 0.92, alpha: 1)

    foreground.setStroke()
    let wifi = NSBezierPath()
    wifi.lineWidth = 2.2
    wifi.lineCapStyle = .round
    wifi.appendArc(
        withCenter: NSPoint(x: 741, y: baselineY + 7),
        radius: 11,
        startAngle: 38,
        endAngle: 142
    )
    wifi.appendArc(
        withCenter: NSPoint(x: 741, y: baselineY + 7),
        radius: 6,
        startAngle: 42,
        endAngle: 138
    )
    wifi.stroke()
    foreground.setFill()
    NSBezierPath(ovalIn: NSRect(x: 739.5, y: baselineY + 5.5, width: 3, height: 3)).fill()

    let battery = NSBezierPath(roundedRect: NSRect(x: 779, y: baselineY, width: 30, height: 14), xRadius: 3, yRadius: 3)
    battery.lineWidth = 1.2
    battery.stroke()
    NSBezierPath(roundedRect: NSRect(x: 782, y: baselineY + 3, width: 21, height: 8), xRadius: 1.5, yRadius: 1.5).fill()
    NSBezierPath(roundedRect: NSRect(x: 810, y: baselineY + 4, width: 2.5, height: 6), xRadius: 1, yRadius: 1).fill()

    let timeAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 17, weight: .medium),
        .foregroundColor: foreground,
    ]
    "Sun 2:14 PM".draw(at: NSPoint(x: 840, y: baselineY - 3), withAttributes: timeAttributes)
}

private func statusOverview() throws -> NSBitmapImageRep {
    try bitmap(size: NSSize(width: 1000, height: 391)) {
        let canvas = NSRect(x: 0, y: 0, width: 1000, height: 391)
        NSGradient(
            starting: NSColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1),
            ending: NSColor(srgbRed: 0.055, green: 0.056, blue: 0.062, alpha: 1)
        )?.draw(in: canvas, angle: -90)

        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18, weight: .regular),
            .foregroundColor: NSColor(srgbRed: 0.82, green: 0.81, blue: 0.83, alpha: 1),
        ]
        "All sessions healthy".draw(at: NSPoint(x: 38, y: 331), withAttributes: labelAttributes)
        "Sessions need attention".draw(at: NSPoint(x: 38, y: 224), withAttributes: labelAttributes)
        "Notch pill (MacBook with camera notch)".draw(
            at: NSPoint(x: 38, y: 117),
            withAttributes: labelAttributes
        )

        let menuFill = NSColor(srgbRed: 0.10, green: 0.095, blue: 0.12, alpha: 0.82)
        let menuBorder = NSColor(srgbRed: 0.25, green: 0.25, blue: 0.29, alpha: 0.55)
        for baselineY in [284 as CGFloat, 177] {
            let rect = NSRect(x: 38, y: baselineY - 13, width: 924, height: 52)
            menuFill.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
            menuBorder.setStroke()
            let border = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
            border.lineWidth = 1
            border.stroke()
            drawMenuUtilities(baselineY: baselineY)
        }
        drawStatusBar(in: NSRect(x: 680, y: 292, width: 36, height: 6), mixed: false)
        drawStatusBar(in: NSRect(x: 680, y: 185, width: 36, height: 6), mixed: true)

        let laptop = NSBezierPath(roundedRect: NSRect(x: 38, y: -42, width: 924, height: 151), xRadius: 28, yRadius: 28)
        NSColor(srgbRed: 0.035, green: 0.036, blue: 0.04, alpha: 1).setFill()
        laptop.fill()
        NSColor(srgbRed: 0.38, green: 0.38, blue: 0.41, alpha: 1).setStroke()
        laptop.lineWidth = 1.2
        laptop.stroke()

        NSColor(srgbRed: 0.07, green: 0.07, blue: 0.085, alpha: 1).setFill()
        NSRect(x: 49, y: 0, width: 902, height: 97).fill()
        NSColor.black.setFill()
        NSBezierPath(roundedRect: NSRect(x: 438, y: 79, width: 146, height: 30), xRadius: 8, yRadius: 8).fill()
        NSBezierPath(roundedRect: NSRect(x: 395, y: 89, width: 52, height: 20), xRadius: 7, yRadius: 7).fill()
        drawStatusBar(in: NSRect(x: 403, y: 97, width: 36, height: 4), mixed: true)

        NSColor(srgbRed: 0.02, green: 0.06, blue: 0.09, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 509, y: 92, width: 7, height: 7)).fill()
        drawMenuUtilities(baselineY: 76)
    }
}

private let appIconFiles: [(String, CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

let appIconDirectory = "menubar/CctopMenubar/Assets.xcassets/AppIcon.appiconset/"
for (filename, size) in appIconFiles {
    try writePNG(appIcon(size: size), to: appIconDirectory + filename)
}

let streamDeckImageDirectory = "plugins/streamdeck/com.st0012.cctop.sdPlugin/imgs/"
try writePNG(streamDeckLockup(size: 256), to: streamDeckImageDirectory + "plugin-icon.png")
try writePNG(streamDeckLockup(size: 512), to: streamDeckImageDirectory + "plugin-icon@2x.png")

let menubarDirectory = "menubar/CctopMenubar/Assets.xcassets/MenubarIcon.imageset/"
try writePNG(hairline(width: 36, height: 18, color: .white), to: menubarDirectory + "menubar-icon.png")
try writePNG(hairline(width: 72, height: 36, color: .white), to: menubarDirectory + "menubar-icon@2x.png")

let tray = try hairline(width: 44, height: 44, color: .white)
let trayAttention = try hairline(
    width: 44,
    height: 44,
    color: NSColor(srgbRed: 0xDB / 255, green: 0x6E / 255, blue: 0x6E / 255, alpha: 1)
)
try writePNG(tray, to: "assets/tray-icon.png")
try writePNG(trayAttention, to: "assets/tray-icon-attention.png")
try rgbaData(tray).write(to: root.appendingPathComponent("assets/tray-icon.rgba"))
try rgbaData(trayAttention).write(to: root.appendingPathComponent("assets/tray-icon-attention.rgba"))

let appIconSVG = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128" role="img" aria-label="cctop app icon">
  <defs><clipPath id="bar"><rect x="16" y="57" width="96" height="14" rx="7"/></clipPath></defs>
  <rect width="128" height="128" rx="28.6336" fill="#0C0D0F"/>
  <g clip-path="url(#bar)">
    <rect x="16" y="57" width="52" height="14" fill="#8CBF6A"/>
    <rect x="68" y="57" width="19" height="14" fill="#E09B56"/>
    <rect x="87" y="57" width="12" height="14" fill="#DB6E6E"/>
    <rect x="99" y="57" width="13" height="14" fill="#4D5058"/>
  </g>
</svg>
"""
try appIconSVG.write(
    to: root.appendingPathComponent("assets/cctop-app-icon.svg"),
    atomically: true,
    encoding: .utf8
)

let streamDeckToggleSVG = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 144 144" role="img" aria-label="cctop">
  <rect width="144" height="144" rx="23.04" fill="#0C0D0F"/>
  <rect x="0.75" y="0.75" width="142.5" height="142.5" rx="22.29" fill="none" stroke="#FFFFFF" stroke-opacity="0.05" stroke-width="1.5"/>
  <path d="M46.26 46.26H73.56V57.18H46.26A5.46 5.46 0 0 1 46.26 46.26Z" fill="#8CBF6A"/>
  <rect x="73.56" y="46.26" width="12.48" height="10.92" fill="#E09B56"/>
  <rect x="86.04" y="46.26" width="7.8" height="10.92" fill="#DB6E6E"/>
  <path d="M93.84 46.26H97.74A5.46 5.46 0 0 1 97.74 57.18H93.84Z" fill="#4D5058"/>
  <text x="72" y="93.45" text-anchor="middle" fill="#E8ECF1" font-family="SF Mono, Menlo, monospace" font-size="23.4" font-weight="600" letter-spacing="0.702">cctop</text>
</svg>
"""
for filename in ["key-toggle.svg", "key-toggle@2x.svg"] {
    try streamDeckToggleSVG.write(
        to: root.appendingPathComponent(streamDeckImageDirectory + filename),
        atomically: true,
        encoding: .utf8
    )
}

let streamDeckCategorySVG = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 28 28">
  <defs><clipPath id="bar"><rect x="4" y="12" width="20" height="4" rx="2"/></clipPath></defs>
  <g clip-path="url(#bar)" fill="#FFFFFF">
    <rect x="4" y="12" width="11" height="4"/>
    <rect x="15" y="12" width="4" height="4" opacity="0.62"/>
    <rect x="19" y="12" width="2.5" height="4" opacity="0.42"/>
    <rect x="21.5" y="12" width="2.5" height="4" opacity="0.25"/>
  </g>
</svg>
"""
for filename in ["category.svg", "category@2x.svg"] {
    try streamDeckCategorySVG.write(
        to: root.appendingPathComponent(streamDeckImageDirectory + filename),
        atomically: true,
        encoding: .utf8
    )
}

try writePNG(statusOverview(), to: "docs/status-icon.png")
