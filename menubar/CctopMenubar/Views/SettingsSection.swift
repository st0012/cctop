import SwiftUI
import KeyboardShortcuts

struct AmberSegmentedPicker<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let isSelected = selection == option.value
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        selection = option.value
                    }
                } label: {
                    Text(option.label)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .foregroundStyle(isSelected ? Color.segmentActiveText : Color.segmentText)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(isSelected ? Color.amber : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.segmentBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct SettingsSection: View {
    @AppStorage("appearanceMode") private var appearanceMode = "system"

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Appearance")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                AmberSegmentedPicker(
                    options: AppearanceMode.allCases.map { ($0.rawValue, $0.label) },
                    selection: $appearanceMode
                )
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Divider().padding(.horizontal, 14)

            HStack {
                Text("Toggle Shortcut")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                KeyboardShortcuts.Recorder("", name: .togglePanel)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
        .background(Color.settingsBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.settingsBorder, lineWidth: 1)
        )
        .padding(.horizontal, 8)
    }
}

#Preview {
    SettingsSection()
        .frame(width: 320)
        .padding()
}
