import SwiftUI

// MARK: - Editor Format Badge

/// Shows RAW (green) or JPG (yellow) format indicator
struct EditorFormatBadge: View {
    let format: String // "RAW" or "JPG"

    private var badgeColor: Color {
        format == "RAW"
            ? Color(red: 0.4, green: 0.8, blue: 0.5)
            : Color(red: 1.0, green: 0.85, blue: 0.35)
    }

    var body: some View {
        Text(format)
            .font(.footnote.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(badgeColor.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Editor Tab Bar (Glass Capsule Style)

/// A horizontal row of glass capsule buttons for switching editor tabs
struct EditorTabBar<Tab: Hashable>: View {
    let tabs: [Tab]
    @Binding var selected: Tab
    let label: (Tab) -> String
    let icon: (Tab) -> String

    @ScaledMetric(relativeTo: .footnote) private var capsulePadH: CGFloat = 10
    @ScaledMetric(relativeTo: .footnote) private var capsulePadV: CGFloat = 6

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tabs, id: \.self) { tab in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selected = tab
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: icon(tab))
                                .font(.caption2)
                            Text(label(tab))
                                .font(.caption2.weight(.medium))
                        }
                        .foregroundStyle(selected == tab ? .white : .primary.opacity(0.6))
                        .padding(.horizontal, capsulePadH)
                        .padding(.vertical, capsulePadV)
                        .background(
                            selected == tab
                                ? AnyShapeStyle(Color.accentColor)
                                : AnyShapeStyle(.ultraThinMaterial),
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

// MARK: - Editor Slider

/// A single parameter slider with label, value readout, and per-slider reset
struct EditorSlider: View {
    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let defaultValue: Float

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(LocalizedStringKey(label))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formatValue(value))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 10) {
                Slider(value: $value, in: range)
                    .tint(.accentColor)

                Button {
                    value = defaultValue
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.caption2)
                        .foregroundStyle(.quaternary)
                }
                .buttonStyle(.plain)
                .opacity(value != defaultValue ? 1 : 0)
            }
        }
    }

    private func formatValue(_ value: Float) -> String {
        if range.upperBound >= 1000 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.2f", value)
    }
}

// MARK: - Editor Toggle

/// A parameter toggle switch
struct EditorToggle: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(LocalizedStringKey(label))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .toggleStyle(.switch)
        .tint(.accentColor)
    }
}

// MARK: - Editor Toolbar (Glass Capsule Buttons)

/// Bottom toolbar with Reset / Presets / Save as glass capsule buttons
struct EditorToolbar: View {
    let isModified: Bool
    let onReset: () -> Void
    let onPresets: () -> Void
    let onSave: () -> Void

    @ScaledMetric(relativeTo: .caption) private var padH: CGFloat = 12
    @ScaledMetric(relativeTo: .caption) private var padV: CGFloat = 7

    var body: some View {
        HStack(spacing: 10) {
            toolbarCapsule(icon: "arrow.counterclockwise", label: String(localized: "Reset"), action: onReset)
                .opacity(isModified ? 1 : 0.4)
                .disabled(!isModified)

            toolbarCapsule(icon: "slider.horizontal.below.square.filled.and.square", label: String(localized: "Presets"), action: onPresets)

            toolbarCapsule(icon: "square.and.arrow.down", label: String(localized: "Save"), action: onSave)
                .opacity(isModified ? 1 : 0.4)
                .disabled(!isModified)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func toolbarCapsule(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption2)
                Text(label)
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, padH)
            .padding(.vertical, padV)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
