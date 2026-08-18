import AppKit
import SwiftUI

/// `HSplitView`(AppKit `NSSplitView`) 조상을 찾아 첫 레이아웃에서 divider를 `ratio` 위치로
/// 강제 이동시키는 크기 0짜리 관찰용 뷰 (2026-08-18 — "창 열 때 사이드바:목록 기본 비율" 요청).
///
/// **왜 순수 SwiftUI 프레임 힌트가 아니라 이 방식인가** — 실측으로 두 가지가 전부 깨졌다:
/// 1. `idealWidth`는 **최초 마운트에서 무시된다.** `NSSplitView`가 두 pane을 반반(예: 1080폭
///    이면 540/540)으로 나눈 뒤 min/maxWidth로만 clamp한다 — 사이드바가 매번 `maxWidth`
///    (예: 400)로 뜨는 원인이었다.
/// 2. 마운트 후 rigid `frame(width:)` → `frame(minWidth:idealWidth:maxWidth:)`로 전환해
///    한 번 자리를 잡아도(예: 216), 프레임이 바뀌는 순간 `NSSplitView`가 재배치하면서
///    `idealWidth`가 아니라 그 뷰의 `fittingSize`(SwiftUI 콘텐츠 기준 사실상 최소)로
///    수렴해 `minWidth`로 튕긴다.
///
/// 그래서 `setPosition(_:ofDividerAt:)`을 직접 호출하는 이 프로브만 유일하게 먹혔다.
/// `SidebarPane`/`FileListPane`은 순수 SwiftUI로 남기 때문에 environment/focus 체인은
/// 전혀 바뀌지 않는다 — 이 뷰 자체는 화면에 아무것도 그리지 않는 관찰자일 뿐이다.
struct SplitRatioProbe: NSViewRepresentable {
    /// 창을 열 때 leading pane(사이드바)이 차지할 비율. 1:4 요청이므로 1/5.
    let ratio: CGFloat
    let minWidth: CGFloat
    let maxWidth: CGFloat

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.ratio = ratio
        view.minWidth = minWidth
        view.maxWidth = maxWidth
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.ratio = ratio
        nsView.minWidth = minWidth
        nsView.maxWidth = maxWidth
    }

    /// 실제 로직을 쥔 크기 0짜리 `NSView`. `layout()`/`viewDidMoveToWindow()` 양쪽에서
    /// 시도하는 이유 — 어느 한쪽만으로는 `NSSplitView`가 아직 최종 `bounds`를 갖추기 전에
    /// 불려 `didApply`가 잘못된(너무 작은) 폭으로 소진되는 경우가 있었다(2026-08-18 실측).
    final class ProbeView: NSView {
        var ratio: CGFloat = 0.2
        var minWidth: CGFloat = 180
        var maxWidth: CGFloat = 400
        private var didApply = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyIfNeeded()
        }

        override func layout() {
            super.layout()
            applyIfNeeded()
        }

        private func applyIfNeeded() {
            guard !didApply else { return }
            guard let splitView = enclosingSplitView(), splitView.bounds.width > minWidth + maxWidth else {
                // `NSSplitView`가 아직 실제 창 크기로 자리 잡기 전(과도 상태)이면 넘어간다 —
                // 여기서 너무 이르게 적용하면 작은 과도 폭 기준 위치를 얼려버린다.
                return
            }
            didApply = true
            let target = min(maxWidth, max(minWidth, splitView.bounds.width * ratio))
            splitView.setPosition(target, ofDividerAt: 0)
        }

        private func enclosingSplitView() -> NSSplitView? {
            var view: NSView? = superview
            while let candidate = view {
                if let splitView = candidate as? NSSplitView { return splitView }
                view = candidate.superview
            }
            return nil
        }
    }
}
