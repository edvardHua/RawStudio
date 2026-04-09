import SwiftUI
import CoreGraphics
import UIKit

// MARK: - Paint Tool

enum PaintTool: String, CaseIterable {
    case brush, wand, eraser

    var label: String {
        switch self {
        case .brush: return String(localized: "Brush")
        case .wand: return String(localized: "Wand")
        case .eraser: return String(localized: "Eraser")
        }
    }

    var icon: String {
        switch self {
        case .brush: return "paintbrush.fill"
        case .wand: return "wand.and.stars"
        case .eraser: return "eraser.fill"
        }
    }
}

// MARK: - MaskBitmap

/// A mutable grayscale bitmap representing the mask.
final class MaskBitmap {
    var data: Data
    let width: Int
    let height: Int

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.data = Data(count: width * height)
    }

    init(width: Int, height: Int, data: Data) {
        self.width = width
        self.height = height
        self.data = data
    }

    func setPixel(x: Int, y: Int, value: UInt8) {
        guard x >= 0, x < width, y >= 0, y < height else { return }
        let idx = y * width + x
        data[idx] = value
    }

    func getPixel(x: Int, y: Int) -> UInt8 {
        guard x >= 0, x < width, y >= 0, y < height else { return 0 }
        return data[y * width + x]
    }

    func toCGImage() -> CGImage? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.linearGray),
              let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    func clear() {
        data = Data(count: width * height)
    }

    func snapshot() -> Data {
        Data(data)
    }

    func restore(from snapshot: Data) {
        guard snapshot.count == data.count else { return }
        data = snapshot
    }

    /// Initialize from an existing CGImage mask (grayscale)
    func loadFrom(_ cgImage: CGImage) {
        guard let context = CGContext(
            data: nil,
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpace(name: CGColorSpace.linearGray)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        ) else { return }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let rawData = context.data else { return }
        data = Data(bytes: rawData, count: width * height)
    }
}

// MARK: - MaskCanvasUIView

final class MaskCanvasUIView: UIView {
    var sourceImage: UIImage?
    var maskBitmap: MaskBitmap?
    var tool: PaintTool = .brush
    var brushSize: CGFloat = 24
    var wandTolerance: Float = 30
    var onStrokeComplete: (() -> Void)?

    private let sourceLayer = CALayer()
    private let overlayLayer = CALayer()
    private var lastPoint: CGPoint?
    private var sourceCGImage: CGImage?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .black
        layer.addSublayer(sourceLayer)
        layer.addSublayer(overlayLayer)
        sourceLayer.contentsGravity = .resizeAspect
        overlayLayer.contentsGravity = .resizeAspect
        overlayLayer.opacity = 0.35
        isMultipleTouchEnabled = false
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        sourceLayer.frame = bounds
        overlayLayer.frame = bounds
        if let img = sourceImage {
            sourceLayer.contents = img.cgImage
            sourceCGImage = img.cgImage
        }
        updateOverlay()
    }

    func configure(sourceImage: UIImage, bitmap: MaskBitmap) {
        self.sourceImage = sourceImage
        self.maskBitmap = bitmap
        self.sourceCGImage = sourceImage.cgImage
        sourceLayer.contents = sourceImage.cgImage
        updateOverlay()
    }

    // MARK: - Coordinate Conversion

    /// Convert a point in the view to pixel coordinates in the bitmap
    private func viewToPixel(_ point: CGPoint) -> (x: Int, y: Int)? {
        guard let bitmap = maskBitmap, let img = sourceImage else { return nil }

        let imageSize = img.size
        let viewSize = bounds.size
        guard viewSize.width > 0, viewSize.height > 0 else { return nil }

        // Calculate aspect-fit rect
        let imageAspect = imageSize.width / imageSize.height
        let viewAspect = viewSize.width / viewSize.height

        let fitRect: CGRect
        if imageAspect > viewAspect {
            // Image wider than view — pillarbox
            let fitW = viewSize.width
            let fitH = fitW / imageAspect
            let y = (viewSize.height - fitH) / 2
            fitRect = CGRect(x: 0, y: y, width: fitW, height: fitH)
        } else {
            // Image taller — letterbox
            let fitH = viewSize.height
            let fitW = fitH * imageAspect
            let x = (viewSize.width - fitW) / 2
            fitRect = CGRect(x: x, y: 0, width: fitW, height: fitH)
        }

        // Map point to bitmap
        let normX = (point.x - fitRect.origin.x) / fitRect.width
        let normY = (point.y - fitRect.origin.y) / fitRect.height

        let px = Int(normX * CGFloat(bitmap.width))
        let py = Int(normY * CGFloat(bitmap.height))

        guard px >= 0, px < bitmap.width, py >= 0, py < bitmap.height else { return nil }
        return (px, py)
    }

    /// Scale brush size from view points to bitmap pixels
    private func scaledBrushRadius() -> Int {
        guard let bitmap = maskBitmap, let img = sourceImage else { return 12 }
        let viewSize = bounds.size
        let imageSize = img.size
        guard viewSize.width > 0 else { return 12 }

        let imageAspect = imageSize.width / imageSize.height
        let viewAspect = viewSize.width / viewSize.height

        let fitW: CGFloat
        if imageAspect > viewAspect {
            fitW = viewSize.width
        } else {
            fitW = viewSize.height * imageAspect
        }

        let scale = CGFloat(bitmap.width) / fitW
        return max(1, Int(brushSize * scale / 2))
    }

    // MARK: - Drawing

    private func drawCircle(at pixel: (x: Int, y: Int), value: UInt8) {
        guard let bitmap = maskBitmap else { return }
        let radius = scaledBrushRadius()

        for dy in -radius...radius {
            for dx in -radius...radius {
                if dx * dx + dy * dy <= radius * radius {
                    bitmap.setPixel(x: pixel.x + dx, y: pixel.y + dy, value: value)
                }
            }
        }
    }

    private func interpolateAndDraw(from p1: CGPoint, to p2: CGPoint, value: UInt8) {
        let dist = hypot(p2.x - p1.x, p2.y - p1.y)
        let steps = max(1, Int(dist))

        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let x = p1.x + (p2.x - p1.x) * t
            let y = p1.y + (p2.y - p1.y) * t
            if let pixel = viewToPixel(CGPoint(x: x, y: y)) {
                drawCircle(at: pixel, value: value)
            }
        }
    }

    // MARK: - Touch Handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let point = touch.location(in: self)
        lastPoint = point

        if tool == .wand {
            // Wand does work on touchesEnded
            return
        }

        let value: UInt8 = (tool == .eraser) ? 0 : 255
        if let pixel = viewToPixel(point) {
            drawCircle(at: pixel, value: value)
            updateOverlay()
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, tool != .wand else { return }
        let point = touch.location(in: self)
        let value: UInt8 = (tool == .eraser) ? 0 : 255

        if let last = lastPoint {
            interpolateAndDraw(from: last, to: point, value: value)
        }
        lastPoint = point
        updateOverlay()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if tool == .wand, let touch = touches.first {
            let point = touch.location(in: self)
            performFloodFill(at: point)
        }
        lastPoint = nil
        onStrokeComplete?()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        lastPoint = nil
        onStrokeComplete?()
    }

    // MARK: - Flood Fill (Magic Wand)

    private func performFloodFill(at viewPoint: CGPoint) {
        guard let bitmap = maskBitmap,
              let pixel = viewToPixel(viewPoint),
              let cgImage = sourceCGImage else { return }

        let w = cgImage.width
        let h = cgImage.height
        let tolerance = wandTolerance

        // Get source pixel data
        guard let context = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        ) else { return }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let rawPtr = context.data else { return }
        let ptr = rawPtr.bindMemory(to: UInt8.self, capacity: w * h * 4)

        // Scale tap pixel to source image coordinates
        let scaleX = CGFloat(w) / CGFloat(bitmap.width)
        let scaleY = CGFloat(h) / CGFloat(bitmap.height)
        let srcX = min(w - 1, max(0, Int(CGFloat(pixel.x) * scaleX)))
        let srcY = min(h - 1, max(0, Int(CGFloat(pixel.y) * scaleY)))

        // Get target color
        let targetIdx = (srcY * w + srcX) * 4
        let tR = Float(ptr[targetIdx])
        let tG = Float(ptr[targetIdx + 1])
        let tB = Float(ptr[targetIdx + 2])

        // BFS flood fill — work in bitmap coordinates
        var visited = Data(count: bitmap.width * bitmap.height)
        var queue: [(Int, Int)] = [(pixel.x, pixel.y)]
        visited[pixel.y * bitmap.width + pixel.x] = 1
        var processed = 0
        let maxPixels = 1_000_000

        while !queue.isEmpty && processed < maxPixels {
            let (bx, by) = queue.removeFirst()
            processed += 1

            bitmap.setPixel(x: bx, y: by, value: 255)

            let neighbors = [(bx-1, by), (bx+1, by), (bx, by-1), (bx, by+1)]
            for (nx, ny) in neighbors {
                guard nx >= 0, nx < bitmap.width, ny >= 0, ny < bitmap.height else { continue }
                let nIdx = ny * bitmap.width + nx
                guard visited[nIdx] == 0 else { continue }
                visited[nIdx] = 1

                // Map bitmap coordinate to source image coordinate
                let sx = min(w - 1, max(0, Int(CGFloat(nx) * scaleX)))
                let sy = min(h - 1, max(0, Int(CGFloat(ny) * scaleY)))
                let sIdx = (sy * w + sx) * 4
                let r = Float(ptr[sIdx])
                let g = Float(ptr[sIdx + 1])
                let b = Float(ptr[sIdx + 2])

                let dist: Float = sqrt((r - tR) * (r - tR) + (g - tG) * (g - tG) + (b - tB) * (b - tB))
                if dist <= tolerance * Float(2.55) { // tolerance 0-100 → 0-255 range
                    queue.append((nx, ny))
                }
            }
        }

        updateOverlay()
    }

    // MARK: - Overlay

    func updateOverlay() {
        guard let bitmap = maskBitmap, let maskCG = bitmap.toCGImage() else {
            overlayLayer.contents = nil
            return
        }

        // Create red-tinted version of the mask
        let w = bitmap.width
        let h = bitmap.height
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        ) else { return }

        // Draw mask as alpha channel with red color
        ctx.setFillColor(UIColor.clear.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // Use the mask as a clipping mask, then fill with red
        ctx.clip(to: CGRect(x: 0, y: 0, width: w, height: h), mask: maskCG)
        ctx.setFillColor(UIColor.red.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        if let result = ctx.makeImage() {
            overlayLayer.contents = result
        }
    }
}

// MARK: - MaskCanvasView (UIViewRepresentable)

struct MaskCanvasView: UIViewRepresentable {
    let sourceImage: UIImage
    let tool: PaintTool
    let brushSize: Float
    let wandTolerance: Float
    let maskBitmap: MaskBitmap
    var onStrokeComplete: () -> Void

    func makeUIView(context: Context) -> MaskCanvasUIView {
        let view = MaskCanvasUIView()
        view.configure(sourceImage: sourceImage, bitmap: maskBitmap)
        view.tool = tool
        view.brushSize = CGFloat(brushSize)
        view.wandTolerance = wandTolerance
        view.onStrokeComplete = onStrokeComplete
        return view
    }

    func updateUIView(_ uiView: MaskCanvasUIView, context: Context) {
        uiView.tool = tool
        uiView.brushSize = CGFloat(brushSize)
        uiView.wandTolerance = wandTolerance
        uiView.onStrokeComplete = onStrokeComplete
        uiView.maskBitmap = maskBitmap
        uiView.updateOverlay()
    }
}

// MARK: - MaskPainterView

struct MaskPainterView: View {
    let sourceImage: UIImage
    let existingMask: CGImage?
    let onDone: (CGImage) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTool: PaintTool = .brush
    @State private var brushSize: Float = 24
    @State private var wandTolerance: Float = 30
    @State private var undoStack: [Data] = []
    @State private var redoStack: [Data] = []
    @State private var maskBitmap: MaskBitmap
    @State private var overlayRefreshID = UUID()

    @ScaledMetric(relativeTo: .caption2) private var padH: CGFloat = 10
    @ScaledMetric(relativeTo: .caption2) private var padV: CGFloat = 5

    init(sourceImage: UIImage, existingMask: CGImage? = nil, onDone: @escaping (CGImage) -> Void) {
        self.sourceImage = sourceImage
        self.existingMask = existingMask
        self.onDone = onDone

        let w = Int(sourceImage.size.width)
        let h = Int(sourceImage.size.height)
        let bitmap = MaskBitmap(width: max(1, w), height: max(1, h))
        if let mask = existingMask {
            bitmap.loadFrom(mask)
        }
        self._maskBitmap = State(initialValue: bitmap)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemBackground).ignoresSafeArea()

                VStack(spacing: 0) {
                    // Canvas
                    MaskCanvasView(
                        sourceImage: sourceImage,
                        tool: selectedTool,
                        brushSize: brushSize,
                        wandTolerance: wandTolerance,
                        maskBitmap: maskBitmap,
                        onStrokeComplete: {
                            // Push undo snapshot
                            undoStack.append(maskBitmap.snapshot())
                            redoStack.removeAll()
                            overlayRefreshID = UUID()
                        }
                    )
                    .id(overlayRefreshID)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // Tools
                    VStack(spacing: 12) {
                        // Tool selector capsules
                        HStack(spacing: 8) {
                            ForEach(PaintTool.allCases, id: \.self) { paintTool in
                                toolCapsule(paintTool.label, icon: paintTool.icon, tool: paintTool)
                            }
                            Spacer()
                        }

                        // Size/Tolerance slider
                        if selectedTool == .wand {
                            EditorSlider(label: "Tolerance", value: $wandTolerance, range: 0...100, defaultValue: 30)
                        } else {
                            EditorSlider(label: "Size", value: $brushSize, range: 4...100, defaultValue: 24)
                        }

                        // Undo/Redo capsules
                        HStack(spacing: 8) {
                            undoCapsule
                            redoCapsule
                            Spacer()
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    Button("Clear") { clearMask() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        if let cgImage = maskBitmap.toCGImage() {
                            onDone(cgImage)
                        }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: - Tool Capsule

    private func toolCapsule(_ label: String, icon: String, tool: PaintTool) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedTool = tool
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2)
                Text(label)
                    .font(.caption2.weight(.medium))
            }
            .foregroundStyle(selectedTool == tool ? .white : .primary.opacity(0.6))
            .padding(.horizontal, padH)
            .padding(.vertical, padV)
            .background(
                selectedTool == tool
                    ? AnyShapeStyle(Color.accentColor.opacity(0.8))
                    : AnyShapeStyle(.ultraThinMaterial),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Undo / Redo

    private var undoCapsule: some View {
        Button {
            guard let snapshot = undoStack.popLast() else { return }
            redoStack.append(maskBitmap.snapshot())
            // The snapshot at the top of the undo stack is the state BEFORE the last stroke
            // Actually, we push AFTER stroke completes, so the stack entry is the state at that point
            // We need to go back one step: use the previous entry
            if let previous = undoStack.last {
                maskBitmap.restore(from: previous)
            } else {
                maskBitmap.clear()
            }
            overlayRefreshID = UUID()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.caption2)
                Text("Undo")
                    .font(.caption2.weight(.medium))
            }
            .foregroundStyle(.primary.opacity(undoStack.isEmpty ? 0.2 : 0.6))
            .padding(.horizontal, padH)
            .padding(.vertical, padV)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(undoStack.isEmpty)
    }

    private var redoCapsule: some View {
        Button {
            guard let snapshot = redoStack.popLast() else { return }
            undoStack.append(maskBitmap.snapshot())
            maskBitmap.restore(from: snapshot)
            overlayRefreshID = UUID()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.uturn.forward")
                    .font(.caption2)
                Text("Redo")
                    .font(.caption2.weight(.medium))
            }
            .foregroundStyle(.primary.opacity(redoStack.isEmpty ? 0.2 : 0.6))
            .padding(.horizontal, padH)
            .padding(.vertical, padV)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(redoStack.isEmpty)
    }

    // MARK: - Clear

    private func clearMask() {
        undoStack.append(maskBitmap.snapshot())
        redoStack.removeAll()
        maskBitmap.clear()
        overlayRefreshID = UUID()
    }
}
