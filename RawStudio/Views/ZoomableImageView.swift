import SwiftUI
import UIKit

struct ZoomState: Equatable {
    var scale: CGFloat = 1.0
    var offset: CGPoint = .zero
}

struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    @Binding var zoomState: ZoomState   // OUTPUT ONLY — scrollview writes up; nothing writes down
    let resetVersion: Int               // 每 +1 触发一次 zoom 重置（外部命令）
    var onSwipeLeft: (() -> Void)?
    var onSwipeRight: (() -> Void)?

    func makeUIView(context: Context) -> ZoomableScrollView {
        let view = ZoomableScrollView()
        view.zoomStateChanged = { state in
            context.coordinator.handleZoomStateChanged(state)
        }
        view.onSwipeLeft = onSwipeLeft
        view.onSwipeRight = onSwipeRight
        view.setImage(image)
        context.coordinator.lastSeenResetVersion = resetVersion
        return view
    }

    func updateUIView(_ view: ZoomableScrollView, context: Context) {
        if view.currentImage !== image {
            view.setImage(image)   // setImage 内部已置 zoomScale = 1.0
            context.coordinator.lastSeenResetVersion = resetVersion
            view.onSwipeLeft = onSwipeLeft
            view.onSwipeRight = onSwipeRight
            return
        }
        view.onSwipeLeft = onSwipeLeft
        view.onSwipeRight = onSwipeRight
        if resetVersion != context.coordinator.lastSeenResetVersion {
            context.coordinator.lastSeenResetVersion = resetVersion
            view.resetZoom(animated: true)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(zoomState: $zoomState, initialResetVersion: resetVersion)
    }

    class Coordinator {
        @Binding var zoomState: ZoomState
        var lastSeenResetVersion: Int

        init(zoomState: Binding<ZoomState>, initialResetVersion: Int) {
            _zoomState = zoomState
            self.lastSeenResetVersion = initialResetVersion
        }

        func handleZoomStateChanged(_ state: ZoomState) {
            zoomState = state
        }
    }
}

// MARK: - UIKit ScrollView

class ZoomableScrollView: UIScrollView, UIScrollViewDelegate {

    private let imageView = UIImageView()
    private(set) var currentImage: UIImage?
    var zoomStateChanged: ((ZoomState) -> Void)?
    var onSwipeLeft: (() -> Void)?
    var onSwipeRight: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        delegate = self
        minimumZoomScale = 1.0
        maximumZoomScale = 5.0
        bouncesZoom = true
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        backgroundColor = .clear

        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)

        let swipeLeft = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeLeft(_:)))
        swipeLeft.direction = .left
        addGestureRecognizer(swipeLeft)

        let swipeRight = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeRight(_:)))
        swipeRight.direction = .right
        addGestureRecognizer(swipeRight)
    }

    func setImage(_ image: UIImage) {
        currentImage = image
        imageView.image = image
        zoomScale = 1.0
        setNeedsLayout()
        layoutIfNeeded()
    }

    /// 外部命令式 reset；mid-gesture 时跳过避免抢用户输入
    func resetZoom(animated: Bool) {
        if isZooming { return }
        if let pinch = pinchGestureRecognizer,
           pinch.state == .began || pinch.state == .changed {
            return
        }
        setZoomScale(1.0, animated: animated)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let image = currentImage, bounds.size != .zero else { return }

        let boundsSize = bounds.size
        let imageSize = image.size

        guard imageSize.width > 0 && imageSize.height > 0 else { return }

        let widthRatio = boundsSize.width / imageSize.width
        let heightRatio = boundsSize.height / imageSize.height
        let fitScale = min(widthRatio, heightRatio)

        let fitWidth = imageSize.width * fitScale
        let fitHeight = imageSize.height * fitScale

        imageView.frame = CGRect(
            x: 0, y: 0,
            width: fitWidth,
            height: fitHeight
        )
        contentSize = CGSize(width: fitWidth, height: fitHeight)

        centerImageView()
    }

    private func centerImageView() {
        let boundsSize = bounds.size
        var frameToCenter = imageView.frame

        if frameToCenter.size.width < boundsSize.width {
            frameToCenter.origin.x = (boundsSize.width - frameToCenter.size.width) / 2.0
        } else {
            frameToCenter.origin.x = 0
        }

        if frameToCenter.size.height < boundsSize.height {
            frameToCenter.origin.y = (boundsSize.height - frameToCenter.size.height) / 2.0
        } else {
            frameToCenter.origin.y = 0
        }

        imageView.frame = frameToCenter
    }

    // MARK: - UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImageView()
        zoomStateChanged?(ZoomState(scale: zoomScale, offset: contentOffset))
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard isDragging || isDecelerating else { return }
        zoomStateChanged?(ZoomState(scale: zoomScale, offset: contentOffset))
    }

    // MARK: - Gestures

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if zoomScale > 1.0 {
            setZoomScale(1.0, animated: true)
        } else {
            let point = gesture.location(in: imageView)
            let size = CGSize(
                width: bounds.width / 3.0,
                height: bounds.height / 3.0
            )
            let rect = CGRect(
                origin: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2),
                size: size
            )
            zoom(to: rect, animated: true)
        }
    }

    @objc private func handleSwipeLeft(_ gesture: UISwipeGestureRecognizer) {
        guard zoomScale <= 1.0 else { return }
        onSwipeLeft?()
    }

    @objc private func handleSwipeRight(_ gesture: UISwipeGestureRecognizer) {
        guard zoomScale <= 1.0 else { return }
        onSwipeRight?()
    }
}
