import Foundation

/// 경로 비교의 **단일 기준** (m2-impl T4 / architect B5 — "URL 표기 정합 규칙").
///
/// 같은 파일을 가리키는 URL이라도 만들어진 경로에 따라 표기가 갈린다.
/// - `DirectoryLoader.makeItem`이 만든 폴더 URL은 후행 슬래시가 붙는다 (`/a/b/`)
/// - `NSPasteboard`에서 읽은 URL, `FileManager` 조작 결과 URL은 붙지 않는다 (`/a/b`)
/// - `standardizedFileURL`은 존재하는 경로에 한해 `/private/var` → `/var`로 축약한다
///
/// 그래서 선택 상태·클립보드·cut 표시 비교는 **URL 값 비교 대신 이 키로만** 한다.
/// (`TreeModel.indexKey`도 이 규칙을 그대로 쓴다 — 트리와 목록이 같은 기준을 공유해야
///  트리 조작 후 `node(for:)`가 어긋나지 않는다)
///
/// **대소문자 정규화** (M2 리뷰 blocker 근본 원인): macOS 기본 볼륨(APFS)은 대소문자를
/// **비구분**하므로 `/a/B`와 `/A/b`가 같은 파일이다. 정규화하지 않으면 표기만 다른 두 경로가
/// "다른 항목"으로 오판되어, 덮어쓰기 대상 == 원본인데도 원본을 휴지통으로 보내는
/// 데이터 손실이 발생한다. 그래서 `key`는 **소문자로 정규화**한다.
///
/// 대소문자 **구분** 볼륨에서는 서로 다른 두 항목을 같다고 볼 수 있지만, 이 키의 오판은
/// 항상 "조작 거부 / 표시 중복" 방향(보수적)으로만 작동하고 파괴적 방향으로는 작동하지 않는다.
/// 반대로 정규화를 생략하면 파괴적 방향(원본 삭제)으로 오판이 일어난다.
///
/// 대소문자를 **보존**해야 하는 용도(URL 재구성·표시·대소문자만 바꾸는 rename)는
/// `exactPath(_:)`를 쓴다.
enum PathKey {

    /// 후행 슬래시가 제거되고 **소문자로 정규화된** 표준 경로 문자열 — 동일성 비교 전용.
    static func key(_ url: URL) -> String {
        // 로케일 비의존 케이스 매핑(`lowercased(with:)`가 아님) — 터키어 I 문제를 피한다.
        exactPath(url).lowercased()
    }

    /// 후행 슬래시가 제거된 표준 경로 문자열 (**대소문자 보존**).
    /// URL을 다시 만들거나 사용자에게 보여줄 때는 이 값을 쓴다 — `key`를 쓰면 경로가 소문자로 뭉개진다.
    static func exactPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        return path.isEmpty ? "/" : path
    }

    /// 표기(대소문자 포함)까지 완전히 같은지. "이름이 그대로인가" 판정처럼
    /// 대소문자 차이를 **변화로 인정해야 하는** 곳에서만 쓴다.
    static func isSameExactPath(_ lhs: URL, _ rhs: URL) -> Bool {
        exactPath(lhs) == exactPath(rhs)
    }

    static func key(_ urls: some Sequence<URL>) -> Set<String> {
        Set(urls.map(key))
    }

    /// 두 URL이 같은 항목을 가리키는지 (표기 차이 무시).
    static func isSame(_ lhs: URL, _ rhs: URL) -> Bool {
        key(lhs) == key(rhs)
    }

    /// `url`이 `base` 자신이거나 그 하위 경로인지.
    /// 폴더를 자기 자신·자기 하위로 복사/이동하는 무한 재귀를 막는 데 쓴다 (m2-impl T0).
    static func isSameOrDescendant(_ url: URL, of base: URL) -> Bool {
        let basePath = key(base)
        let path = key(url)
        if path == basePath { return true }
        let prefix = basePath == "/" ? "/" : basePath + "/"
        return path.hasPrefix(prefix)
    }

    /// 상위 폴더. 루트에서는 `nil`.
    ///
    /// URL을 다시 만드는 자리라 `key`(소문자)가 아니라 `exactPath`를 쓴다 —
    /// `key`로 만들면 실제 경로가 소문자로 뭉개져 대소문자 구분 볼륨에서 존재하지 않는 경로가 된다.
    static func parent(of url: URL) -> URL? {
        let normalized = URL(fileURLWithPath: exactPath(url))
        let parent = URL(fileURLWithPath: exactPath(normalized.deletingLastPathComponent()))
        return isSameExactPath(parent, normalized) ? nil : parent
    }

    /// 폴더 표기(후행 슬래시 포함)로 통일한 URL.
    static func directoryURL(_ url: URL) -> URL {
        URL(fileURLWithPath: exactPath(url), isDirectory: true)
    }
}
