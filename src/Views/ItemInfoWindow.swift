import AppKit
import SwiftUI

/// Get Info 창 (후속 T5·T6·T7 / UI설계 §7.6).
///
/// **시트가 아니라 독립 창인 이유**: 정보를 띄운 채 목록을 계속 탐색할 수 있어야 하고,
/// 대상별로 창이 하나씩 열려 비교가 가능해야 한다. 같은 URL로 다시 열면 `WindowGroup(for:)`이
/// 기존 창을 앞으로 가져온다(`InfoTarget`이 URL 기반 값이라 성립한다 — D7).
struct ItemInfoWindow: View {

    let target: InfoTarget

    @State private var model: ItemInfoModel

    init(target: InfoTarget) {
        self.target = target
        _model = State(initialValue: ItemInfoModel(target: target))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.state {
            case .loading:
                centered { ProgressView().controlSize(.small) }
            case let .failed(message):
                // 표 대신 한 줄 안내 (UI설계 §7.6).
                centered {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 24))
                            .foregroundStyle(.secondary)
                        Text(message)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
            case .loaded:
                if let attributes = model.attributes {
                    loadedBody(attributes)
                }
            }
        }
        .frame(minWidth: 380, idealWidth: 420, minHeight: 320)
        .onAppear { model.load() }
        // 창을 닫으면 폴더 크기 계산을 **즉시** 멈춘다(§5 성능 요구 — 닫힌 창을 위해 디스크를 갈지 않는다).
        .onDisappear { model.cancel() }
        .navigationTitle("\(target.displayName) Info")
        .alert(
            "Couldn't change the default application",
            isPresented: Binding(
                get: { model.applicationErrorMessage != nil },
                set: { if !$0 { model.applicationErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.applicationErrorMessage = nil }
        } message: {
            Text(model.applicationErrorMessage ?? "")
        }
        // UI설계 §7.8 — 시스템 전역 설정을 바꾸는 조작이라 확인 없이는 절대 실행하지 않는다.
        .alert(
            "Change All",
            isPresented: Binding(
                get: { model.isChangeAllConfirmationPresented },
                set: { if !$0 { model.cancelChangeAll() } }
            )
        ) {
            Button("Cancel", role: .cancel) { model.cancelChangeAll() }
            Button("Change All") { model.confirmChangeAll() }
        } message: {
            Text(model.changeAllConfirmationMessage)
        }
    }

    // MARK: - 본문

    @ViewBuilder
    private func loadedBody(_ attributes: ItemInfoModel.Attributes) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header(attributes)
                Divider()
                generalRows(attributes)

                // 폴더에는 "Open with:"를 띄우지 않는다 — 폴더의 기본 앱 변경은 범위 밖이다(UI설계 §7.6).
                if !attributes.isDirectory, !model.applications.isEmpty {
                    Divider()
                    openWithSection
                }

                Divider()
                detailRows(attributes)
            }
            .padding(16)
            // 모든 값은 선택·복사 가능해야 한다(UI설계 §7.6).
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func header(_ attributes: ItemInfoModel.Attributes) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(nsImage: Self.headerIcon(for: target.url))
                .resizable()
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(attributes.name)
                    .font(.system(size: 15, weight: .semibold))
                Text(headerSubtitle(attributes))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func headerSubtitle(_ attributes: ItemInfoModel.Attributes) -> String {
        var parts = [attributes.kind]
        if let size = attributes.byteSize {
            parts.append(Formatters.displayByteCount(size))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func generalRows(_ attributes: ItemInfoModel.Attributes) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Kind", attributes.kind)
            sizeRow(attributes)
            if let allocated = attributes.allocatedSize {
                row("Size on disk", Formatters.displayByteCount(allocated))
            }
            row("Where", attributes.location)
            if let destination = attributes.symbolicLinkDestination {
                // D3 — 링크 자체를 보여주되 해석된 경로를 병기한다.
                row("Original", destination)
            }
            row("Created", Formatters.displayDate(attributes.createdAt))
            row("Modified", Formatters.displayDate(attributes.modifiedAt))
            row("Last opened", Formatters.displayDate(attributes.accessedAt))
        }
    }

    @ViewBuilder
    private func sizeRow(_ attributes: ItemInfoModel.Attributes) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Size:")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: Self.labelWidth, alignment: .trailing)
            if case .calculating = model.folderSize {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
            }
            Text(Self.sizeText(attributes: attributes, folderSize: model.folderSize))
                .font(.system(size: 11))
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func detailRows(_ attributes: ItemInfoModel.Attributes) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let identifier = attributes.typeIdentifier {
                row("Type ID", identifier)
            }
            row("Owner", [attributes.owner, attributes.group.map { "(\($0))" }].compactMap { $0 }.joined(separator: " "))
            row("Permissions", attributes.permissions ?? "--")
            row("Locked", attributes.isLocked ? "Yes" : "No")
            if !attributes.tags.isEmpty {
                row("Tags", attributes.tags.joined(separator: ", "))
            }
        }
    }

    private var openWithSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Open with:")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: Self.labelWidth, alignment: .trailing)
                Picker(
                    "",
                    selection: Binding(
                        get: { model.selectedApplication },
                        set: { if let url = $0 { model.selectApplication(url) } }
                    )
                ) {
                    ForEach(model.applications, id: \.url) { application in
                        Text(application.isDefault ? "\(application.name) (default)" : application.name)
                            .tag(Optional(application.url))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
            }
            HStack {
                Spacer().frame(width: Self.labelWidth + 8)
                Button("Change All…") { model.requestChangeAll() }
                    .controlSize(.small)
                    .disabled(model.selectedApplication == nil)
                Spacer(minLength: 0)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(label):")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: Self.labelWidth, alignment: .trailing)
            Text(value.isEmpty ? "--" : value)
                .font(.system(size: 11))
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                content()
                Spacer()
            }
            Spacer()
        }
    }

    static let labelWidth: CGFloat = 92

    /// 헤더 아이콘 48pt. **`IconProvider`를 쓰지 않는다** — 그쪽은 목록 셀용 16pt 캐시라
    /// 여기서 크기를 바꾸면 목록 아이콘까지 48pt로 커진다(같은 캐시 객체를 공유하므로).
    ///
    /// `IconProvider`의 `.copy()` 규약은 그대로 따른다: `NSWorkspace.icon(forFile:)`은 공유
    /// 인스턴스를 돌려줄 수 있어 그것을 직접 `size` 변형하면 AppKit의 다른 소비자에게도 새어 나간다.
    static func headerIcon(for url: URL) -> NSImage {
        let source = NSWorkspace.shared.icon(forFile: url.path)
        let image = (source.copy() as? NSImage) ?? source
        image.size = NSSize(width: 48, height: 48)
        return image
    }

    /// `Size:` 행의 문구 — 뷰 밖에서 단언할 수 있도록 순수 함수로 뽑았다.
    ///
    /// 폴더는 계산 상태에 따라 문구가 달라진다(UI설계 §7.6):
    /// `Calculating…` → `1.2 GB (3,481 items)` → 필요하면 `(some items couldn't be read)`.
    static func sizeText(attributes: ItemInfoModel.Attributes, folderSize: ItemInfoModel.FolderSize) -> String {
        switch folderSize {
        case .notApplicable:
            guard let size = attributes.byteSize else { return "--" }
            return "\(Formatters.displayByteCount(size)) (\(byteCountText(size)) bytes)"

        case let .calculating(bytes, itemCount):
            guard bytes > 0 || itemCount > 0 else { return "Calculating…" }
            return "Calculating… \(Formatters.displayByteCount(bytes)) (\(itemsText(itemCount)))"

        case let .done(bytes, itemCount, isIncomplete):
            var text = "\(Formatters.displayByteCount(bytes)) (\(itemsText(itemCount)))"
            if isIncomplete { text += " (some items couldn't be read)" }
            return text

        case .failed:
            return "--"
        }
    }

    static func itemsText(_ count: Int) -> String {
        "\(byteCountText(Int64(count))) \(count == 1 ? "item" : "items")"
    }

    /// 천 단위 구분 기호가 붙은 정수 표기.
    static func byteCountText(_ value: Int64) -> String {
        Self.integerFormatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private static let integerFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
}
