//
//  SkillListView.swift
//  SkillsBuddy
//

import BlissUI
import SwiftUI

/// The filtered skills as a sortable table, with the command log below.
/// The window's actions live in the title bar.
struct SkillListView: View {
    @Environment(SkillLibrary.self) private var library
    private let agentLogos = AgentLogoStore.shared
    let filter: LibraryFilter
    let searchText: String
    @Binding var selectedSkillID: Skill.ID?
    /// The checked rows the batch actions apply to.
    @Binding var checkedSkillIDs: Set<Skill.ID>
    let onInstall: () -> Void

    @State private var isConfirmingBatchRemoval = false
    @State private var isConfirmingAgentRemoval = false
    /// The open Find Repositories sheet and the skills it searches for, fixed
    /// when it opens: attaching takes a skill off the Local list, not out of
    /// the sheet.
    @State private var repositorySearch: RepositorySearch?

    /// The agent the list is filtered to; batch actions apply to just that agent.
    private var agentScope: String? {
        if case .agent(let agentName) = filter { return agentName }
        return nil
    }

    var body: some View {
        // Worked out once per render and handed down, not recomputed by every
        // part of the body that needs them.
        let visibleSkills = filteredSkills()
        let checkedSkills = library.skills.filter { checkedSkillIDs.contains($0.id) }
        VStack(alignment: .leading, spacing: 0) {
            SkillListHeader(
                title: filter.title,
                skillCount: visibleSkills.count,
                removableAgentName: agentScope.flatMap { visibleSkills.contains(where: \.isRemovable) ? $0 : nil },
                isConfirmingAgentRemoval: $isConfirmingAgentRemoval,
                // Offered on the Local list, for the skills with no source.
                eligibleForRepositorySearch: filter == .source(.local) ? visibleSkills.filter(RepoFinder.isEligible).map(\.id) : [],
                repositorySearch: $repositorySearch
            )
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.lg)
            .padding(.bottom, Spacing.md)

            if let errorMessage = library.errorMessage {
                Banner(
                    "Something went wrong",
                    message: .verbatim(errorMessage),
                    style: .danger,
                    onDismiss: { library.errorMessage = nil }
                )
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.md)
            }

            ForEach(library.scanWarnings, id: \.self) { warning in
                Banner(.verbatim(warning), style: .warning)
                    .padding(.horizontal, Spacing.xl)
                    .padding(.bottom, Spacing.md)
            }

            if visibleSkills.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // No fade mask: it would fade the pinned header with the rows under it.
                ScrollViewWithThinIndicator(showFadeMask: false) {
                    table(visibleSkills)
                        // Room for the batch bar over the last rows, when there's
                        // no Activity log under the table for it to sit on.
                        .padding(.bottom, checkedSkillIDs.isEmpty || library.hasActivity ? Spacing.lg : 72)
                }
            }

            // Its own view: it reads the log, so a streamed line redraws it
            // and not the table above.
            ActivityDock()
        }
        // At the bottom of the list column, not over the middle of the table.
        .selectionBar(count: checkedSkills.count, onClear: { checkedSkillIDs.removeAll() }) {
            batchActions(for: checkedSkills)
        }
        .appSheet(item: $repositorySearch, contentSized: true) { search in
            FindRepositoriesSheet(
                skillIDs: search.skillIDs,
                isPresented: Binding(get: { repositorySearch != nil }, set: { if !$0 { repositorySearch = nil } })
            )
        }
        .confirmationSheet(
            isPresented: $isConfirmingBatchRemoval,
            title: .verbatim(batchRemovalTitle(for: checkedSkills)),
            message: .verbatimWithCode(removalMessage(agentName: agentScope, count: checkedSkills.count)),
            confirmTitle: "Remove",
            isDestructive: true
        ) {
            // Read before clearing: the checked set is the target.
            let targets = checkedSkills
            let agentName = agentScope
            checkedSkillIDs.removeAll()
            Task { await library.remove(targets, fromAgentNamed: agentName) }
        }
        .confirmationSheet(
            isPresented: $isConfirmingAgentRemoval,
            title: .verbatim("Remove every skill from \(agentScope ?? "")?"),
            message: .verbatimWithCode(removalMessage(agentName: agentScope, count: visibleSkills.filter(\.isRemovable).count)),
            confirmTitle: "Remove All",
            isDestructive: true
        ) {
            guard let agentName = agentScope else { return }
            Task { await library.removeAllSkills(fromAgentNamed: agentName) }
        }
    }

    // MARK: - Batch actions

    @ViewBuilder
    private func batchActions(for targets: [Skill]) -> some View {
        if targets.contains(where: { library.status(of: $0).canUpdate }) {
            SelectionBarButton("Update", systemImage: "arrow.down.circle") {
                Task { await library.update(targets) }
            }
        }
        if targets.contains(where: { skill in skill.disabledEntries.contains { agentScope == nil || $0.agentNames.contains(agentScope!) } }) {
            SelectionBarButton("Enable", systemImage: "play.circle") {
                Task { await library.enable(targets, forAgentNamed: agentScope) }
            }
        }
        if targets.contains(where: { $0.isRemovable && (agentScope.map($0.isInstalled(forAgentNamed:)) ?? !$0.agents.isEmpty) }) {
            SelectionBarButton("Disable", systemImage: "pause.circle") {
                Task { await library.disable(targets, forAgentNamed: agentScope) }
            }
        }
        if targets.contains(where: \.isRemovable) {
            SelectionBarButton("Remove…", systemImage: "trash") {
                isConfirmingBatchRemoval = true
            }
        }
    }

    private func batchRemovalTitle(for checkedSkills: [Skill]) -> String {
        let what = checkedSkills.count == 1 ? checkedSkills[0].displayName : "\(checkedSkills.count) skills"
        return "Remove \(what) from \(agentScope ?? "every agent")?"
    }

    private func removalMessage(agentName: String?, count: Int) -> String {
        var message = "CLI skills go through `skills remove`; other skills and disabled copies go to the Trash. Plugin skills are left alone."
        if let agentName {
            let sharing = library.agentsSharingFolder(with: agentName)
            message += sharing.isEmpty
                ? " Other agents keep their copies."
                : " \(sharing.joined(separator: ", ")) read the same folder as \(agentName), so they lose these skills too."
        }
        return "\(count) skill(s). " + message
    }

    // MARK: - Table

    /// The skills the filter and search leave.
    private func filteredSkills() -> [Skill] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return library.skills.filter { skill in
            guard filter.includes(skill, status: library.status(of: skill)) else { return false }
            guard !query.isEmpty else { return true }
            return skill.displayName.localizedCaseInsensitiveContains(query)
                || skill.summary.localizedCaseInsensitiveContains(query)
                || (skill.repository?.displayName.localizedCaseInsensitiveContains(query) ?? false)
                || skill.agents.contains { $0.displayName.localizedCaseInsensitiveContains(query) }
        }
    }

    private func table(_ visibleSkills: [Skill]) -> some View {
        BlissTable(
            visibleSkills,
            columns: [
                BlissTableColumn("Name", id: "name", width: .flexible(minimum: 140), sortedBy: \Skill.displayName),
                BlissTableColumn("Agents", id: "agents") { first, second in
                    first.agents.count < second.agents.count
                },
                BlissTableColumn("Source", id: "source", sortedBy: \Skill.sourceKind.title),
                BlissTableColumn("Repository", id: "repository", width: .flexible(minimum: 80)) { first, second in
                    (first.repository?.displayName ?? "") < (second.repository?.displayName ?? "")
                },
                BlissTableColumn("Status", id: "status") { first, second in
                    statusRank(first) < statusRank(second)
                },
                BlissTableColumn("Last used", id: "lastUsed", alignment: .trailing) { first, second in
                    (library.lastUsedAt(first) ?? .distantPast) < (library.lastUsedAt(second) ?? .distantPast)
                },
                BlissTableColumn("Updated", id: "updated", alignment: .trailing) { first, second in
                    (first.updatedAt ?? .distantPast) < (second.updatedAt ?? .distantPast)
                },
            ],
            selection: $checkedSkillIDs,
            initialSort: BlissTableSort(columnID: "name"),
            pinsHeader: true,
            // Badges and dates hug their content; the name and repository take
            // the rest and truncate first when the window is narrow.
            autoSizeColumns: true,
            // Row fill at 12pt; with the row's 8pt padding and the checkbox's 4pt
            // inset, the checkboxes line up under the 24pt heading.
            contentInset: Spacing.md,
            onOpen: { skill in selectedSkillID = skill.id }
        ) { skill in
            nameCell(skill)
            agentsCell(skill)
            Badge(.verbatim(skill.sourceKind.title), icon: skill.sourceKind.systemImage)
                .badgeStyle(.secondary)
            Text(LocalizedStringKey.verbatim(skill.repository?.displayName ?? "—"))
                .font(Typography.captionSmall)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            SkillStatusPill(status: library.status(of: skill))
            lastUsedCell(skill)
            updatedCell(skill)
        }
    }

    /// From Claude Code's session transcripts; "—" when none shows the skill.
    @ViewBuilder
    private func lastUsedCell(_ skill: Skill) -> some View {
        if let lastUsedAt = library.lastUsedAt(skill) {
            TimeAgoLabel(date: lastUsedAt)
                .foregroundStyle(Color.textSecondary)
        } else {
            Text(library.isReadingUsage && library.lastUseDates.isEmpty ? "…" : "—")
                .foregroundStyle(Color.textTertiary)
        }
    }

    private func nameColor(_ skill: Skill) -> Color {
        if skill.id == selectedSkillID { return Color.accent }
        return skill.isFullyDisabled ? Color.textTertiary : Color.primary
    }

    /// One line each for the name and summary; hover shows them in full.
    private func nameCell(_ skill: Skill) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LocalizedStringKey.verbatim(skill.displayName))
                .font(Typography.bodySmallSemibold)
                .foregroundStyle(nameColor(skill))
                .lineLimit(1)
                .truncationMode(.tail)
            if !skill.summary.isEmpty {
                // The skill's own description, in the content font.
                Text(LocalizedStringKey.verbatim(skill.summary))
                    .font(Typography.contentCaption)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
            }
        }
        .compactTooltip(position: .below) {
            SkillDetailsTooltip(skill: skill)
        }
    }

    /// The agents' logos, overlapping, with `+N` past four. AvatarStack's own
    /// tooltip lists every name.
    @ViewBuilder
    private func agentsCell(_ skill: Skill) -> some View {
        if !skill.agents.isEmpty {
            AvatarStack(
                skill.agents,
                name: \.displayName,
                image: { agentLogos.logo(forAgentNamed: $0.displayName) },
                limit: 4,
                size: .small,
                shape: .rounded,
                overflowStyle: .plain
            )
        } else {
            Text("None")
                .font(Typography.captionSmall)
                .foregroundStyle(Color.textTertiary)
        }
    }

    @ViewBuilder
    private func updatedCell(_ skill: Skill) -> some View {
        if let updatedAt = skill.updatedAt {
            TimeAgoLabel(date: updatedAt)
                .foregroundStyle(Color.textSecondary)
        } else {
            Text("—").foregroundStyle(Color.textTertiary)
        }
    }

    /// Sorts the statuses that need attention first.
    private func statusRank(_ skill: Skill) -> Int {
        switch library.status(of: skill) {
        case .updateAvailable: 0
        case .locallyModified: 1
        case .failed, .noUpstream: 2
        case .pinned: 3
        case .checking: 4
        case .unchecked: 5
        case .upToDate: 6
        case .notTracked: 7
        case .managedByPlugin: 8
        case .disabled: 9
        }
    }

    // MARK: - Empty

    @ViewBuilder
    private var emptyState: some View {
        if library.isScanning && library.skills.isEmpty {
            EmptyState(icon: "magnifyingglass", title: "Looking for skills…")
        } else if !searchText.isEmpty {
            EmptyState(icon: "magnifyingglass", title: "No matches", subtitle: "Try a different search.")
        } else if filter == .updatesAvailable {
            EmptyState(icon: "checkmark.circle", title: "Everything's up to date", subtitle: "Check again any time with ⌘R.")
        } else {
            EmptyState(icon: "square.stack.3d.up.slash", title: "No skills here", subtitle: "Install some from a GitHub repo to get started.") {
                Button("Install Skills…", action: onInstall)
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
    }
}

/// A Find Repositories sheet's skills, fixed when it opens.
struct RepositorySearch: Identifiable {
    let id = UUID()
    let skillIDs: [Skill.ID]
}

/// The list's title and what the library is doing, plus Remove All when the
/// list is one agent's. Its own view: it reads the library's busy state, which
/// changes through every operation, without redrawing the table.
private struct SkillListHeader: View {
    @Environment(SkillLibrary.self) private var library
    let title: String
    let skillCount: Int
    /// The agent the list is filtered to, when it has skills Remove All can take.
    let removableAgentName: String?
    @Binding var isConfirmingAgentRemoval: Bool
    /// Skills Find Repositories can search for here; empty hides the button.
    let eligibleForRepositorySearch: [Skill.ID]
    @Binding var repositorySearch: RepositorySearch?

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey.verbatim(title))
                    .font(Typography.displaySmall)
                HStack(spacing: Spacing.xs) {
                    if library.isBusy {
                        ThinkingSpinner(size: 10, lineWidth: 1.5)
                        Text(LocalizedStringKey.verbatim(library.activeOperation ?? (library.isScanning ? "Scanning skills…" : "Checking for updates…")))
                    } else if let lastCheckedAt = library.lastCheckedAt {
                        Text("\(skillCount) skills · checked")
                        TimeAgoLabel(date: lastCheckedAt)
                    } else {
                        Text("\(skillCount) skills")
                    }
                }
                .font(Typography.captionSmall)
                .foregroundStyle(Color.textSecondary)
            }
            Spacer(minLength: Spacing.md)
            if !eligibleForRepositorySearch.isEmpty {
                Button {
                    repositorySearch = RepositorySearch(skillIDs: eligibleForRepositorySearch)
                } label: {
                    Label("Find Repositories…", systemImage: "sparkle.magnifyingglass")
                        .lineLimit(1)
                }
                .buttonStyle(SecondaryButtonStyle(compact: true))
                .fixedSize()
                .disabled(library.isBusy)
            }
            if let removableAgentName {
                Button {
                    isConfirmingAgentRemoval = true
                } label: {
                    Label(LocalizedStringKey.verbatim("Remove All from \(removableAgentName)…"), systemImage: "trash")
                        .lineLimit(1)
                }
                .buttonStyle(DestructiveButtonStyle(compact: true))
                .fixedSize()
                .disabled(library.isBusy)
            }
        }
    }
}

/// The command log, docked along the bottom of the list column and flush to
/// its edges so the table's scroll area runs down to the hairline on top. Its
/// text is inset to line up under the heading.
private struct ActivityDock: View {
    @Environment(SkillLibrary.self) private var library

    var body: some View {
        if library.hasActivity {
            TerminalOutputView(lines: library.activityLog, title: "Activity", maxHeight: 160, isDocked: true, contentInset: Spacing.xl)
        }
    }
}

/// What a skill's name shows on hover, sized for the compact tooltip: the
/// full name, the start of its description, and where it came from.
private struct SkillDetailsTooltip: View {
    let skill: Skill

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LocalizedStringKey.verbatim(skill.displayName))
                .font(Typography.captionSemibold)
                .fixedSize(horizontal: false, vertical: true)
            if !skill.summary.isEmpty {
                Text(LocalizedStringKey.verbatim(skill.summary))
                    .font(Typography.contentCaption)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(3)
            }
            Text(LocalizedStringKey.verbatim(metadataLine))
                .font(Typography.captionSmall)
                .foregroundStyle(Color.textTertiary)
                .lineLimit(1)
        }
    }

    /// `Skills CLI · vercel-labs/skills · 19 agents`.
    private var metadataLine: String {
        let agentCount = skill.agents.count == 1 ? "1 agent" : "\(skill.agents.count) agents"
        return [skill.sourceKind.title, skill.repository?.displayName, agentCount].compactMap { $0 }.joined(separator: " · ")
    }
}

#if DEBUG
#Preview(traits: .fixedLayout(width: 960, height: 600)) {
    SkillListView(filter: .all, searchText: "", selectedSkillID: .constant(nil), checkedSkillIDs: .constant([]), onInstall: {})
        .environment(SkillLibrary.preview)
        .background(Color.contentAreaBackground)
        .blissTheme()
}

#Preview("Empty", traits: .fixedLayout(width: 900, height: 500)) {
    SkillListView(filter: .updatesAvailable, searchText: "", selectedSkillID: .constant(nil), checkedSkillIDs: .constant([]), onInstall: {})
        .environment(SkillLibrary(previewSkills: []))
        .background(Color.contentAreaBackground)
        .blissTheme()
}
#endif
