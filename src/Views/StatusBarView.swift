import SwiftUI

/// 상태바 (UI설계 §5). 높이 24pt, `항목 N개 | M개 선택됨 (크기)`.
/// 크기 합계는 **파일만** 합산하고, 폴더가 섞이면 `+ 폴더 N개`로 덧붙인다(설계서 §3.2).
///
/// **우측 끝은 현재 볼륨의 여유 공간**이다(2026-08-20). 진행 표시·안내 문구와 자리를 다투는데,
/// 그 둘은 일시적이고 용량은 상시 표시라 **용량이 맨 오른쪽에 고정**된다 — 순서가 뒤바뀌면
/// 조작 중에만 숫자가 옆으로 밀려 눈이 따라가야 한다.
struct StatusBarView: View {

    let model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            Text(summaryText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            // 파일 조작 중 미니 진행 표시 (UI설계 §5). 진행률 시트 본체는 M3.
            if let progress = model.operationProgressText {
                Text(progress)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.trailing, 8)
            }

            if let message = model.transientMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            // 현재 폴더가 있는 볼륨의 여유 공간. 조회 실패·볼륨 미특정이면 **아무것도 그리지 않는다**
            // (`--`는 한 줄 상태바에서 정보를 주지 않는다 — `VolumeCapacityModel.displayText` 주석).
            if let capacity = model.volumeCapacity.displayText {
                Text(capacity)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    // 창이 좁아지면 **왼쪽의 안내 문구가 먼저 잘려야 한다** — 용량은 짧고 상시라
                    // 여기서 줄어들면 표시 자체가 의미를 잃는다.
                    .fixedSize()
                    .padding(.leading, 8)
                    .help("Free space on the volume containing this folder")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(.bar)
    }

    private var summaryText: String {
        let directory = model.directory
        let total = directory.itemCount == 1 ? "1 item" : "\(directory.itemCount) items"

        let selected = directory.selectedItems
        guard !selected.isEmpty else { return total }

        let files = selected.filter { !$0.isDirectory }
        let folderCount = selected.count - files.count
        let byteSum = files.reduce(Int64(0)) { $0 + ($1.size ?? 0) }

        // 폴더는 크기를 계산하지 않으므로(설계서 §3.2) 개수만 따로 덧붙인다.
        let folders = folderCount == 1 ? "1 folder" : "\(folderCount) folders"
        var detail = "\(selected.count) selected"
        if !files.isEmpty && folderCount > 0 {
            detail += " (\(Formatters.displayByteCount(byteSum)) + \(folders))"
        } else if !files.isEmpty {
            detail += " (\(Formatters.displayByteCount(byteSum)))"
        } else {
            detail += " (\(folders))"
        }

        return "\(total) | \(detail)"
    }
}
