import SwiftUI

/// Horizontal layer selector using glass capsule buttons
struct LayerSelectorView: View {
    @Binding var selectedLayer: LayerType
    let segmentation: SegmentationService
    var activeCustomLayers: [LayerType] = []
    var canAddCustomLayer: Bool = false
    var onAddCustomLayer: () -> Void = {}
    var onEditCustomMask: (LayerType) -> Void = { _ in }
    var onDeleteCustomLayer: (LayerType) -> Void = { _ in }

    @ScaledMetric(relativeTo: .caption2) private var padH: CGFloat = 10
    @ScaledMetric(relativeTo: .caption2) private var padV: CGFloat = 5

    /// Layers visible in the selector: Global + auto layers + active custom layers
    private var visibleLayers: [LayerType] {
        [.global] + LayerType.autoLayers + activeCustomLayers
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(visibleLayers) { layer in
                    let available = segmentation.hasContent(for: layer)
                    let isCustom = layer.isCustom

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
                                ? AnyShapeStyle(isCustom ? Color.purple.opacity(0.8) : Color.accentColor.opacity(0.8))
                                : AnyShapeStyle(.ultraThinMaterial),
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!available)
                    .if(isCustom) { view in
                        view.contextMenu {
                            Button {
                                onEditCustomMask(layer)
                            } label: {
                                Label(String(localized: "Edit Mask"), systemImage: "paintbrush.pointed")
                            }
                            Button(role: .destructive) {
                                onDeleteCustomLayer(layer)
                            } label: {
                                Label(String(localized: "Delete Layer"), systemImage: "trash")
                            }
                        }
                    }
                }

                // Add custom layer button
                Button(action: onAddCustomLayer) {
                    Image(systemName: "plus")
                        .font(.caption2)
                        .foregroundStyle(.primary.opacity(canAddCustomLayer ? 0.6 : 0.2))
                        .padding(.horizontal, padH)
                        .padding(.vertical, padV)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .disabled(!canAddCustomLayer)
            }
            .padding(.horizontal, 16)
        }
    }
}

// MARK: - Conditional Modifier Helper

private extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
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
