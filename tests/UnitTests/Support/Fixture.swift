import Foundation

/// 테스트용 fixture 생성 헬퍼.
/// 테스트계획서 §1 원칙 2 — 결정성: 이름·날짜·크기를 고정해 매번 동일한 결과가 나오게 한다.
enum Fixture {

    /// 모든 fixture가 공유하는 기준 시각. offset(초)으로 파일 간 순서를 고정한다.
    static func fixedDate(offset seconds: TimeInterval = 0) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + seconds)
    }

    @discardableResult
    static func makeFile(
        in directory: URL,
        name: String,
        sizeBytes: Int = 16,
        modified: Date = fixedDate(),
        hidden: Bool = false
    ) throws -> URL {
        let finalName = hidden && !name.hasPrefix(".") ? ".\(name)" : name
        let url = directory.appendingPathComponent(finalName)
        let data = Data(repeating: 0x41, count: sizeBytes)
        try data.write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: modified],
            ofItemAtPath: url.path
        )
        return url
    }

    @discardableResult
    static func makeDirectory(
        in directory: URL,
        name: String,
        modified: Date = fixedDate(),
        hidden: Bool = false
    ) throws -> URL {
        let finalName = hidden && !name.hasPrefix(".") ? ".\(name)" : name
        let url = directory.appendingPathComponent(finalName, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: modified],
            ofItemAtPath: url.path
        )
        return url
    }

    @discardableResult
    static func makeSymlink(
        in directory: URL,
        name: String,
        destination: URL
    ) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: destination)
        return url
    }

    /// 권한 없는 폴더 fixture. teardown(`TempDirectoryTestCase`)에서 권한을 복구하므로
    /// 개별 테스트에서 별도 정리하지 않아도 되지만, 명시적으로 복구하고 싶다면 `restore()`를 호출한다.
    @discardableResult
    static func makeInaccessibleDirectory(
        in directory: URL,
        name: String
    ) throws -> (url: URL, restore: () -> Void) {
        let url = try makeDirectory(in: directory, name: name)
        // 접근 불가 재현을 위해 안의 파일을 하나 만든 뒤 권한을 제거한다(빈 폴더는 rmdir만으로 지워질 수 있어
        // "권한 없음"을 확실히 재현하려면 read/execute 비트를 제거해야 한다).
        try makeFile(in: url, name: "secret.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        let restore: () -> Void = {
            _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return (url, restore)
    }

    /// 255자 파일명(APFS 최대 길이) fixture.
    static func maxLengthName(extensionSuffix: String = ".txt") -> String {
        let suffixLength = extensionSuffix.count
        let baseLength = 255 - suffixLength
        return String(repeating: "a", count: baseLength) + extensionSuffix
    }
}
