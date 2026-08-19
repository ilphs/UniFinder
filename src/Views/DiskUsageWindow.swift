import SwiftUI

/// 디스크 용량 창 (후속 T8 / UI설계 §7.7).
///
/// **앱 전체에 하나뿐인 창**이다(`Window(id:)` 단일 씬 — `UniFinderApp` 참조).
/// 볼륨 용량은 창별 상태가 아니라 머신의 사실이라 여러 벌 떠 있을 이유가 없다.
struct DiskUsageWindow: View {

    @State private var model = DiskUsageModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if model.volumes.isEmpty {
                        Text("No volumes found.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    } else {
                        ForEach(model.volumes) { volume in
                            volumeRow(volume)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack {
                Text(Self.updatedText(model.updatedAt))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                // D9 — 자동 갱신을 하지 않는 대신 수동 갱신 수단을 항상 노출한다.
                //
                // **단축키는 달지 않는다**(reviewer minor #8): ⌘R을 여기서도 잡으면 메뉴바의
                // `View > Refresh`와 소유자가 둘이 되어, 이 창이 key일 때 어느 쪽이 반응하는지가
                // 우연에 좌우된다. 대신 아래에서 이 창의 새로고침 동작을 씬 값으로 게시해
                // 메뉴바의 ⌘R이 **이 창을** 새로고침하게 한다(소유자는 하나, 대상은 활성 씬).
                Button("Refresh") { model.refresh() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(minWidth: 420, minHeight: 280)
        // ⌘R의 대상 게시 — 이 창이 활성일 때 `View > Refresh`는 볼륨 용량을 다시 읽는다.
        .focusedSceneValue(\.sceneRefresh, SceneRefreshAction(id: "disk-usage") { model.refresh() })
        // 창을 열 때 1회 (D9). 마운트/언마운트 통지는 구독하지 않는다.
        .onAppear { model.refresh() }
    }

    private func volumeRow(_ volume: DiskUsageModel.Volume) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(volume.name)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(volume.url.path)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            // 조회 실패한 볼륨은 **행을 없애지 않는다** — 볼륨이 사라진 것처럼 보이면 안 된다.
            // 막대만 생략하고 값은 `--`로 둔다(UI설계 §7.7).
            if let fraction = volume.usedFraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(volume.isLowOnSpace ? .orange : .accentColor)
            }

            Text(Self.capacityText(volume))
                .font(.system(size: 11))
                .foregroundStyle(volume.isLowOnSpace ? .orange : .secondary)
        }
        .textSelection(.enabled)
    }

    // MARK: - 문구 (뷰 밖에서 단언할 수 있게 순수 함수로 뽑는다)

    static func capacityText(_ volume: DiskUsageModel.Volume) -> String {
        guard let total = volume.totalBytes, let available = volume.availableBytes, let used = volume.usedBytes else {
            return "--"
        }
        return "\(Formatters.displayByteCount(available)) free · "
            + "\(Formatters.displayByteCount(total)) total · "
            + "\(Formatters.displayByteCount(used)) used"
    }

    static func updatedText(_ date: Date?) -> String {
        guard let date else { return "Not updated yet" }
        return "Updated \(Formatters.clockTime(date))"
    }
}
