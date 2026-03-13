import AppKit
import SwiftUI

// MARK: - Window drag area

extension Notification.Name {
    static let panelDragEnded = Notification.Name("panelDragEnded")
    static let resetPanelPosition = Notification.Name("resetPanelPosition")
}

enum PanelDragKeys {
    static let originX = "x"
    static let topY = "topY"
}

private func makeMoveCursor(color: NSColor) -> NSCursor {
    let size = NSSize(width: 16, height: 16)
    let image = NSImage(size: size, flipped: true) { _ in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        let mid: CGFloat = 8
        let arm: CGFloat = 5
        let tip: CGFloat = 2.5

        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(1.2)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        // Cross lines
        ctx.move(to: CGPoint(x: mid, y: mid - arm))
        ctx.addLine(to: CGPoint(x: mid, y: mid + arm))
        ctx.move(to: CGPoint(x: mid - arm, y: mid))
        ctx.addLine(to: CGPoint(x: mid + arm, y: mid))

        // Arrowheads: top, bottom, left, right
        for (dx, dy) in [(0.0, -1.0), (0.0, 1.0), (-1.0, 0.0), (1.0, 0.0)] {
            let tipPt = CGPoint(x: mid + dx * arm, y: mid + dy * arm)
            ctx.move(to: CGPoint(x: tipPt.x - dy * tip, y: tipPt.y - dx * tip))
            ctx.addLine(to: tipPt)
            ctx.addLine(to: CGPoint(x: tipPt.x + dy * tip, y: tipPt.y + dx * tip))
        }

        ctx.strokePath()
        return true
    }
    return NSCursor(image: image, hotSpot: NSPoint(x: 8, y: 8))
}

private let darkMoveCursor = makeMoveCursor(color: NSColor(white: 0.15, alpha: 1))
private let lightMoveCursor = makeMoveCursor(color: NSColor(white: 0.9, alpha: 1))

private class DragCursorView: NSView {
    private var currentMoveCursor: NSCursor {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? lightMoveCursor : darkMoveCursor
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: currentMoveCursor)
    }

    private var cursorTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = cursorTrackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        cursorTrackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        currentMoveCursor.set()
    }
}

struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = DragCursorView()
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct HeaderView: View {
    let sessions: [Session]

    var body: some View {
        let counts = StatusCounts(sessions: sessions)

        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(headerBarColor(counts: counts))
                .frame(width: 3, height: 14)
            Text("cctop")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
            Spacer()
            StatusChip(count: counts.permission, color: .red, categoryLabel: "need permission")
            StatusChip(count: counts.attention, color: Color.amber, categoryLabel: "need attention")
            StatusChip(count: counts.working, color: Color.statusGreen, categoryLabel: "working")
            StatusChip(count: counts.idle, color: .gray, categoryLabel: "idle")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(WindowDragArea())
    }
    private func headerBarColor(counts: StatusCounts) -> Color {
        if counts.permission > 0 || counts.attention > 0 {
            return Color.amber
        }
        if counts.working > 0 {
            return Color.statusGreen.opacity(0.5)
        }
        return Color.textMuted
    }
}

#Preview("Normal") {
    HeaderView(sessions: Session.qaShowcase).frame(width: 320).padding()
}
