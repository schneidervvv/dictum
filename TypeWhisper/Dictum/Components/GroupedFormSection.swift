import SwiftUI

struct GroupedFormSection<Content: View>: View {
    let title: LocalizedStringKey
    var footer: LocalizedStringKey? = nil
    var tableName: String = "DictumShell"
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title, tableName: tableName)
                .font(DictumTheme.Typography.section)
                .frame(height: 19, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.bottom, 8)
            VStack(spacing: 0, content: content)
                .frame(maxWidth: .infinity)
                .background(DictumTheme.card, in: RoundedRectangle(cornerRadius: DictumTheme.Layout.groupRadius))
                .overlay(RoundedRectangle(cornerRadius: DictumTheme.Layout.groupRadius).strokeBorder(DictumTheme.separator, lineWidth: 0.5))
            if let footer {
                Text(footer, tableName: tableName)
                    .font(DictumTheme.Typography.secondary)
                    .foregroundStyle(DictumTheme.textSecondary)
                    .padding(.horizontal, 4)
                    .padding(.top, 7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct GroupedFormRow<Content: View>: View {
    var separated = false
    /// 行左右两侧的内边距；放进已带水平内边距的容器（如折叠栏）时传 0，避免重复缩进。
    var horizontalInset: CGFloat = 14
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 12, content: content)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, horizontalInset)
            .overlay(alignment: .top) {
                if separated { DictumTheme.separator.frame(height: 0.5).padding(.horizontal, horizontalInset) }
            }
    }
}

struct GroupedFormToggle: View {
    let title: LocalizedStringKey
    @Binding var isOn: Bool
    var separated = true
    var tableName: String = "DictumShell"

    var body: some View {
        GroupedFormRow(separated: separated) {
            Text(title, tableName: tableName)
            Spacer()
            Toggle(isOn: $isOn) { Text(title, tableName: tableName) }
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }
    }
}
