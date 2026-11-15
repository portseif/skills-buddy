//
//  SkillHistorySheet.swift
//  SkillsBuddy
//

import BlissUI
import SwiftUI

/// A skill's commit history as a graph, with Restore on each version.
struct SkillHistorySheet: View {
    @Environment(SkillLibrary.self) private var library
    let skillID: Skill.ID
    @Binding var isPresented: Bool

    @State private var history: SkillHistory?
    @State private var errorText: String?
    @State private var isLoading = false
    @State private var revisionPendingRestore: SkillRevision?
    private let isPreview: Bool

    init(skillID: Skill.ID, isPresented: Binding<Bool>, previewHistory: SkillHistory? = nil) {
        self.skillID = skillID
        self._isPresented = isPresented
        self._history = State(initialValue: previewHistory)
        self.isPreview = previewHistory != nil
    }

    /// Re-read after each restore: the skill's pin and folder can change.
    private var skill: Skill? { library.skill(withID: skillID) }

    var body: some View {
        // Read now: the confirmation sheet clears `revisionPendingRestore` as it
        // closes, before it runs its action.
        let pendingRevision = revisionPendingRestore
        AppSheetScaffold {
            SheetHeader(
                title: .verbatim("\(skill?.displayName ?? "Skill") history"),
                subtitle: .verbatim(subtitle),
                icon: "clock.arrow.circlepath",
                onDismiss: { isPresented = false }
            )
        } content: {
            VStack(alignment: .leading, spacing: Spacing.md) {
                if let errorText {
                    Banner("Couldn't read the history", message: .verbatim(errorText), style: .danger)
                }
                if isLoading && history == nil {
                    HStack(spacing: Spacing.xs) {
                        ThinkingSpinner()
                        Text("Reading history…")
                            .font(Typography.bodySmall)
                            .foregroundStyle(Color.textSecondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 120)
                } else if let history, history.revisions.isEmpty {
                    EmptyState(icon: "clock", title: "No commits touch this skill").contained()
                } else if let history {
                    // A row click asks to restore too: the hover button is hidden from
                    // the keyboard and VoiceOver until hovered, the row never is.
                    CommitGraph(commits(from: history), onOpen: { commit in
                        if let revision = restorableRevision(commit.id, in: history) { revisionPendingRestore = revision }
                    }) { commit, isHovered in
                        restoreButton(for: commit, in: history, isHovered: isHovered)
                    }
                    if history.isTruncated {
                        Text("Showing the latest \(history.revisions.count) changes.")
                            .font(Typography.captionSmall)
                            .foregroundStyle(Color.textTertiary)
                    }
                }
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.md)
        } footer: {
            HStack {
                Text(LocalizedStringKey.verbatim(footnote))
                    .font(Typography.captionSmall)
                    .foregroundStyle(Color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Spacing.md)
                Button("Done") { isPresented = false }
                    .buttonStyle(PrimaryButtonStyle(compact: true))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.md)
        }
        .frame(width: 760)
        .task { await load() }
        .confirmationSheet(
            isPresented: Binding(get: { revisionPendingRestore != nil }, set: { if !$0 { revisionPendingRestore = nil } }),
            title: .verbatim("Restore \(skill?.displayName ?? "skill") to \(revisionPendingRestore?.shortHash ?? "")?"),
            message: .verbatimWithCode(restoreMessage),
            confirmTitle: "Restore"
        ) {
            guard let skill, let revision = pendingRevision, let history else { return }
            let isLatest = revision.commitHash == history.latestCommitHash
            Task {
                if await library.restore(skill, to: revision.commitHash, isLatest: isLatest) {
                    await load()
                }
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func restoreButton(for commit: CommitGraphCommit, in history: SkillHistory, isHovered: Bool) -> some View {
        if let revision = restorableRevision(commit.id, in: history) {
            Button("Restore") { revisionPendingRestore = revision }
                .buttonStyle(SecondaryButtonStyle(compact: true))
                .opacity(isHovered ? 1 : 0)
                .disabled(!isHovered || library.isBusy)
        } else {
            // Holds the same width, so every row's age lines up.
            Button("Restore") {}
                .buttonStyle(SecondaryButtonStyle(compact: true))
                .hidden()
                .accessibilityHidden(true)
        }
    }

    /// Any version but the installed one, as long as the skill's folder exists
    /// in it (not before it was added or after it was deleted).
    private func restorableRevision(_ commitHash: String, in history: SkillHistory) -> SkillRevision? {
        guard commitHash != history.installedCommitHash, !library.isBusy,
              let revision = history.revisions.first(where: { $0.commitHash == commitHash }),
              revision.folderTreeHash != nil else { return nil }
        return revision
    }

    private func commits(from history: SkillHistory) -> [CommitGraphCommit] {
        let showsLocalBranches = skill?.sourceKind == .git
        return history.revisions.map { revision in
            var refs: [CommitGraphRef] = []
            if revision.commitHash == history.installedCommitHash {
                refs.append(CommitGraphRef("Installed", kind: .highlight))
            }
            if revision.commitHash == history.latestCommitHash, revision.commitHash != history.installedCommitHash {
                refs.append(CommitGraphRef("Latest", kind: .tag))
            }
            for decoration in revision.decorations {
                if decoration.hasPrefix("tag: ") {
                    refs.append(CommitGraphRef(String(decoration.dropFirst("tag: ".count)), kind: .tag))
                } else if decoration.contains("/") && decoration.hasPrefix("origin/") {
                    refs.append(CommitGraphRef(decoration, kind: .remoteBranch))
                } else if showsLocalBranches {
                    // A CLI skill's cache clone keeps a stale local branch; only show a real clone's.
                    refs.append(CommitGraphRef(decoration, kind: .branch))
                }
            }
            return CommitGraphCommit(
                id: revision.commitHash,
                parentIDs: revision.parentHashes,
                title: revision.title,
                shortHash: revision.shortHash,
                authorName: revision.authorName,
                date: revision.date,
                refs: refs
            )
        }
    }

    // MARK: - Text

    private var subtitle: String {
        guard let skill else { return "" }
        let source = skill.repository?.displayName ?? skill.sourceKind.title
        return skill.sourceFolderPath.map { $0.isEmpty ? source : "\(source) · \($0)" } ?? source
    }

    private var footnote: String {
        switch skill?.sourceKind {
        case .git: "Restoring resets this clone to that commit. Update brings it back to the latest."
        case .skillsCLI: "Restoring reinstalls that commit with the skills CLI and pins it. Restore Latest to follow updates again."
        default: ""
        }
    }

    private var restoreMessage: String {
        guard let skill, let revision = revisionPendingRestore else { return "" }
        let title = "\"\(revision.title)\""
        switch skill.sourceKind {
        case .git:
            let others = library.skills.filter { $0.gitWorkTreeURL == skill.gitWorkTreeURL && $0.id != skill.id }.count
            let sharedNote = others > 0 ? " The clone holds \(others) other skill(s); they move with it." : ""
            return "Resets the clone to \(revision.shortHash), \(title).\(sharedNote)"
        case .skillsCLI:
            let agents = skill.agents.map(\.displayName).joined(separator: ", ")
            return "Reinstalls \(revision.shortHash), \(title), for \(agents) with the skills CLI."
        case .plugin, .local:
            return ""
        }
    }

    // MARK: - Loading

    private func load() async {
        guard !isPreview, let skill else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            history = try await library.history(for: skill)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }
}

#if DEBUG
#Preview(traits: .fixedLayout(width: 800, height: 640)) {
    SkillHistorySheet(skillID: Skill.previewSamples[1].id, isPresented: .constant(true), previewHistory: SkillHistory.preview)
        .appSheetHost()
        .environment(SkillLibrary.preview)
        .blissTheme()
}
#endif
