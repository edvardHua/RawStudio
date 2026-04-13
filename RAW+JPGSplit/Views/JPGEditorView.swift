import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

struct JPGEditorView: View {
    let imageData: Data
    let assetID: String
    var presetStore: RAWEditPresetStore
    let onDone: (JPGEditParams, LayerEdits, UIImage?) -> Void

    @State private var params: JPGEditParams
    @State private var previewImage: UIImage?
    @State private var isRendering = false
    @State private var selectedTab: EditorTab = .exposure
    @State private var selectedLayer: LayerType = .global
    @State private var layerEdits: LayerEdits
    @State private var segmentation = SegmentationService()
    @State private var showPresetPicker = false
    @State private var showSavePreset = false
    @State private var presetName = ""
    @State private var customMaskStore = CustomMaskStore()
    @State private var activeCustomLayers: [LayerType] = []
    @State private var showMaskPainter = false
    @State private var editingMaskLayer: LayerType?
    @Environment(\.dismiss) private var dismiss

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let sourceImage: CIImage?
    private let imageOrientation: UIImage.Orientation

    enum EditorTab: String, CaseIterable {
        case exposure, color, detail

        var label: String {
            switch self {
            case .exposure: return String(localized: "Exposure")
            case .color: return String(localized: "Color")
            case .detail: return String(localized: "Detail")
            }
        }

        var icon: String {
            switch self {
            case .exposure: return "sun.max"
            case .color: return "drop.halffull"
            case .detail: return "circle.hexagongrid"
            }
        }
    }

    init(imageData: Data, assetID: String, presetStore: RAWEditPresetStore,
         initialParams: JPGEditParams, initialLayerEdits: LayerEdits = LayerEdits(),
         onDone: @escaping (JPGEditParams, LayerEdits, UIImage?) -> Void) {
        self.imageData = imageData
        self.assetID = assetID
        self.presetStore = presetStore
        self.onDone = onDone
        self._params = State(initialValue: initialParams)
        self._layerEdits = State(initialValue: initialLayerEdits)

        // Create CIImage with orientation applied so pixels match display
        if let ciImage = CIImage(data: imageData) {
            self.sourceImage = ciImage.oriented(forExifOrientation: Int32(ciImage.properties[kCGImagePropertyOrientation as String] as? Int ?? 1))
            // Map CGImagePropertyOrientation to UIImage.Orientation for output
            let exifOrientation = ciImage.properties[kCGImagePropertyOrientation as String] as? Int ?? 1
            self.imageOrientation = Self.uiImageOrientation(from: exifOrientation)
        } else {
            self.sourceImage = nil
            self.imageOrientation = .up
        }
    }

    private static func uiImageOrientation(from exifOrientation: Int) -> UIImage.Orientation {
        switch exifOrientation {
        case 1: return .up
        case 2: return .upMirrored
        case 3: return .down
        case 4: return .downMirrored
        case 5: return .leftMirrored
        case 6: return .right
        case 7: return .rightMirrored
        case 8: return .left
        default: return .up
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemBackground).ignoresSafeArea()

                GeometryReader { geo in
                    VStack(spacing: 0) {
                        // Preview area — fills remaining space
                        previewArea
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        // Controls area — proportional height
                        editorControls
                            .frame(height: geo.size.height * 0.4)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        presetStore.saveJPGParams(params, for: assetID)
                        presetStore.saveJPGLayerEdits(layerEdits, for: assetID)
                        onDone(params, layerEdits, previewImage)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .task {
                await generateMasks()
                loadCustomMasks()
                await renderPreview()
            }
            .onChange(of: params) { _, _ in
                Task { await renderPreview() }
            }
            .onChange(of: layerEdits) { _, _ in
                Task { await renderPreview() }
            }
            .sheet(isPresented: $showPresetPicker) {
                JPGPresetPickerView(
                    presetStore: presetStore,
                    onSelect: { preset in
                        params = preset.params
                    }
                )
                .presentationDetents([.medium])
            }
            .alert("Save Preset", isPresented: $showSavePreset) {
                TextField("Preset Name", text: $presetName)
                Button("Save") {
                    if !presetName.isEmpty {
                        presetStore.saveJPGPreset(name: presetName, params: params)
                        presetName = ""
                    }
                }
                Button("Cancel", role: .cancel) { presetName = "" }
            } message: {
                Text("Enter a name for this preset")
            }
            .fullScreenCover(isPresented: $showMaskPainter) {
                if let layer = editingMaskLayer {
                    let img = previewImage ?? UIImage()
                    let existingMask: CGImage? = customMaskStore.loadMask(for: assetID, layer: layer)
                        .flatMap { ciImage in
                            let ctx = CIContext()
                            return ctx.createCGImage(ciImage, from: ciImage.extent)
                        }
                    MaskPainterView(sourceImage: img, existingMask: existingMask) { maskCG in
                        customMaskStore.saveMask(maskCG, for: assetID, layer: layer)
                        let ciMask = CIImage(cgImage: maskCG)
                        segmentation.setCustomMask(ciMask, for: layer)
                        if !activeCustomLayers.contains(layer) {
                            activeCustomLayers.append(layer)
                            activeCustomLayers.sort { $0.rawValue < $1.rawValue }
                        }
                        selectedLayer = layer
                    }
                }
            }
        }
    }

    // MARK: - Preview

    private var previewArea: some View {
        Group {
            if let image = previewImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Editor Controls

    private var editorControls: some View {
        VStack(spacing: 0) {
            // Row 1: Format badge + Layer selector (one line)
            HStack(spacing: 0) {
                EditorFormatBadge(format: "JPG")
                    .padding(.leading, 16)
                LayerSelectorView(
                    selectedLayer: $selectedLayer,
                    segmentation: segmentation,
                    activeCustomLayers: activeCustomLayers,
                    canAddCustomLayer: customMaskStore.nextAvailableCustomLayer(for: assetID) != nil,
                    onAddCustomLayer: { addCustomLayer() },
                    onEditCustomMask: { layer in editCustomMask(layer) },
                    onDeleteCustomLayer: { layer in deleteCustomLayer(layer) }
                )
            }
            .padding(.vertical, 8)

            if selectedLayer == .global {
                // Row 2: Tab bar (glass capsules)
                EditorTabBar(
                    tabs: EditorTab.allCases,
                    selected: $selectedTab,
                    label: { $0.label },
                    icon: { $0.icon }
                )
                .padding(.bottom, 8)

                // Row 3: ScrollView with sliders
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 14) {
                        tabContent
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                }

                // Row 4: EditorToolbar (Reset/Presets/Save)
                EditorToolbar(
                    isModified: params.isModified,
                    onReset: { params.reset() },
                    onPresets: { showPresetPicker = true },
                    onSave: { showSavePreset = true }
                )
            } else {
                // Row 2: ScrollView with LayerParamsView
                ScrollView(.vertical, showsIndicators: false) {
                    jpgLayerParamsContent
                        .padding(.horizontal, 16)
                        .padding(.bottom, 20)
                }

                // Row 3: Layer reset button (glass capsule, left-aligned)
                HStack {
                    Button {
                        var p = layerEdits.params(for: selectedLayer)
                        p.reset()
                        layerEdits.setParams(p, for: selectedLayer)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.caption2)
                            Text("Reset")
                                .font(.caption.weight(.medium))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .opacity(layerEdits.params(for: selectedLayer).isModified ? 1 : 0.4)
                    .disabled(!layerEdits.params(for: selectedLayer).isModified)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var jpgLayerParamsContent: some View {
        let binding = Binding<LayerEditParams>(
            get: { layerEdits.params(for: selectedLayer) },
            set: { layerEdits.setParams($0, for: selectedLayer) }
        )
        LayerParamsView(params: binding)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .exposure:
            EditorSlider(label: "Exposure", value: $params.exposure, range: -3.0...3.0, defaultValue: 0.0)
            EditorSlider(label: "Brightness", value: $params.brightness, range: -0.5...0.5, defaultValue: 0.0)
            EditorSlider(label: "Contrast", value: $params.contrast, range: 0.5...2.0, defaultValue: 1.0)
            EditorSlider(label: "Highlights", value: $params.highlights, range: 0...2.0, defaultValue: 1.0)
            EditorSlider(label: "Shadows", value: $params.shadows, range: -1.0...1.0, defaultValue: 0.0)

        case .color:
            EditorSlider(label: "Temperature", value: $params.warmth, range: 2000...10000, defaultValue: 6500)
            EditorSlider(label: "Tint", value: $params.tint, range: -150...150, defaultValue: 0.0)
            EditorSlider(label: "Saturation", value: $params.saturation, range: 0...2.0, defaultValue: 1.0)
            EditorSlider(label: "Vibrance", value: $params.vibrance, range: -1.0...1.0, defaultValue: 0.0)

        case .detail:
            EditorSlider(label: "Sharpness", value: $params.sharpness, range: 0...2.0, defaultValue: 0.0)
        }
    }

    // MARK: - Rendering

    private func generateMasks() async {
        guard let source = sourceImage else { return }
        // Use a scaled-down version for mask generation
        let scale: CGFloat = 0.25
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        await segmentation.generateMasks(for: scaled, identifier: assetID)
    }

    private func renderPreview() async {
        guard !isRendering, let source = sourceImage else { return }
        isRendering = true
        defer { isRendering = false }

        let output = Self.applyParams(params, to: source)

        // Scale down for preview
        let scale: CGFloat = 0.25
        var scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        // Apply layer edits with masks
        if layerEdits.hasAnyLayerEdits {
            for layer in LayerType.maskLayers {
                let lp = layerEdits.params(for: layer)
                if lp.isModified, let mask = segmentation.mask(for: layer, imageExtent: scaled.extent) {
                    scaled = SegmentationService.applyLayerEdits(lp, to: scaled, mask: mask)
                }
            }
        }

        guard let cgImage = ciContext.createCGImage(scaled, from: scaled.extent) else { return }
        let uiImage = UIImage(cgImage: cgImage)

        await MainActor.run {
            previewImage = uiImage
        }
    }

    /// Apply JPG edit params using CIFilter chain
    static func applyParams(_ params: JPGEditParams, to image: CIImage) -> CIImage {
        var current = image

        // Exposure
        if params.exposure != 0 {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = current
            filter.ev = params.exposure
            if let output = filter.outputImage { current = output }
        }

        // Color Controls: brightness, contrast, saturation
        if params.brightness != 0 || params.contrast != 1.0 || params.saturation != 1.0 {
            let filter = CIFilter.colorControls()
            filter.inputImage = current
            filter.brightness = params.brightness
            filter.contrast = params.contrast
            filter.saturation = params.saturation
            if let output = filter.outputImage { current = output }
        }

        // Temperature and Tint
        if params.warmth != 6500 || params.tint != 0 {
            let filter = CIFilter.temperatureAndTint()
            filter.inputImage = current
            filter.neutral = CIVector(x: CGFloat(params.warmth), y: CGFloat(params.tint))
            if let output = filter.outputImage { current = output }
        }

        // Highlight and Shadow
        if params.highlights != 1.0 || params.shadows != 0 {
            let filter = CIFilter.highlightShadowAdjust()
            filter.inputImage = current
            filter.highlightAmount = params.highlights
            filter.shadowAmount = params.shadows
            if let output = filter.outputImage { current = output }
        }

        // Vibrance
        if params.vibrance != 0 {
            let filter = CIFilter.vibrance()
            filter.inputImage = current
            filter.amount = params.vibrance
            if let output = filter.outputImage { current = output }
        }

        // Sharpness
        if params.sharpness > 0 {
            let filter = CIFilter.sharpenLuminance()
            filter.inputImage = current
            filter.sharpness = params.sharpness
            if let output = filter.outputImage { current = output }
        }

        return current
    }

    // MARK: - Custom Layer Management

    private func loadCustomMasks() {
        activeCustomLayers = customMaskStore.existingCustomLayers(for: assetID)
        for layer in activeCustomLayers {
            if let mask = customMaskStore.loadMask(for: assetID, layer: layer) {
                segmentation.setCustomMask(mask, for: layer)
            }
        }
    }

    private func addCustomLayer() {
        guard let layer = customMaskStore.nextAvailableCustomLayer(for: assetID) else { return }
        editingMaskLayer = layer
        showMaskPainter = true
    }

    private func editCustomMask(_ layer: LayerType) {
        editingMaskLayer = layer
        showMaskPainter = true
    }

    private func deleteCustomLayer(_ layer: LayerType) {
        customMaskStore.deleteMask(for: assetID, layer: layer)
        segmentation.setCustomMask(nil, for: layer)
        activeCustomLayers.removeAll { $0 == layer }
        // Reset layer edits for this layer
        layerEdits.setParams(LayerEditParams(), for: layer)
        if selectedLayer == layer {
            selectedLayer = .global
        }
    }
}
