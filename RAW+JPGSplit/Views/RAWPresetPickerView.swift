import SwiftUI

struct RAWPresetPickerView: View {
    var presetStore: RAWEditPresetStore
    let onSelect: (RAWEditPreset) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if presetStore.presets.isEmpty {
                    ContentUnavailableView {
                        Label("No Presets", systemImage: "slider.horizontal.below.square.filled.and.square")
                    } description: {
                        Text("Save your current adjustments as a preset to reuse them on other photos.")
                    }
                } else {
                    presetList
                }
            }
            .navigationTitle("Presets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var presetList: some View {
        List {
            ForEach(presetStore.presets) { preset in
                Button {
                    onSelect(preset)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(preset.name)
                            .font(.body)
                            .foregroundStyle(.primary)
                        Text(presetSummary(preset.params))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 2)
                }
            }
            .onDelete { indexSet in
                for index in indexSet {
                    presetStore.deletePreset(presetStore.presets[index])
                }
            }
        }
    }

    private func presetSummary(_ params: RAWEditParams) -> String {
        var parts: [String] = []
        if params.exposure != 0 { parts.append("EV \(String(format: "%+.1f", params.exposure))") }
        if params.temperature != 5000 { parts.append("\(Int(params.temperature))K") }
        if params.contrastAmount != 1.0 { parts.append("Contrast \(String(format: "%.1f", params.contrastAmount))") }
        if params.sharpnessAmount > 0 { parts.append("Sharp \(String(format: "%.1f", params.sharpnessAmount))") }
        if parts.isEmpty { return "Default" }
        return parts.joined(separator: " · ")
    }
}
