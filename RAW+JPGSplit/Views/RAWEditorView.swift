import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import Photos

struct RAWEditorView: View {
    let rawData: Data
    let resourceHint: String
    let assetID: String
    let previewImageForMask: UIImage?  // Pre-rendered image for Vision segmentation
    var presetStore: RAWEditPresetStore
    let onDone: (RAWEditParams, LayerEdits) -> Void

    @State private var params: RAWEditParams
    @State private var previewImage: UIImage?
    @State private var isRendering = false
    @State private var selectedTab: EditorTab = .exposure
    @State private var showPresetPicker = false
    @State private var showSavePreset = false
    @State private var presetName = ""
    @State private var selectedLayer: LayerType = .global
    @State private var layerEdits: LayerEdits
    @State private var segmentation = SegmentationService()
    @State private var isMaskLoading = false
    @Environment(\.dismiss) private var dismiss

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    enum EditorTab: String, CaseIterable {
        case exposure, color, detail, lens

        var label: String {
            switch self {
            case .exposure: return String(localized: "Exposure")
            case .color: return String(localized: "Color")
            case .detail: return String(localized: "Detail")
            case .lens: return String(localized: "Lens")
            }
        }

        var icon: String {
            switch self {
            case .exposure: return "sun.max"
            case .color: return "drop.halffull"
            case .detail: return "circle.hexagongrid"
            case .lens: return "camera.aperture"
            }
        }
    }

    init(rawData: Data, resourceHint: String, assetID: String,
         previewImageForMask: UIImage? = nil,
         presetStore: RAWEditPresetStore, initialParams: RAWEditParams,
         initialLayerEdits: LayerEdits = LayerEdits(),
         onDone: @escaping (RAWEditParams, LayerEdits) -> Void) {
        self.rawData = rawData
        self.resourceHint = resourceHint
        self.assetID = assetID
        self.previewImageForMask = previewImageForMask
        self.presetStore = presetStore
        self.onDone = onDone
        self._params = State(initialValue: initialParams)
        self._layerEdits = State(initialValue: initialLayerEdits)
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
                        presetStore.saveParams(params, for: assetID)
                        presetStore.saveLayerEdits(layerEdits, for: assetID)
                        onDone(params, layerEdits)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .task {
                await generateMasks()
                await renderPreview()
            }
            .onChange(of: params) { _, _ in
                Task { await renderPreview() }
            }
            .onChange(of: layerEdits) { _, _ in
                Task { await renderPreview() }
            }
            .sheet(isPresented: $showPresetPicker) {
                RAWPresetPickerView(
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
                        presetStore.savePreset(name: presetName, params: params)
                        presetName = ""
                    }
                }
                Button("Cancel", role: .cancel) { presetName = "" }
            } message: {
                Text("Enter a name for this preset")
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
                EditorFormatBadge(format: "RAW")
                    .padding(.leading, 16)
                LayerSelectorView(selectedLayer: $selectedLayer, segmentation: segmentation)
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
                    layerParamsContent
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
    private var layerParamsContent: some View {
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
            EditorSlider(label: "Brightness", value: $params.boostAmount, range: 0...2.0, defaultValue: 1.0)
            EditorSlider(label: "Shadows", value: $params.boostShadowAmount, range: 0...2.0, defaultValue: 0.0)
            EditorSlider(label: "Contrast", value: $params.contrastAmount, range: 0...2.0, defaultValue: 1.0)
            EditorSlider(label: "Local Tone Map", value: $params.localToneMapAmount, range: 0...1.0, defaultValue: 0.0)
            EditorToggle(label: "Highlight Recovery", isOn: $params.highlightRecoveryEnabled)

        case .color:
            EditorSlider(label: "Temperature", value: $params.temperature, range: 2000...10000, defaultValue: 5000)
            EditorSlider(label: "Tint", value: $params.tint, range: -150...150, defaultValue: 0.0)
            EditorToggle(label: "Gamut Mapping", isOn: $params.gamutMappingEnabled)

        case .detail:
            EditorSlider(label: "Sharpness", value: $params.sharpnessAmount, range: 0...2.0, defaultValue: 0.0)
            EditorSlider(label: "Detail", value: $params.detailAmount, range: 0...3.0, defaultValue: 0.0)
            EditorSlider(label: "Luminance NR", value: $params.luminanceNoiseReduction, range: 0...1.0, defaultValue: 0.0)
            EditorSlider(label: "Color NR", value: $params.colorNoiseReduction, range: 0...1.0, defaultValue: 0.0)
            EditorSlider(label: "Moire Reduction", value: $params.moireReduction, range: 0...1.0, defaultValue: 0.0)

        case .lens:
            EditorToggle(label: "Lens Correction", isOn: $params.lensCorrectionEnabled)
        }
    }

    // MARK: - Rendering

    private func generateMasks() async {
        isMaskLoading = true
        defer { isMaskLoading = false }

        // Use pre-rendered UIImage from CompareView (standard sRGB CGImage)
        // This avoids CIRAWFilter output issues (non-zero extent, HDR color space)
        if let cgImage = previewImageForMask?.cgImage {
            let ciImage = CIImage(cgImage: cgImage)
            await segmentation.generateMasks(for: ciImage, identifier: assetID)
            return
        }

        // Fallback: render via CIRAWFilter (may not work for all formats)
        guard let rawFilter = CIRAWFilter(imageData: rawData, identifierHint: resourceHint) else { return }
        rawFilter.isDraftModeEnabled = true
        rawFilter.scaleFactor = 0.5
        guard let image = rawFilter.outputImage else { return }
        await segmentation.generateMasks(for: image, identifier: assetID)
    }

    private func renderPreview() async {
        guard !isRendering else { return }
        isRendering = true
        defer { isRendering = false }

        guard let rawFilter = CIRAWFilter(imageData: rawData, identifierHint: resourceHint) else { return }

        // Apply global params
        applyParams(params, to: rawFilter)

        // Draft mode for fast preview
        rawFilter.isDraftModeEnabled = true
        rawFilter.scaleFactor = 0.25

        guard var outputImage = rawFilter.outputImage else { return }

        // Apply layer edits with masks
        if layerEdits.hasAnyLayerEdits {
            for layer in [LayerType.person, .skin, .foreground, .background] {
                let lp = layerEdits.params(for: layer)
                if lp.isModified, let mask = segmentation.mask(for: layer, imageExtent: outputImage.extent) {
                    outputImage = SegmentationService.applyLayerEdits(lp, to: outputImage, mask: mask)
                }
            }
        }

        // Render to UIImage
        let extent = outputImage.extent
        guard let cgImage = ciContext.createCGImage(outputImage, from: extent) else { return }
        let uiImage = UIImage(cgImage: cgImage)

        await MainActor.run {
            previewImage = uiImage
        }
    }

    static func applyParams(_ params: RAWEditParams, to filter: CIRAWFilter) {
        filter.exposure = params.exposure
        filter.boostAmount = params.boostAmount
        filter.boostShadowAmount = params.boostShadowAmount

        if filter.isContrastSupported {
            filter.contrastAmount = params.contrastAmount
        }
        if filter.isLocalToneMapSupported {
            filter.localToneMapAmount = params.localToneMapAmount
        }
        if filter.isHighlightRecoverySupported {
            filter.isHighlightRecoveryEnabled = params.highlightRecoveryEnabled
        }

        filter.neutralTemperature = params.temperature
        filter.neutralTint = params.tint
        filter.isGamutMappingEnabled = params.gamutMappingEnabled

        if filter.isSharpnessSupported {
            filter.sharpnessAmount = params.sharpnessAmount
        }
        if filter.isDetailSupported {
            filter.detailAmount = params.detailAmount
        }
        if filter.isLuminanceNoiseReductionSupported {
            filter.luminanceNoiseReductionAmount = params.luminanceNoiseReduction
        }
        if filter.isColorNoiseReductionSupported {
            filter.colorNoiseReductionAmount = params.colorNoiseReduction
        }
        if filter.isMoireReductionSupported {
            filter.moireReductionAmount = params.moireReduction
        }
        if filter.isLensCorrectionSupported {
            filter.isLensCorrectionEnabled = params.lensCorrectionEnabled
        }
    }

    private func applyParams(_ params: RAWEditParams, to filter: CIRAWFilter) {
        Self.applyParams(params, to: filter)
    }
}
