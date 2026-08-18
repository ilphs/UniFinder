import SwiftUI

/// 파일 조작 진행률 — **윈도우 콘텐츠 안의 비모달 오버레이** (m3-impl T2/B18, UI설계 §7.4).
///
/// 시트로 만들지 않는 이유가 이 뷰의 존재 이유다: `ConflictSheetPresenter`·실패 알림·숨김 이름
/// 확인이 전부 같은 윈도우에 시트를 단다. 진행률을 조작 전체 기간 동안 시트로 띄우면 충돌 알림이
/// AppKit 시트 큐에 밀려 표시되지 않고, 조작은 오지 않는 응답을 기다리며 멈춘다.
///
/// 비모달 원칙:
/// - 오버레이는 카드 영역만 차지하고 그 밖의 클릭은 목록/트리로 그대로 통과한다
/// - 표시 중에도 탐색·선택·스크롤이 계속 가능하다
/// - 1초 이상 지속되는 작업에만 나타난다(`OperationProgressModel.presentationDelay`)
struct OperationProgressOverlay: View {

    let progress: OperationProgressModel
    let onCancel: () -> Void

    var body: some View {
        if progress.isVisible {
            card
                .padding(.bottom, 12)
                .transition(.opacity)
        }
    }

    private var card: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(progress.isCancelling ? "Cancelling…" : progress.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)

                bar

                HStack(spacing: 6) {
                    // B19 — 항목 수 기준만 표시한다(바이트·속도는 Phase 2).
                    Text(progress.itemCountText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if let name = progress.currentName {
                        Text(name)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .frame(width: 260, alignment: .leading)

            Button("Cancel") { onCancel() }
                .disabled(progress.isCancelling)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor))
        )
        .shadow(radius: 8, y: 2)
    }

    @ViewBuilder
    private var bar: some View {
        if let fraction = progress.fraction {
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
        } else {
            // 총 개수를 아직 모르는 구간(첫 틱 이전) — 불확정 막대.
            ProgressView()
                .progressViewStyle(.linear)
        }
    }
}
