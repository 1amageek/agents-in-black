import SwiftUI

struct TerminalTabsView: View {
    @Bindable var manager: TerminalManager
    var highlightedContextKey: String?

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            if let tab = manager.selectedTab {
                TerminalTabDetailView(tab: tab, showsHeader: false)
                    .id(tab.id)
            } else {
                ContentUnavailableView(
                    "No Terminal",
                    systemImage: "terminal",
                    description: Text("Press ⌘T or click + to open a terminal.")
                )
            }
        }
        .keyboardShortcut("t", modifiers: .command, action: newTabFromSelected)
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(manager.tabs) { tab in
                        tabItem(tab)
                    }
                }
            }
            Divider().frame(height: 14)
            newTabButton
        }
        .frame(height: 24)
        .background(.bar)
    }

    private func tabItem(_ tab: TerminalTabModel) -> some View {
        let isSelected = manager.selectedTabID == tab.id
        let isHighlighted = highlightedContextKey != nil && tab.contextKey == highlightedContextKey

        return HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isHighlighted ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))

            Text(tab.repoName)
                .font(.system(size: 11))
                .lineLimit(1)

            Button {
                manager.closeTab(tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isSelected ? 1 : 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(isSelected ? AnyShapeStyle(.selection.opacity(0.3)) : AnyShapeStyle(.clear))
        .contentShape(Rectangle())
        .onTapGesture {
            manager.selectTab(tab.id)
        }
    }

    private var newTabButton: some View {
        Button {
            newTabFromSelected()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("New Terminal Tab (⌘T)")
    }

    // MARK: - Actions

    private func newTabFromSelected() {
        manager.newTabFromSelected()
    }
}

// MARK: - Keyboard Shortcut Helper

private extension View {
    func keyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers, action: @escaping () -> Void) -> some View {
        background(
            Button("", action: action)
                .keyboardShortcut(key, modifiers: modifiers)
                .hidden()
        )
    }
}
