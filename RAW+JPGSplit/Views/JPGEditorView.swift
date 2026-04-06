import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

struct JPGEditorView: View {
    let imageData: Data
    let assetID: String
    var presetStore: RAWEditPresetStore
    let onDone: (JPGEditParams, UIImage?) -> Void

    @State private var params: JPGEditParams
    @State private var previewImage: UIImage?
    @State private var isRendering = false
    @State private var selectedTab: EditorTab = .exposure
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
         initialParams: JPGEditParams, onDone: @escaping (JPGEditParams, UIImage?) -> Void) {
        self.imageData = imageData
        self.assetID = assetID
        self.presetStore = presetStore
        self.onDone = onDone
        self._params = State(initialValue: initialParams)

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
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    previewArea
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

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
                        let jpgKey = "jpgEditParams_\(assetID)"
                        if let data = try? JSONEncoder().encode(params) {
                            UserDefaults.standard.set(data, forKey: jpgKey)
                        }
                        onDone(params, previewImage)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .task { await renderPreview() }
            .onChange(of: params) { _, _ in
                Task { await renderPreview() }
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

    // MARK: - Controls

    private var editorControls: some View {
        VStack(spacing: 0) {
            // Reset button
            HStack {
                Button {
                    params.reset()
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                        .font(.caption)
                }
                .disabled(!params.isModified)
                .buttonStyle(.plain)
                .foregroundStyle(.white)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // Tabs
            tabSelector
                .padding(.bottom, 8)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 14) {
                    tabContent
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
            .frame(height: 220)
        }
        .background(.ultraThinMaterial)
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
            paramSlider(label: "Brightness", value: $params.brightness, range: -0.5...0.5, defaultValue: 0.0)
            paramSlider(label: "Contrast", value: $params.contrast, range: 0.5...2.0, defaultValue: 1.0)
            paramSlider(label: "Highlights", value: $params.highlights, range: 0...2.0, defaultValue: 1.0)
            paramSlider(label: "Shadows", value: $params.shadows, range: -1.0...1.0, defaultValue: 0.0)

        case .color:
            paramSlider(label: "Temperature", value: $params.warmth, range: 2000...10000, defaultValue: 6500)
            paramSlider(label: "Tint", value: $params.tint, range: -150...150, defaultValue: 0.0)
            paramSlider(label: "Saturation", value: $params.saturation, range: 0...2.0, defaultValue: 1.0)
            paramSlider(label: "Vibrance", value: $params.vibrance, range: -1.0...1.0, defaultValue: 0.0)

        case .detail:
            paramSlider(label: "Sharpness", value: $params.sharpness, range: 0...2.0, defaultValue: 0.0)
        }
    }

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

    // MARK: - Rendering

    private func renderPreview() async {
        guard !isRendering, let source = sourceImage else { return }
        isRendering = true
        defer { isRendering = false }

        let output = Self.applyParams(params, to: source)

        // Scale down for preview
        let scale: CGFloat = 0.25
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

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
}
