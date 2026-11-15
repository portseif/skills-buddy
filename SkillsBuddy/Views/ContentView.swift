//
//  ContentView.swift
//  SkillsBuddy
//
//  The shell: a title bar with the window's actions, filters on the shell
//  color, the skill table on the content surface, and the selected skill in a
//  trailing inspector.
//

import BlissUI
import SwiftUI

struct ContentView: View {
    /// How wide the sidebar's grip lets it get.
    static let sidebarWidthRange: ClosedRange<Double> = 180...360

    @State private var filter: LibraryFilter = .all
    @State private var selectedSkillID: Skill.ID?
    @State private var checkedSkillIDs: Set<Skill.ID> = []
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool
    // The window's layout, kept across launches (the frame itself is kept by
    // `.persistsWindowFrame`, the inspector's width by `InspectorSplit`).
    @AppStorage("skillsBuddy.sidebarWidth") private var sidebarWidth: Double = 232
    @AppStorage("skillsBuddy.isSidebarCollapsed") private var isSidebarCollapsed = false
    @AppStorage("skillsBuddy.isInspectorPresented") private var isInspectorPresented = true
    @State private var isInstallSheetPresented = false
    /// Settings mode and its page. Owned by the app, above `.blissTheme()`: a
    /// theme change rebuilds this view, which would leave settings mid-pick.
    @Binding var isSettingsPresented: Bool
    @Binding var settingsPage: SettingsPage
    let settingsScroll: SettingsScrollMemory
    @State private var filterHistory = FilterHistory()
    /// Set while Back or Forward changes the filter, so it isn't recorded as a new visit.
    @State private var isMovingThroughHistory = false
    /// Back left settings; Forward returns to them until another filter is picked.
    @State private var canReturnToSettings = false
    /// Which of the two modes have been built. Each stays built, hidden, while
    /// the other shows, so toggling settings swaps them instead of rebuilding
    /// the skill table (seconds for a long list). A theme or font change
    /// rebuilds the window with only the mode on screen, which keeps those
    /// edits quick; the other is built the next time it's shown.
    @State private var hasBuiltSkills = false
    @State private var hasBuiltSettings = false

    private var currentSidebarWidth: CGFloat {
        isSidebarCollapsed ? Sizing.sidebarCollapsedWidth : CGFloat(sidebarWidth)
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            HStack(spacing: 0) {
                sidebar
                    .frame(width: currentSidebarWidth)
                    .sidebarResizeHandle(width: $sidebarWidth, in: Self.sidebarWidthRange, isEnabled: !isSidebarCollapsed)
                    // Above the content panel, so the half of the grip over it still catches the drag.
                    .zIndex(1)
                contentPanel
            }
        }
        // Up into the hidden title bar, so the title bar's row is the traffic
        // lights' row: `.blissWindowChrome()` centers them in `Sizing.titleBarHeight`.
        .ignoresSafeArea(.container, edges: .top)
        // The shell's fill: opaque, or a tint over the blurred desktop with
        // Translucent sidebar on.
        .background(Color.shellBackground)
        // The sheet sets its own width; the card hugs it.
        .appSheet(isPresented: $isInstallSheetPresented, contentSized: true) {
            InstallSkillSheet(isPresented: $isInstallSheetPresented)
        }
        .onChange(of: filter) { previousFilter, _ in
            if isMovingThroughHistory {
                isMovingThroughHistory = false
            } else {
                filterHistory.recordVisit(leaving: previousFilter)
            }
            // A batch applies to what you checked in this list, not a list you left.
            checkedSkillIDs.removeAll()
            if !isMovingThroughHistory { canReturnToSettings = false }
        }
        .onChange(of: isSettingsPresented, initial: true) { _, showsSettings in
            if showsSettings { hasBuiltSettings = true } else { hasBuiltSkills = true }
        }
        // No leading inset: sheets center on the whole window, sidebar included.
        .appSheetHost()
    }

    // MARK: - Sidebar

    /// The skill filters, or in settings mode the settings categories.
    private var sidebar: some View {
        ZStack {
            if hasBuiltSkills || !isSettingsPresented {
                LibrarySidebar(filter: $filter, isCollapsed: isSidebarCollapsed)
                    .concealed(isSettingsPresented)
            }
            if hasBuiltSettings || isSettingsPresented {
                SettingsSidebar(page: $settingsPage, isCollapsed: isSidebarCollapsed)
                    .concealed(!isSettingsPresented)
            }
        }
    }

    // MARK: - Title bar

    private var titleBar: some View {
        WindowTitleBar {
            SidebarToggleButton(isCollapsed: $isSidebarCollapsed)

            Button(action: goBack) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(ToolbarIconButtonStyle())
            // In settings, Back leaves them.
            .disabled(!isSettingsPresented && !filterHistory.canGoBack)
            .keyboardShortcut("[", modifiers: .command)
            .compactTooltip("Back (⌘[)", position: .below)
            .accessibilityLabel(Text("Back"))

            Button(action: goForward) {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(ToolbarIconButtonStyle())
            .disabled(isSettingsPresented || !(canReturnToSettings || filterHistory.canGoForward))
            .keyboardShortcut("]", modifiers: .command)
            .compactTooltip("Forward (⌘])", position: .below)
            .accessibilityLabel(Text("Forward"))
        } trailing: {
            // Search filters the skill table, which settings mode replaces.
            if !isSettingsPresented {
                TextField("Search skills", text: $searchText)
                    .textFieldStyle(ToolbarSearchTextFieldStyle())
                    .frame(width: 200)
                    .focused($isSearchFocused)
                    .compactTooltip("Search skills (⌘F)", position: .below)
                    // ⌘F jumps to the field, as Find does elsewhere.
                    .background {
                        Button("Find") { isSearchFocused = true }
                            .keyboardShortcut("f", modifiers: .command)
                            .opacity(0)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
            }

            LibraryUpdateButtons()

            Button {
                isInstallSheetPresented = true
            } label: {
                Label("Install", systemImage: "plus")
                    .lineLimit(1)
            }
            .buttonStyle(OutlineButtonStyle(compact: true))
            .fixedSize()
            .keyboardShortcut("n", modifiers: .command)
            .compactTooltip("Install a skill (⌘N)", position: .below)

            // The inspector belongs to the skill table; settings have none.
            if !isSettingsPresented {
                Button {
                    withAnimation(Animations.pane) { isInspectorPresented.toggle() }
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .buttonStyle(ToolbarIconButtonStyle(isActive: isInspectorPresented))
                .keyboardShortcut("i", modifiers: [.option, .command])
                .compactTooltip(isInspectorPresented ? "Hide inspector (⌥⌘I)" : "Show inspector (⌥⌘I)", position: .below)
                .accessibilityLabel(Text("Toggle Inspector"))
            }
        }
        // In line with the content panel's rounded leading edge rather than
        // centered on the window; past the sidebar toggle when the sidebar is
        // collapsed. Clicks fall through, so the empty bar still drags the window.
        .overlay(alignment: .leading) {
            HStack(spacing: Spacing.xs) {
                Image("AppMark")
                    .resizable()
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
                Text("Skills Buddy")
                    .font(Typography.bodySmallSemibold)
                    .lineLimit(1)
            }
            .padding(.leading, max(currentSidebarWidth, Self.titleMinimumLeading))
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
    }

    /// Clears the traffic lights and the sidebar toggle, Back and Forward after them.
    private static let titleMinimumLeading: CGFloat = 184

    private func goBack() {
        if isSettingsPresented {
            isSettingsPresented = false
            canReturnToSettings = true
            return
        }
        guard let target = filterHistory.goBack(from: filter) else { return }
        isMovingThroughHistory = true
        filter = target
    }

    private func goForward() {
        if canReturnToSettings {
            canReturnToSettings = false
            isSettingsPresented = true
            return
        }
        guard let target = filterHistory.goForward(from: filter) else { return }
        isMovingThroughHistory = true
        filter = target
    }

    // MARK: - Content

    private var contentPanel: some View {
        ZStack {
            if hasBuiltSkills || !isSettingsPresented {
                skillsPanel
                    .concealed(isSettingsPresented)
            }
            if hasBuiltSettings || isSettingsPresented {
                SettingsContent(page: settingsPage, scrollMemory: settingsScroll)
                    .concealed(!isSettingsPresented)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.contentAreaBackground)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: Sizing.radiusLarge, style: .continuous))
        .overlay {
            UnevenRoundedRectangle(topLeadingRadius: Sizing.radiusLarge, style: .continuous)
                .strokeBorder(Color.menuBorder, lineWidth: 1)
        }
    }

    /// The skill table with the selected skill in the inspector.
    private var skillsPanel: some View {
        InspectorSplit(isPresented: $isInspectorPresented, widthStorageKey: "skillsBuddy.inspectorWidth") {
            SkillListView(
                filter: filter,
                searchText: searchText,
                selectedSkillID: $selectedSkillID,
                checkedSkillIDs: $checkedSkillIDs,
                onInstall: { isInstallSheetPresented = true }
            )
        } inspector: {
            SelectedSkillInspector(selectedSkillID: selectedSkillID)
        }
    }
}

/// Check for Updates and Update All. Their own view: they read the library's
/// busy state and pending updates, which change through every operation,
/// without re-running the window's body.
private struct LibraryUpdateButtons: View {
    @Environment(SkillLibrary.self) private var library

    var body: some View {
        Button {
            Task { await library.checkForUpdates() }
        } label: {
            if library.isCheckingForUpdates {
                ThinkingSpinner(size: 13, lineWidth: 1.5)
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .buttonStyle(ToolbarIconButtonStyle())
        .disabled(library.isBusy)
        .compactTooltip("Check for updates (⌘R)", position: .below)
        .accessibilityLabel(Text("Check for Updates"))

        Button {
            Task { await library.updateAll() }
        } label: {
            Label(updateAllTitle, systemImage: "arrow.down.circle")
                .lineLimit(1)
        }
        .buttonStyle(PrimaryButtonStyle(compact: true))
        .fixedSize()
        .disabled(library.skillsWithUpdates.isEmpty || library.isBusy)
        .keyboardShortcut("u", modifiers: [.shift, .command])
        .compactTooltip("Update every skill with an update (⇧⌘U)", position: .below)
    }

    private var updateAllTitle: LocalizedStringKey {
        let count = library.skillsWithUpdates.count
        return count > 0 ? "Update All (\(count))" : "Update All"
    }
}

/// The inspector for the selected skill. It looks the skill up itself, so a
/// rescan redraws the inspector and not the window around it.
private struct SelectedSkillInspector: View {
    @Environment(SkillLibrary.self) private var library
    let selectedSkillID: Skill.ID?

    var body: some View {
        if let skill = library.skill(withID: selectedSkillID) {
            SkillInspector(skill: skill)
                .id(skill.id)
        } else {
            SkillInspectorPlaceholder()
        }
    }
}

private extension View {
    /// Kept in the window but out of sight, out of reach of the pointer and
    /// out of VoiceOver while the other mode shows. Not `.disabled`: flipping
    /// that re-renders every row of the table, most of a toggle's cost.
    func concealed(_ isConcealed: Bool) -> some View {
        opacity(isConcealed ? 0 : 1)
            .allowsHitTesting(!isConcealed)
            .accessibilityHidden(isConcealed)
    }
}

#if DEBUG
#Preview(traits: .fixedLayout(width: 1240, height: 760)) {
    ContentView(isSettingsPresented: .constant(false), settingsPage: .constant(.appearance), settingsScroll: SettingsScrollMemory())
        .globalToast()
        .environment(SkillLibrary.preview)
        .blissTheme()
}
#endif
