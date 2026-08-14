import Foundation

/// 디렉토리 열거 추상화 (architect B3).
///
/// `DirectoryLoader`(actor)가 프로덕션 구현체이고, 테스트에서는 지연/에러를 주입할 수 있는
/// 더블을 꽂아 `DirectoryModel`의 "빠른 연속 이동 시 마지막 요청만 반영" race를 결정적으로
/// 재현한다. 그래서 `DirectoryModel`은 구체 타입이 아니라 이 프로토콜에만 의존한다.
protocol DirectoryListing: Sendable {

    /// - Parameters:
    ///   - url: 열거할 디렉토리
    ///   - showHidden: 숨김 항목 포함 여부
    /// - Returns: **정렬되지 않은** 항목 목록 (정렬은 `DirectoryModel`이 적용 — 설계서 §3.3)
    /// - Throws: `DirectoryError`, 또는 취소 시 `CancellationError`
    func list(at url: URL, showHidden: Bool) async throws -> [FileItem]
}
