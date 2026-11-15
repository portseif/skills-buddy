//
//  FindRepositoriesSheet.swift
//  SkillsBuddy
//
//  Searches GitHub for the repositories of skills with no source and attaches
//  the ones found, so they can be updated from there. Apple Intelligence, when
//  it's on, judges near matches; identical files need no judging.
//

import AppKit
import BlissUI
import SwiftUI

struct FindRepositoriesSheet: View {
    @Environment(SkillLibrary.self) private var library
    @Environment(RepoFinder.self) private var finder
    let skillIDs: [Skill.ID]
    @Binding var isPresented: Bool

    /// The match waiting for the user to confirm attaching it.
    @State private var pendingAttach: PendingAttach?
    @State private var attachingSkillID: Skill.ID?

    private struct PendingAttach: Equatable {
        let skillID: Skill.ID
        let match: RepoMatch
    }

    var body: some View {
        let skills = skillIDs.compactMap(library.skill(withID:))
        AppSheetScaffold {
            SheetHeader(
                title: .verbatim(skills.count == 1 ? "Find a repository for \(skills[0].displayName)" : "Find repositories"),
                subtitle: "Searches GitHub for skills with no source, so they can update from there.",
                icon: "sparkle.magnifyingglass",
                onDismiss: { isPresented = false }
            )
        } content: {
            VStack(alignment: .leading, spacing: Spacing.md) {
                IntelligenceNote(status: finder.intelligence)
                if let setupError = finder.setupError {
                    Banner("Can't search GitHub", message: .verbatimWithCode(setupError), style: .danger)
                }
                VStack(spacing: 0) {
                    DividedForEach(skills) { skill in
                        RepoFinderRow(
                            skill: skill,
                            status: finder.status(of: skill.id),
                            isAttaching: attachingSkillID == skill.id,
                            onAttach: { match in pendingAttach = PendingAttach(skillID: skill.id, match: match) }
                        )
                    }
                }
                Text("GitHub allows 10 searches a minute, so each skill takes about 7 to 15 seconds. Skill names are sent to GitHub; descriptions are compared on this Mac.")
                    .font(Typography.captionSmall)
                    .foregroundStyle(Color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.md)
        } footer: {
            ActionBar(
                cancelTitle: "Done",
                confirmTitle: finder.isRunning ? "Stop" : "Search GitHub",
                isConfirmDisabled: skills.isEmpty || attachingSkillID != nil,
                onCancel: { isPresented = false },
                onConfirm: toggleSearch
            )
        }
        .frame(width: 640)
        .confirmationSheet(
            isPresented: Binding(get: { pendingAttach != nil }, set: { if !$0 { pendingAttach = nil } }),
            title: .verbatim(attachTitle),
            message: .verbatimWithCode(attachMessage),
            confirmTitle: "Attach"
        ) {
            if let pendingAttach { attach(pendingAttach) }
        }
    }

    private func toggleSearch() {
        if finder.isRunning {
            finder.stop()
        } else {
            let skills = skillIDs.compactMap(library.skill(withID:)).filter(RepoFinder.isEligible)
            Task { finder.search(skills, environment: await library.resolvedEnvironment()) }
        }
    }

    private var attachTitle: String {
        guard let pendingAttach, let skill = library.skill(withID: pendingAttach.skillID) else { return "Attach the repository?" }
        return "Attach \(pendingAttach.match.candidate.repository) to \(skill.displayName)?"
    }

    private var attachMessage: String {
        guard let pendingAttach, let skill = library.skill(withID: pendingAttach.skillID) else { return "" }
        let agents = skill.agents.map(\.displayName).joined(separator: ", ")
        return "Skills Buddy moves the current copy to the Trash and installs `\(pendingAttach.match.skillName)` from `\(pendingAttach.match.candidate.repository)` for \(agents). Local edits that aren't in the repo stay in the Trash."
    }

    private func attach(_ pending: PendingAttach) {
        guard let skill = library.skill(withID: pending.skillID) else { return }
        attachingSkillID = skill.id
        Task {
            defer { attachingSkillID = nil }
            await library.attachRepository(to: skill, source: pending.match.candidate.repository, sourceSkillName: pending.match.skillName)
        }
    }
}

/// Whether Apple Intelligence helps this search, and what that means.
private struct IntelligenceNote: View {
    let status: IntelligenceStatus

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            Image(systemName: "apple.intelligence")
                .foregroundStyle(status == .available ? Color.accent : Color.textTertiary)
            Text(LocalizedStringKey.verbatim(message))
                .font(Typography.captionSmall)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var message: String {
        switch status {
        case .available:
            "Apple Intelligence compares descriptions on this Mac when a copy isn't identical, and suggests searches when a name finds nothing."
        case .unavailable(let reason):
            "\(reason) Identical copies are still found, and close ones by name."
        }
    }
}

/// One skill: its name, then what the search found and Attach.
private struct RepoFinderRow: View {
    let skill: Skill
    let status: RepoFinder.Status?
    let isAttaching: Bool
    let onAttach: (RepoMatch) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey.verbatim(skill.displayName))
                    .font(Typography.bodySmallSemibold)
                if !skill.summary.isEmpty {
                    Text(LocalizedStringKey.verbatim(skill.summary))
                        .font(Typography.contentCaption)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            outcome
        }
        .padding(.vertical, Spacing.sm)
    }

    @ViewBuilder
    private var outcome: some View {
        if let repository = skill.repository {
            Label(LocalizedStringKey.verbatim("Attached to \(repository.displayName)"), systemImage: "checkmark.circle.fill")
                .font(Typography.captionSmall)
                .foregroundStyle(Color.success)
        } else if isAttaching {
            progress("Attaching…")
        } else {
            switch status {
            case nil:
                quiet("Not searched")
            case .waiting:
                quiet("Waiting…")
            case .searching:
                progress("Searching…")
            case .notFound:
                quiet("No match")
            case .failed(let message):
                quiet("Couldn't search")
                    .compactTooltip(.verbatim(message), position: .below)
            case .found(let match):
                found(match)
            }
        }
    }

    private func found(_ match: RepoMatch) -> some View {
        HStack(spacing: Spacing.sm) {
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: Spacing.xs) {
                    Badge(.verbatim(match.confidence == .exact ? "Exact copy" : "Likely"))
                        .badgeStyle(match.confidence == .exact ? .success : .warning)
                    TextLink(match.candidate.repository, font: Typography.captionSemibold, truncationMode: .middle, hoverSymbol: "arrow.up.right") {
                        if let webURL = match.candidate.webURL { NSWorkspace.shared.open(webURL) }
                    }
                }
                Text(LocalizedStringKey.verbatim(detail(for: match)))
                    .font(Typography.captionSmall)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
            .frame(maxWidth: 300, alignment: .trailing)
            Button("Attach") { onAttach(match) }
                .buttonStyle(SecondaryButtonStyle(compact: true))
                .fixedSize()
        }
    }

    /// `Same SKILL.md · ★ 1.2k · also in 3 other repos`.
    private func detail(for match: RepoMatch) -> String {
        var parts = [match.reason]
        if let stars = match.stars { parts.append("★ \(stars.formatted(.number.notation(.compactName)))") }
        if match.otherCopies > 0 { parts.append("also in \(match.otherCopies) other repo\(match.otherCopies == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    private func quiet(_ text: String) -> some View {
        Text(LocalizedStringKey.verbatim(text))
            .font(Typography.captionSmall)
            .foregroundStyle(Color.textTertiary)
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: Spacing.xs) {
            ThinkingSpinner(size: 10, lineWidth: 1.5)
            quiet(text)
        }
    }
}

#if DEBUG
#Preview(traits: .fixedLayout(width: 680, height: 560)) {
    FindRepositoriesSheet(skillIDs: Skill.previewSamples.map(\.id), isPresented: .constant(true))
        .environment(SkillLibrary.preview)
        .environment(RepoFinder())
        .blissTheme()
}
#endif
