import SwiftUI

/// Horizontal layer selector bar used in both RAW and JPG editors
struct LayerSelectorView: View {
    @Binding var selectedLayer: LayerType
    let segmentation: SegmentationService

    var body: some View {
        HStack(spacing: 0) {
            ForEach(LayerType.allCases) { layer in
                let available = segmentation.hasContent(for: layer)
                Button {
                    if available {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedLayer = layer
                        }
                    }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: layer.icon)
                            .font(.system(size: 14))
                        Text(layer.label)
                            .font(.system(size: 9))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .foregroundStyle(
                        selectedLayer == layer
                            ? .white
                            : available ? .white.opacity(0.5) : .white.opacity(0.2)
                    )
                    .background(
                        selectedLayer == layer
                            ? Color.accentColor.opacity(0.3)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!available)
            }
        }
        .padding(.horizontal, 8)
    }
}

/// Layer-specific parameter sliders (5 common params)
struct LayerParamsView: View {
    @Binding var params: LayerEditParams

    var body: some View {
        VStack(spacing: 14) {
            layerSlider(label: "Exposure", value: $params.exposure, range: -3.0...3.0, defaultValue: 0.0)
            layerSlider(label: "Brightness", value: $params.brightness, range: -0.5...0.5, defaultValue: 0.0)
            layerSlider(label: "Contrast", value: $params.contrast, range: 0.5...2.0, defaultValue: 1.0)
            layerSlider(label: "Saturation", value: $params.saturation, range: 0...2.0, defaultValue: 1.0)
            layerSlider(label: "Temperature", value: $params.temperature, range: 2000...10000, defaultValue: 6500)
        }
    }

    private func layerSlider(label: String, value: Binding<Float>, range: ClosedRange<Float>, defaultValue: Float) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(LocalizedStringKey(label))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text(formatValue(value.wrappedValue, range: range))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }

            HStack(spacing: 10) {
                Slider(value: value, in: range)
                    .tint(.white)

                Button {
                    value.wrappedValue = defaultValue
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
                .opacity(value.wrappedValue != defaultValue ? 1 : 0)
            }
        }
    }

    private func formatValue(_ value: Float, range: ClosedRange<Float>) -> String {
        if range.upperBound >= 1000 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.2f", value)
    }
}
