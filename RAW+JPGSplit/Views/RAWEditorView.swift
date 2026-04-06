import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import Photos

struct RAWEditorView: View {
    let rawData: Data
    let resourceHint: String
    let assetID: String
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
         presetStore: RAWEditPresetStore, initialParams: RAWEditParams,
         initialLayerEdits: LayerEdits = LayerEdits(),
         onDone: @escaping (RAWEditParams, LayerEdits) -> Void) {
        self.rawData = rawData
        self.resourceHint = resourceHint
        self.assetID = assetID
        self.presetStore = presetStore
        self.onDone = onDone
        self._params = State(initialValue: initialParams)
        self._layerEdits = State(initialValue: initialLayerEdits)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Preview area
                    previewArea
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // Editor controls
                    editorControls
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        presetStore.saveParams(params, for: assetID)
                        // Save layer edits
                        let layerKey = "layerEdits_\(assetID)"
                        if let data = try? JSONEncoder().encode(layerEdits) {
                            UserDefaults.standard.set(data, forKey: layerKey)
                        }
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
            // Layer selector
            LayerSelectorView(selectedLayer: $selectedLayer, segmentation: segmentation)
                .padding(.top, 8)
                .padding(.bottom, 4)

            if selectedLayer == .global {
                // Global editing: full RAW params
                controlsToolbar
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 6)

                tabSelector
                    .padding(.bottom, 8)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 14) {
                        tabContent
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                }
                .frame(height: 200)
            } else {
                // Layer editing: 5 common params
                HStack {
                    Button {
                        var p = layerEdits.params(for: selectedLayer)
                        p.reset()
                        layerEdits.setParams(p, for: selectedLayer)
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                            .font(.caption)
                    }
                    .disabled(!layerEdits.params(for: selectedLayer).isModified)
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 6)

                ScrollView(.vertical, showsIndicators: false) {
                    layerParamsContent
                        .padding(.horizontal, 16)
                        .padding(.bottom, 20)
                }
                .frame(height: 220)
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

    private var controlsToolbar: some View {
        HStack {
            Button {
                params.reset()
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
                    .font(.caption)
            }
            .disabled(!params.isModified)

            Spacer()

            Button {
                showPresetPicker = true
            } label: {
                Label("Presets", systemImage: "slider.horizontal.below.square.filled.and.square")
                    .font(.caption)
            }

            Spacer()

            Button {
                showSavePreset = true
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
                    .font(.caption)
            }
            .disabled(!params.isModified)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }

    private var tabSelector: some View {
        HStack(spacing: 0) {
            ForEach(EditorTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedTab = tab
                    }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 16))
                        Text(tab.label)
                            .font(.system(size: 10))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .foregroundStyle(selectedTab == tab ? .white : .white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .exposure:
            paramSlider(label: "Exposure", value: $params.exposure, range: -3.0...3.0, defaultValue: 0.0)
            paramSlider(label: "Brightness", value: $params.boostAmount, range: 0...2.0, defaultValue: 1.0)
            paramSlider(label: "Shadows", value: $params.boostShadowAmount, range: 0...2.0, defaultValue: 0.0)
            paramSlider(label: "Contrast", value: $params.contrastAmount, range: 0...2.0, defaultValue: 1.0)
            paramSlider(label: "Local Tone Map", value: $params.localToneMapAmount, range: 0...1.0, defaultValue: 0.0)
            toggleParam(label: "Highlight Recovery", isOn: $params.highlightRecoveryEnabled)

        case .color:
            paramSlider(label: "Temperature", value: $params.temperature, range: 2000...10000, defaultValue: 5000)
            paramSlider(label: "Tint", value: $params.tint, range: -150...150, defaultValue: 0.0)
            toggleParam(label: "Gamut Mapping", isOn: $params.gamutMappingEnabled)

        case .detail:
            paramSlider(label: "Sharpness", value: $params.sharpnessAmount, range: 0...2.0, defaultValue: 0.0)
            paramSlider(label: "Detail", value: $params.detailAmount, range: 0...3.0, defaultValue: 0.0)
            paramSlider(label: "Luminance NR", value: $params.luminanceNoiseReduction, range: 0...1.0, defaultValue: 0.0)
            paramSlider(label: "Color NR", value: $params.colorNoiseReduction, range: 0...1.0, defaultValue: 0.0)
            paramSlider(label: "Moire Reduction", value: $params.moireReduction, range: 0...1.0, defaultValue: 0.0)

        case .lens:
            toggleParam(label: "Lens Correction", isOn: $params.lensCorrectionEnabled)
        }
    }

    // MARK: - Parameter Controls

    private func paramSlider(label: String, value: Binding<Float>, range: ClosedRange<Float>, defaultValue: Float) -> some View {
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

                // Reset single param
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

    private func toggleParam(label: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(LocalizedStringKey(label))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
        }
        .toggleStyle(.switch)
        .tint(.accentColor)
    }

    private func formatValue(_ value: Float, range: ClosedRange<Float>) -> String {
        if range.upperBound >= 1000 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.2f", value)
    }

    // MARK: - Rendering

    private func generateMasks() async {
        guard let rawFilter = CIRAWFilter(imageData: rawData, identifierHint: resourceHint) else { return }
        rawFilter.isDraftModeEnabled = true
        rawFilter.scaleFactor = 0.25
        guard let image = rawFilter.outputImage else { return }
        isMaskLoading = true
        await segmentation.generateMasks(for: image, identifier: assetID)
        isMaskLoading = false
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
            for layer in [LayerType.person, .foreground, .background] {
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
