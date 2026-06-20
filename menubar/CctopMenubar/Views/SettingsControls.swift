import KeyboardShortcuts
import SwiftUI

struct AmberSegmentedPicker<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: AppChrome.settingsSegmentSpacing) {
            ForEach(options.indices, id: \.self) { index in
                SegmentButton(
                    label: options[index].label,
                    isSelected: selection == options[index].value
                ) {
                    withAnimation(.easeOut(duration: 0.15)) { selection = options[index].value }
                }
            }
        }
        .padding(AppChrome.settingsSegmentedControlPadding)
        .frame(height: AppChrome.settingsSegmentedControlHeight)
        .background(Color.panelControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppChrome.controlCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppChrome.controlCornerRadius, style: .continuous)
                .stroke(Color.panelControlBorder, lineWidth: 1)
        }
    }
}

private struct SegmentButton: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .allowsTightening(true)
                .padding(.horizontal, AppChrome.settingsSegmentHorizontalPadding)
                .frame(height: AppChrome.settingsSegmentHeight)
                .foregroundStyle(foregroundColor)
                .background {
                    SelectionSurfaceChrome(
                        isSelected: isSelected,
                        isHovered: isHovered,
                        cornerRadius: AppChrome.settingsSegmentSelectionCornerRadius,
                        hoverColor: Color.panelControlBackground
                    )
                }
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: AppChrome.settingsSegmentSelectionCornerRadius, style: .continuous)
                            .stroke(Color.panelAccentBorder, lineWidth: 1)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: AppChrome.settingsSegmentSelectionCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var foregroundColor: Color {
        if isSelected { return Color.segmentActiveText }
        if isHovered { return Color.segmentActiveText.opacity(0.7) }
        return Color.segmentText
    }
}

struct ShortcutBadge: View {
    let name: KeyboardShortcuts.Name
    @State private var showRecorder = false
    @State private var isHovered = false

    var body: some View {
        Button { showRecorder.toggle() } label: {
            if let shortcut = KeyboardShortcuts.getShortcut(for: name) {
                Text(shortcut.description)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(isHovered ? Color.segmentActiveText : Color.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(isHovered ? Color.panelSelectionBackground : Color.panelControlBackground)
                    .clipShape(RoundedRectangle(cornerRadius: AppChrome.controlCornerRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: AppChrome.controlCornerRadius, style: .continuous)
                            .stroke(Color.panelControlBorder, lineWidth: 1)
                    }
            } else {
                Text("Record Shortcut")
                    .font(.system(size: 10))
                    .foregroundStyle(isHovered ? Color.textPrimary : Color.textMuted)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .popover(isPresented: $showRecorder) {
            KeyboardShortcuts.Recorder("", name: name)
                .padding(8)
        }
    }
}
