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

    /// 디스크 용량 창의 `Updated HH:mm` (후속 T8 / UI설계 §7.7).
    static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// 목록 "크기" 컬럼의 값. **폴더는 언제나 `--`다** — 설계서 §3.2 불변식 1.
    ///
    /// 2026-08-19(후속 T6) 정정: Get Info 창은 폴더 크기를 **비동기로 계산해** 보여주지만,
    /// 그것은 이 컬럼의 값이 아니다. 여기서 폴더 크기를 계산하면 목록 열거가 하위 트리 순회를
    /// 떠안게 되어 §5 성능 목표(10만 항목 < 3s)가 즉시 무너진다.
    static func displaySize(_ size: Int64?) -> String {
        guard let size else { return "--" }
        return byteCount.string(fromByteCount: size)
    }

    static func clockTime(_ date: Date) -> String {
        clock.string(from: date)
    }

    static func displayByteCount(_ bytes: Int64) -> String {
        byteCount.string(fromByteCount: bytes)
    }
}
