import SwiftUI

/// Horizontal layer selector using glass capsule buttons
struct LayerSelectorView: View {
    @Binding var selectedLayer: LayerType
    let segmentation: SegmentationService

    @ScaledMetric(relativeTo: .caption2) private var padH: CGFloat = 10
    @ScaledMetric(relativeTo: .caption2) private var padV: CGFloat = 5

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(LayerType.allCases) { layer in
                    let available = segmentation.hasContent(for: layer)
                    Button {
                        if available {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectedLayer = layer
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: layer.icon)
                                .font(.caption2)
                            Text(layer.label)
                                .font(.caption2.weight(.medium))
                        }
                        .foregroundStyle(
                            selectedLayer == layer
                                ? .white
                                : available ? .primary.opacity(0.6) : .primary.opacity(0.2)
                        )
                        .padding(.horizontal, padH)
                        .padding(.vertical, padV)
                        .background(
                            selectedLayer == layer
                                ? AnyShapeStyle(Color.accentColor.opacity(0.8))
                                : AnyShapeStyle(.ultraThinMaterial),
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!available)
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

/// Layer-specific parameter sliders (5 common params) — uses shared EditorSlider
struct LayerParamsView: View {
    @Binding var params: LayerEditParams

    var body: some View {
        VStack(spacing: 14) {
            EditorSlider(label: "Exposure", value: $params.exposure, range: -3.0...3.0, defaultValue: 0.0)
            EditorSlider(label: "Brightness", value: $params.brightness, range: -0.5...0.5, defaultValue: 0.0)
            EditorSlider(label: "Contrast", value: $params.contrast, range: 0.5...2.0, defaultValue: 1.0)
            EditorSlider(label: "Saturation", value: $params.saturation, range: 0...2.0, defaultValue: 1.0)
            EditorSlider(label: "Temperature", value: $params.temperature, range: 2000...10000, defaultValue: 6500)
        }
    }
}
