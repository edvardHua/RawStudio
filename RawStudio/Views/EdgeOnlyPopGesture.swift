import SwiftUI
import UIKit

/// 禁用 NavigationStack 默认的 interactivePopGestureRecognizer，
/// 改装一个左屏幕边缘 pan（UIScreenEdgePanGestureRecognizer）触发 pop。
/// 效果：只有从左边缘开始的右滑会返回；中间右滑可被子视图（如 ZoomableImageView 的 UISwipe right）正常吃掉去做"上一张"。
struct EdgeOnlyPopModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.background(EdgeOnlyPopBridge())
    }
}

extension View {
    /// 应用 EdgeOnlyPopModifier — push 进来的页面里调用一次
    func edgeOnlyPop() -> some View {
        modifier(EdgeOnlyPopModifier())
    }
}

/// 用 UIViewRepresentable 而非 ControllerRepresentable —— SwiftUI 在 `.background()`
/// 里的 ControllerRepresentable 不一定真正接入 navigation hierarchy，导致
/// viewWillAppear 时 navigationController 是 nil。
/// 直接用 UIView + didMoveToWindow + responder chain walk 是更可靠的桥接点。
private struct EdgeOnlyPopBridge: UIViewRepresentable {
    func makeUIView(context: Context) -> EdgeOnlyPopBridgeView {
        EdgeOnlyPopBridgeView()
    }
    func updateUIView(_ view: EdgeOnlyPopBridgeView, context: Context) {}
}

private final class EdgeOnlyPopBridgeView: UIView {
    private var installedEdgeGesture: UIScreenEdgePanGestureRecognizer?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            installIfNeeded()
        } else {
            restoreSystemPop()
        }
    }

    deinit {
        // window 已断开时 navController 也走不到；只能尽力清掉本地引用，
        // 实际的 isEnabled 复位 / removeGestureRecognizer 由 didMoveToWindow(nil) 保证。
        installedEdgeGesture = nil
    }

    /// 从 self 沿 responder chain 向上找 UINavigationController；不依赖 SwiftUI 对 child VC 的接入。
    private var navController: UINavigationController? {
        var responder: UIResponder? = self
        while let r = responder {
            if let nav = r as? UINavigationController { return nav }
            if let vc = r as? UIViewController, let nav = vc.navigationController { return nav }
            responder = r.next
        }
        return nil
    }

    private func installIfNeeded() {
        guard let nav = navController else { return }
        nav.interactivePopGestureRecognizer?.isEnabled = false
        guard installedEdgeGesture == nil else { return }
        let g = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdge(_:)))
        g.edges = .left
        nav.view.addGestureRecognizer(g)
        installedEdgeGesture = g
    }

    private func restoreSystemPop() {
        guard let nav = navController else { return }
        nav.interactivePopGestureRecognizer?.isEnabled = true
        if let g = installedEdgeGesture {
            nav.view.removeGestureRecognizer(g)
            installedEdgeGesture = nil
        }
    }

    @objc private func handleEdge(_ g: UIScreenEdgePanGestureRecognizer) {
        guard g.state == .recognized || g.state == .ended else { return }
        navController?.popViewController(animated: true)
    }
}
