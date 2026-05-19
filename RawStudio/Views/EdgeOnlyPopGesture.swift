import SwiftUI
import UIKit

/// 禁用 NavigationStack 默认的 interactivePopGestureRecognizer，
/// 改装一个左屏幕边缘 pan（UIScreenEdgePanGestureRecognizer）触发 pop。
/// 效果：只有从左边缘开始的右滑会返回；中间右滑可被子视图（如 ZoomableImageView 的 UISwipe right）正常吃掉去做"上一张"。
struct EdgeOnlyPopModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.background(NavGestureBridge())
    }
}

extension View {
    /// 应用 EdgeOnlyPopModifier — push 进来的页面里调用一次
    func edgeOnlyPop() -> some View {
        modifier(EdgeOnlyPopModifier())
    }
}

private struct NavGestureBridge: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> EdgeOnlyController {
        EdgeOnlyController()
    }
    func updateUIViewController(_ vc: EdgeOnlyController, context: Context) {}
}

private final class EdgeOnlyController: UIViewController {
    private var installedEdgeGesture: UIScreenEdgePanGestureRecognizer?

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard let nav = navigationController else { return }
        nav.interactivePopGestureRecognizer?.isEnabled = false
        if installedEdgeGesture == nil {
            installEdgeGesture(on: nav)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        restoreSystemPop()
    }

    deinit {
        restoreSystemPop()
    }

    private func restoreSystemPop() {
        guard let nav = navigationController else { return }
        nav.interactivePopGestureRecognizer?.isEnabled = true
        if let g = installedEdgeGesture {
            nav.view.removeGestureRecognizer(g)
            installedEdgeGesture = nil
        }
    }

    private func installEdgeGesture(on nav: UINavigationController) {
        let g = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdge(_:)))
        g.edges = .left
        nav.view.addGestureRecognizer(g)
        installedEdgeGesture = g
    }

    @objc private func handleEdge(_ g: UIScreenEdgePanGestureRecognizer) {
        guard g.state == .recognized || g.state == .ended else { return }
        navigationController?.popViewController(animated: true)
    }
}
