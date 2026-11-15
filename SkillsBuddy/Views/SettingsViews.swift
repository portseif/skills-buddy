//
//  SettingsViews.swift
//  SkillsBuddy
//
//  Settings as a mode of the main window: the categories take the sidebar's
//  place and the selected one fills the content panel. ⌘, (Skills Buddy ›
//  Settings…) opens it; ⌘, again or the Back arrow leaves it.
//

import BlissUI
import SwiftUI

/// A settings category: one sidebar row, one page.
enum SettingsPage: String, CaseIterable, Identifiable, Hashable {
    case appearance

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .appearance: "Appearance"
        }
    }

    var subtitle: LocalizedStringKey {
        switch self {
        case .appearance: "Mode, theme, colors, fonts and motion."
        }
    }

    var icon: String {
        switch self {
        case .appearance: "paintpalette"
        }
    }
}

/// The categories, in the sidebar's place.
struct SettingsSidebar: View {
    @Binding var page: SettingsPage
    var isCollapsed = false

    var body: some View {
        Sidebar(selection: $page, isCollapsed: isCollapsed) {
            VStack(alignment: .leading, spacing: 0) {
                SidebarSection("Settings") {
                    ForEach(SettingsPage.allCases) { page in
                        SidebarRow(page.title, icon: page.icon, value: page)
                    }
                }
            }
            // Matches `LibrarySidebar`'s inset, so switching keeps the rows in place.
            .padding(.horizontal, isCollapsed ? 0 : Spacing.sm)
        }
        .padding(.top, -Spacing.xs)
    }
}

/// Where the settings page is scrolled to, kept by the app: a theme or font
/// change rebuilds the window, and the page should come back where it was.
/// A plain class, not state: it's written on every scroll frame, and an
/// observed value there re-rendered the whole window (the hidden skill table
/// included) on each one.
final class SettingsScrollMemory {
    var offset: CGFloat = 0
}

/// The selected category's settings, in the content panel.
struct SettingsContent: View {
    let page: SettingsPage
    let scrollMemory: SettingsScrollMemory
    /// Starts where the page was before the rebuild.
    @State private var scrollPosition: ScrollPosition

    init(page: SettingsPage, scrollMemory: SettingsScrollMemory) {
        self.page = page
        self.scrollMemory = scrollMemory
        self._scrollPosition = State(initialValue: ScrollPosition(y: scrollMemory.offset))
    }

    var body: some View {
        ScrollViewWithThinIndicator {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(page.title)
                        .font(Typography.displaySmall)
                    Text(page.subtitle)
                        .font(Typography.captionSmall)
                        .foregroundStyle(Color.textSecondary)
                }
                AppearanceSettings(dockIcons: DockIconOption.skillsBuddyOptions)
                    // The page sets the insets; drop the form's window padding.
                    .environment(\.settingsFormPlain, true)
            }
            // A readable column, centered in the content panel like a settings page.
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.lg)
            .padding(.bottom, Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { _, offset in
            scrollMemory.offset = offset
        }
    }
}

#if DEBUG
#Preview("Sidebar", traits: .fixedLayout(width: 240, height: 320)) {
    @Previewable @State var page = SettingsPage.appearance
    SettingsSidebar(page: $page)
        .background(Color.appShell)
        .blissTheme()
}

#Preview("Appearance", traits: .fixedLayout(width: 760, height: 520)) {
    SettingsContent(page: .appearance, scrollMemory: SettingsScrollMemory())
        .background(Color.contentAreaBackground)
        .blissTheme()
}
#endif
