import Foundation

/// 표시용 포맷터 모음. 목록 셀·상태바에서만 쓰므로 MainActor에 고정한다
/// (`DateFormatter`/`ByteCountFormatter`는 Sendable이 아니다).
@MainActor
enum Formatters {

    /// UI설계 §4.1 — 수정일은 고정 포맷 `yyyy-MM-dd HH:mm` (MVP 단순화)
    static let date: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static let byteCount: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        return formatter
    }()

    static func displayDate(_ date: Date?) -> String {
        guard let date else { return "--" }
        return self.date.string(from: date)
    }

    /// 폴더는 `--` (MVP는 폴더 크기 미계산 — 설계서 §3.2)
    static func displaySize(_ size: Int64?) -> String {
        guard let size else { return "--" }
        return byteCount.string(fromByteCount: size)
    }

    static func displayByteCount(_ bytes: Int64) -> String {
        byteCount.string(fromByteCount: bytes)
    }
}
