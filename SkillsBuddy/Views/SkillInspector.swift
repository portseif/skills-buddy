//
//  SkillInspector.swift
//  SkillsBuddy
//

import AppKit
import BlissUI
import SwiftUI

/// The selected skill: what it is, which agents load it, where it lives, and
/// what you can do with it.
struct SkillInspector: View {
    @Environment(SkillLibrary.self) private var library
    let skill: Skill

    @State private var isHistoryPresented = false
    @State private var isConfirmingRemovalFromAll = false
    @State private var agentPendingRemoval: SkillAgentInstall?
    @State private var isAttachSheetPresented = false
    @State private var isFindRepositorySheetPresented = false
    /// Loaded when Track Remote Branch is clicked; shown for confirmation.
    @State private var pendingTrackingPlan: GitTrackingPlan?

    private var status: SkillUpdateStatus { library.status(of: skill) }

    var body: some View {
        // Read now: the confirmation sheet clears `agentPendingRemoval` as it
        // closes, before it runs its action.
        let pendingAgent = agentPendingRemoval
        let trackingPlan = pendingTrackingPlan
        ScrollViewWithThinIndicator {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(LocalizedStringKey.verbatim(skill.displayName))
                        .font(Typography.headingSmall)
                        .textSelection(.enabled)
                    SkillStatusPill(status: status)
                }

                if !skill.summary.isEmpty {
                    // The skill's own description, in the content font.
                    Text(LocalizedStringKey.verbatim(skill.summary))
                        .font(Typography.contentSmall)
                        .foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                statusBanner
                actions
                agentsSection
                detailsSection

                if skill.isRemovable && (!skill.agents.isEmpty || !skill.disabledEntries.isEmpty) {
                    Button {
                        isConfirmingRemovalFromAll = true
                    } label: {
                        Label("Remove from All Agents…", systemImage: "trash")
                    }
                    .buttonStyle(DestructiveButtonStyle())
                    .disabled(library.isBusy)
                }
            }
            .padding(Spacing.lg)
        }
        // Wider than the standard sheet: the graph needs room for lanes, title and age.
        .appSheet(isPresented: $isHistoryPresented, contentSized: true) {
            SkillHistorySheet(skillID: skill.id, isPresented: $isHistoryPresented)
        }
        .appSheet(isPresented: $isFindRepositorySheetPresented, contentSized: true) {
            FindRepositoriesSheet(skillIDs: [skill.id], isPresented: $isFindRepositorySheetPresented)
        }
        .appSheet(isPresented: $isAttachSheetPresented, contentSized: true) {
            AttachRepositorySheet(skillID: skill.id, isPresented: $isAttachSheetPresented)
        }
        .confirmationSheet(
            isPresented: $isConfirmingRemovalFromAll,
            title: .verbatim("Remove \(skill.displayName) from every agent?"),
            message: .verbatimWithCode(removalMessage(for: nil)),
            confirmTitle: "Remove",
            isDestructive: true
        ) {
            Task { await library.remove(skill) }
        }
        .confirmationSheet(
            isPresented: Binding(get: { agentPendingRemoval != nil }, set: { if !$0 { agentPendingRemoval = nil } }),
            title: .verbatim("Remove \(skill.displayName) from \(agentPendingRemoval?.displayName ?? "")?"),
            message: .verbatimWithCode(removalMessage(for: agentPendingRemoval)),
            confirmTitle: "Remove",
            isDestructive: true
        ) {
            guard let agent = pendingAgent else { return }
            Task { await library.remove(skill, from: agent) }
        }
        .confirmationSheet(
            isPresented: Binding(get: { pendingTrackingPlan != nil }, set: { if !$0 { pendingTrackingPlan = nil } }),
            title: .verbatim("Track \(pendingTrackingPlan?.remoteBranch ?? "the remote branch")?"),
            message: .verbatimWithCode(pendingTrackingPlan.map(trackingMessage) ?? ""),
            confirmTitle: pendingTrackingPlan?.movesHead == true ? "Switch and Track" : "Track"
        ) {
            guard let plan = trackingPlan else { return }
            Task { await library.trackRemoteBranch(for: skill, plan: plan) }
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusBanner: some View {
        switch status {
        case .locallyModified:
            Banner(
                "Local changes",
                message: "This clone has uncommitted changes. Commit or discard them, then check again.",
                style: .warning
            )
        case .pinned:
            Banner(
                .verbatim("Pinned to \(skill.pinnedRevision.map { String($0.prefix(7)) } ?? "an older version")"),
                message: "Updates skip this skill until you restore the latest version.",
                style: .warning,
                actionTitle: "Restore Latest",
                action: {
                    Task { await library.restore(skill, to: skill.pinnedRevision ?? "", isLatest: true) }
                }
            )
        case .noUpstream:
            Banner(
                "Not tracking a remote branch",
                message: "The clone doesn't follow a branch on its remote, so there's nothing to check against.",
                style: .warning,
                actionTitle: "Track Remote Branch…",
                action: { Task { await loadTrackingPlan() } }
            )
        case .failed(let reason):
            Banner("Couldn't check for updates", message: .verbatim(reason), style: .danger)
        case .disabled:
            Banner(
                "Disabled",
                message: .verbatimWithCode(disabledMessage),
                style: .info,
                actionTitle: "Enable",
                action: { Task { await library.enable([skill]) } }
            )
        case .managedByPlugin:
            Banner(
                "Part of a plugin",
                message: "Claude Code updates and removes plugin skills. Use /plugin in Claude Code.",
                style: .info
            )
        default:
            EmptyView()
        }
    }

    // MARK: - Actions

    private var actions: some View {
        FlowLayout(spacing: Spacing.xs) {
            if status.canUpdate {
                Button {
                    Task { await library.update(skill) }
                } label: {
                    Label("Update", systemImage: "arrow.down.circle")
                }
                .buttonStyle(PrimaryButtonStyle(compact: true))
                .disabled(library.isBusy)
            }

            if skill.hasHistory {
                Button {
                    isHistoryPresented = true
                } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(SecondaryButtonStyle(compact: true))
            }

            if skill.isRemovable && !skill.agents.isEmpty {
                Button {
                    Task { await library.disable([skill]) }
                } label: {
                    Label("Disable", systemImage: "pause.circle")
                }
                .buttonStyle(SecondaryButtonStyle(compact: true))
                .disabled(library.isBusy)
            } else if !skill.disabledEntries.isEmpty {
                Button {
                    Task { await library.enable([skill]) }
                } label: {
                    Label("Enable", systemImage: "play.circle")
                }
                .buttonStyle(SecondaryButtonStyle(compact: true))
                .disabled(library.isBusy)
            }

            if RepoFinder.isEligible(skill) {
                Button {
                    isFindRepositorySheetPresented = true
                } label: {
                    Label("Find Repository…", systemImage: "sparkle.magnifyingglass")
                }
                .buttonStyle(SecondaryButtonStyle(compact: true))
                .disabled(library.isBusy)
                Button {
                    isAttachSheetPresented = true
                } label: {
                    Label("Attach Repository…", systemImage: "link")
                }
                .buttonStyle(SecondaryButtonStyle(compact: true))
                .disabled(library.isBusy)
            }

            Button {
                NSWorkspace.shared.open(skill.skillFileURL)
            } label: {
                Label("Open SKILL.md", systemImage: "doc.text")
            }
            .buttonStyle(SecondaryButtonStyle(compact: true))

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([skill.resolvedFolderURL])
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            .buttonStyle(SecondaryButtonStyle(compact: true))

            if let webURL = skill.repository?.webURL {
                Button {
                    NSWorkspace.shared.open(webURL)
                } label: {
                    Label("Repository", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(SecondaryButtonStyle(compact: true))
            }
        }
    }

    // MARK: - Agents

    /// Every agent that loads it, or did before Disable, with a switch each.
    private var agentRows: [(name: String, install: SkillAgentInstall?)] {
        let active = skill.agents.map { (name: $0.displayName, install: Optional($0)) }
        let disabled = skill.disabledAgentNames.filter { !skill.isInstalled(forAgentNamed: $0) }.map { (name: $0, install: SkillAgentInstall?.none) }
        return (active + disabled).sorted { $0.name < $1.name }
    }

    @ViewBuilder
    private var agentsSection: some View {
        if agentRows.isEmpty {
            RoundedSection("Agents", insetsHeader: false) {
                Text("Not installed for any agent.")
                    .font(Typography.bodySmall)
                    .foregroundStyle(Color.textSecondary)
            }
        } else {
            RoundedSection(divided: true, insetsHeader: false) {
                ForEach(agentRows, id: \.name) { row in
                    agentRow(name: row.name, install: row.install)
                }
            } header: {
                SectionHeader("Agents", count: skill.agents.count, topPadding: 0)
            }
        }
    }

    private func agentRow(name: String, install: SkillAgentInstall?) -> some View {
        let isEnabled = install != nil
        let sharing = library.agentsSharingFolder(with: name).filter { skill.isInstalled(forAgentNamed: $0) || skill.disabledAgentNames.contains($0) }
        return HStack(spacing: Spacing.sm) {
            Avatar(name: name, image: AgentLogoStore.shared.logo(forAgentNamed: name), size: .small, shape: .rounded)
                .opacity(isEnabled ? 1 : 0.4)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(LocalizedStringKey.verbatim(name))
                    .font(Typography.bodySmall)
                    .foregroundStyle(isEnabled ? Color.primary : Color.textTertiary)
                if !sharing.isEmpty {
                    Text(LocalizedStringKey.verbatim("Shares a folder with \(sharing.joined(separator: ", "))"))
                        .font(Typography.captionSmall)
                        .foregroundStyle(Color.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Spacing.sm)
            if skill.isRemovable {
                Toggle(LocalizedStringKey.verbatim("Enabled for \(name)"), isOn: Binding(
                    get: { isEnabled },
                    set: { turnOn in
                        Task {
                            if turnOn { await library.enable([skill], forAgentNamed: name) }
                            else { await library.disable([skill], forAgentNamed: name) }
                        }
                    }
                ))
                .toggleStyle(.flatSwitch)
                .controlSize(.small)
                .labelsHidden()
                .disabled(library.isBusy)
                if let install {
                    HoverIconButton(
                        systemImage: "minus.circle",
                        tint: Danger.danger500,
                        help: "Remove from \(name)"
                    ) {
                        agentPendingRemoval = install
                    }
                    .disabled(library.isBusy)
                }
            }
        }
        .padding(.vertical, Spacing.xs)
        .compactTooltip(.verbatim(install?.folderURL?.path ?? "Disabled for \(name)"))
    }

    private var disabledMessage: String {
        let base = "No agent loads it; its folders are set aside in Skills Buddy. Enable puts them back as they were."
        return skill.sourceKind == .skillsCLI
            ? base + " While it's disabled, running `npx skills update` outside Skills Buddy reinstalls it."
            : base
    }

    // MARK: - Details

    private var detailsSection: some View {
        RoundedSection(divided: true, insetsHeader: false) {
            DetailRow(label: "Source", value: skill.sourceKind.title)
            if let repository = skill.repository {
                if let webURL = repository.webURL {
                    DetailRow(label: "Repository", value: webURL.absoluteString, isLink: true)
                } else {
                    DetailRow(label: "Repository", value: repository.location, monospace: true, copyable: true)
                }
            }
            if let pluginIdentifier = skill.pluginIdentifier {
                DetailRow(label: "Plugin", value: pluginIdentifier, monospace: true)
            }
            if let version = skill.version {
                DetailRow(label: skill.sourceKind == .plugin ? "Version" : "Revision", value: version, monospace: true, copyable: true)
            }
            DetailRow(label: "Folder", value: skill.folderURL.path, isPath: true)
            if skill.isSymlink {
                DetailRow(label: "Links to", value: skill.resolvedFolderURL.path, isPath: true)
            }
            if let installedAt = skill.installedAt {
                DetailRow(label: "Installed", value: installedAt.formatted(date: .abbreviated, time: .shortened))
            }
            if let updatedAt = skill.updatedAt {
                DetailRow(label: "Updated", value: updatedAt.formatted(date: .abbreviated, time: .shortened))
            }
            DetailRow(label: "Last used", value: lastUsedDescription)
        } header: {
            SectionHeader("Details", topPadding: 0)
        }
    }

    private func loadTrackingPlan() async {
        if let plan = await library.trackingPlan(for: skill) {
            pendingTrackingPlan = plan
        } else {
            library.errorMessage = "\(skill.displayName)'s clone has no branch on its remote to track."
        }
    }

    private func trackingMessage(_ plan: GitTrackingPlan) -> String {
        guard plan.movesHead else {
            return "Sets `\(plan.localBranch)` to track `\(plan.remoteBranch)`. The files don't change; checks and updates follow `\(plan.remoteBranch)` from now on."
        }
        let from = skill.version.map { "commit `\($0)`" } ?? "its current commit"
        let behind = plan.commitsBehind == 1 ? "1 newer commit" : "\(plan.commitsBehind) newer commits"
        return "The clone is on \(from), not a branch. This switches it to `\(plan.localBranch)`, tracking `\(plan.remoteBranch)`, which has \(behind), so the skill's files change now. If another tool installed this clone, its own updater may expect the old commit."
    }

    /// From Claude Code's session transcripts.
    private var lastUsedDescription: String {
        if let lastUsedAt = library.lastUsedAt(skill) {
            return lastUsedAt.formatted(date: .abbreviated, time: .shortened)
        }
        return library.isReadingUsage && library.lastUseDates.isEmpty ? "Reading Claude Code sessions…" : "Not in any Claude Code session"
    }

    private func removalMessage(for agent: SkillAgentInstall?) -> String {
        let target = agent.map { "from \($0.displayName)" } ?? "from every agent that has it"
        switch skill.sourceKind {
        case .skillsCLI:
            return "Runs `skills remove` \(target). The shared copy stays while another agent still uses it."
        case .git, .local:
            return "Moves the skill's folder \(target) to the Trash. A link goes to the Trash as a link; the folder it points to stays."
        case .plugin:
            return ""
        }
    }
}

/// Shown in the inspector until a row is picked.
struct SkillInspectorPlaceholder: View {
    var body: some View {
        EmptyState(icon: "sidebar.right", title: "No skill selected", subtitle: "Click a skill to see its details.")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if DEBUG
#Preview(traits: .fixedLayout(width: 340, height: 820)) {
    SkillInspector(skill: Skill.previewSamples[0])
        .background(Color.contentAreaBackground)
        .appSheetHost()
        .environment(SkillLibrary.preview)
        .blissTheme()
}

#Preview("Plugin skill", traits: .fixedLayout(width: 340, height: 720)) {
    SkillInspector(skill: Skill.previewSamples[3])
        .background(Color.contentAreaBackground)
        .appSheetHost()
        .environment(SkillLibrary.preview)
        .blissTheme()
}

#Preview("Placeholder", traits: .fixedLayout(width: 340, height: 400)) {
    SkillInspectorPlaceholder()
        .blissTheme()
}
#endif
