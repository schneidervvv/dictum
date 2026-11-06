import SwiftUI

struct Sidebar: View {
    @Binding var page: DictumPage
    @State private var showsSettings: Bool
    @State private var returnPage = SettingsReturnPage()

    init(page: Binding<DictumPage>) {
        _page = page
        _showsSettings = State(initialValue: page.wrappedValue.isSettings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsSettings {
                backRow
                pageGroup(settings: true).padding(.top, 6)
            } else {
                pageGroup(settings: false)
            }
            Spacer(minLength: 12)
            if !showsSettings { settingsButton }
            SidebarStatusRow { page = .speech }
        }
        .padding(.horizontal, 10).padding(.top, 52).padding(.bottom, 12)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .trailing) { DictumTheme.separator.frame(width: 0.5) }
        .background { hiddenShortcuts(settings: !showsSettings) }
        .onChange(of: page) { previous, destination in
            returnPage.pageChanged(from: previous, to: destination)
            showsSettings = destination.isSettings
        }
    }

    private var backRow: some View {
        Button {
            showsSettings = false
            if page.isSettings { page = returnPage.page }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold)).frame(width: 16)
                    .foregroundStyle(DictumTheme.textSecondary)
                    .accessibilityHidden(true)
                Text("Settings", tableName: "DictumShell").font(DictumTheme.Typography.section)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(height: 30).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Back", tableName: "DictumShell"))
        .accessibilityIdentifier("dictum.sidebar.back")
    }

    private var settingsButton: some View {
        Button {
            showsSettings = true
            page = .general
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .regular)).frame(width: 16)
                    .foregroundStyle(DictumTheme.textSecondary)
                    .accessibilityHidden(true)
                Text("Settings", tableName: "DictumShell").font(DictumTheme.Typography.body)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(height: 30).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("dictum.sidebar.settings")
    }

    private func pageGroup(settings: Bool) -> some View {
        VStack(spacing: 1) {
            ForEach(DictumPage.allCases.filter { $0.isSettings == settings }) { destination in
                Button { page = destination } label: {
                    HStack(spacing: 9) {
                        Image(systemName: destination.symbol)
                            .font(.system(size: 13, weight: .regular)).frame(width: 16)
                            .foregroundStyle(page == destination ? DictumTheme.accent : DictumTheme.textSecondary)
                            .accessibilityHidden(true)
                        Text(destination.title).font(DictumTheme.Typography.body)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).frame(height: 30)
                    .background(page == destination ? DictumTheme.selected : .clear, in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("dictum.page.\(destination.rawValue)")
                .accessibilityAddTraits(page == destination ? .isSelected : [])
                .keyboardShortcut(destination.shortcut, modifiers: .command)
            }
        }
    }

    /// 侧栏只列出当前模式的页面，另一组页面的 ⌘ 数字快捷键由这些看不见的按钮继续提供。
    private func hiddenShortcuts(settings: Bool) -> some View {
        ZStack {
            ForEach(DictumPage.allCases.filter { $0.isSettings == settings }) { destination in
                Button { page = destination } label: { EmptyView() }
                    .keyboardShortcut(destination.shortcut, modifiers: .command)
            }
        }
        .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
    }
}
