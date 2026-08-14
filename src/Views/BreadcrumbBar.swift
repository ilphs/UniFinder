import AppKit
import SwiftUI

/// 경로 세그먼트 1개.
struct PathSegment: Identifiable, Hashable {
    let id: Int
    let title: String
    let url: URL
    let isHomeRoot: Bool
}

/// 툴바 주소창 (UI설계 §2.2).
///
/// 평상시 breadcrumb 버튼 나열, 빈 영역 클릭/`Cmd+L` 시 텍스트 필드로 전환.
/// 공간이 부족하면 앞쪽 세그먼트부터 `…` 메뉴로 접는다.
struct BreadcrumbBar: View {

    let url: URL
    @Binding var isEditing: Bool
    let shakeTrigger: Int
    var onNavigate: (URL) -> Void
    var onSubmit: (String) -> Void

    @State private var editingText: String = ""
    @FocusState private var isFieldFocused: Bool

    private var segments: [PathSegment] {
        Self.segments(for: url)
    }

    var body: some View {
        Group {
            if isEditing {
                editor
            } else {
                breadcrumb
            }
        }
        .frame(height: 24)
        .onChange(of: isEditing) { _, newValue in
            if newValue {
                editingText = url.path
                isFieldFocused = true
            }
        }
    }

    // MARK: - 편집 모드

    private var editor: some View {
        TextField("경로 입력", text: $editingText)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12))
            .focused($isFieldFocused)
            .onSubmit { onSubmit(editingText) }
            .onExitCommand { isEditing = false }
            .modifier(ShakeEffect(animatableData: CGFloat(shakeTrigger)))
            .animation(.default, value: shakeTrigger)
            .onChange(of: isFieldFocused) { _, focused in
                if !focused { isEditing = false }
            }
    }

    // MARK: - breadcrumb 모드

    private var breadcrumb: some View {
        GeometryReader { proxy in
            let layout = Self.fold(segments: segments, availableWidth: proxy.size.width)
            HStack(spacing: 0) {
                if !layout.folded.isEmpty {
                    Menu {
                        ForEach(layout.folded) { segment in
                            Button(segment.title) { onNavigate(segment.url) }
                        }
                    } label: {
                        Text("…")
                            .font(.system(size: 12))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    chevron
                }

                ForEach(Array(layout.visible.enumerated()), id: \.element.id) { index, segment in
                    Button {
                        onNavigate(segment.url)
                    } label: {
                        HStack(spacing: 3) {
                            if segment.isHomeRoot {
                                Image(systemName: "house")
                                    .font(.system(size: 11))
                            }
                            Text(segment.title)
                                .font(.system(size: 12))
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(index == layout.visible.count - 1 ? Color.primary : Color.secondary)

                    if index < layout.visible.count - 1 {
                        chevron
                    }
                }

                // 빈 영역 클릭 → 편집 모드 (UI설계 §2.2)
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { isEditing = true }
            }
            .padding(.horizontal, 6)
            .frame(width: proxy.size.width, height: 24, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 3)
    }

    // MARK: - 세그먼트 계산

    /// 홈 하위 경로는 홈 아이콘부터, 그 외는 루트(`/`)부터 나열한다 (UI설계 §2.2).
    static func segments(for url: URL) -> [PathSegment] {
        let normalized = NavigationModel.normalize(url)
        let home = NavigationModel.normalize(FileManager.default.homeDirectoryForCurrentUser)

        let path = normalized.path
        let homePath = home.path

        if path == homePath || path.hasPrefix(homePath + "/") {
            let relative = path.dropFirst(homePath.count).split(separator: "/").map(String.init)
            var result: [PathSegment] = [
                PathSegment(id: 0, title: home.lastPathComponent, url: home, isHomeRoot: true)
            ]
            var cursor = home
            for (index, component) in relative.enumerated() {
                cursor = cursor.appendingPathComponent(component)
                result.append(
                    PathSegment(id: index + 1, title: component, url: NavigationModel.normalize(cursor), isHomeRoot: false)
                )
            }
            return result
        }

        let components = path.split(separator: "/").map(String.init)
        var result: [PathSegment] = [
            PathSegment(id: 0, title: volumeName(), url: URL(fileURLWithPath: "/"), isHomeRoot: false)
        ]
        var cursor = URL(fileURLWithPath: "/")
        for (index, component) in components.enumerated() {
            cursor = cursor.appendingPathComponent(component)
            result.append(
                PathSegment(id: index + 1, title: component, url: NavigationModel.normalize(cursor), isHomeRoot: false)
            )
        }
        return result
    }

    private static func volumeName() -> String {
        let root = URL(fileURLWithPath: "/")
        if let values = try? root.resourceValues(forKeys: [.volumeNameKey]), let name = values.volumeName {
            return name
        }
        return "/"
    }

    /// 공간이 부족하면 앞쪽 세그먼트부터 접는다. 현재 폴더 세그먼트는 항상 표시.
    static func fold(segments: [PathSegment], availableWidth: CGFloat) -> (folded: [PathSegment], visible: [PathSegment]) {
        guard segments.count > 1 else { return ([], segments) }

        let font = NSFont.systemFont(ofSize: 12)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let widths = segments.map { segment -> CGFloat in
            let textWidth = (segment.title as NSString).size(withAttributes: attributes).width
            // 아이콘 + 구분자(chevron) 여백 포함
            return ceil(textWidth) + (segment.isHomeRoot ? 20 : 0) + 16
        }

        let budget = max(availableWidth - 40, 60) // 여백 + "…" 메뉴 자리
        var total = widths.reduce(0, +)
        var firstVisible = 0

        while total > budget && firstVisible < segments.count - 1 {
            total -= widths[firstVisible]
            firstVisible += 1
        }

        return (Array(segments[..<firstVisible]), Array(segments[firstVisible...]))
    }
}

/// 잘못된 경로 입력 시 셰이크 (UI설계 §2.2 / §8)
struct ShakeEffect: GeometryEffect {
    var amount: CGFloat = 6
    var shakesPerUnit: CGFloat = 3
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        let translation = amount * sin(animatableData * .pi * shakesPerUnit)
        return ProjectionTransform(CGAffineTransform(translationX: translation, y: 0))
    }
}
