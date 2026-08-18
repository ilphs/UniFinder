import SwiftUI

/// 상태바 (UI설계 §5). 높이 24pt, `항목 N개 | M개 선택됨 (크기)`.
/// 크기 합계는 **파일만** 합산하고, 폴더가 섞이면 `+ 폴더 N개`로 덧붙인다(설계서 §3.2).
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
