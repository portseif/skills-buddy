//
//  AttachRepositorySheet.swift
//  SkillsBuddy
//

import BlissUI
import SwiftUI

/// Gives a skill with no recorded source a repository: find the matching
/// skill in a repo, then reinstall from it with the `skills` CLI for the
/// same agents, so updates come from there.
struct AttachRepositorySheet: View {
    @Environment(SkillLibrary.self) private var library
    let skillID: Skill.ID
    @Binding var isPresented: Bool

    @State private var sourceText = ""
    @State private var listedSource: SkillSourceInput?
    @State private var listedSourceText = ""
    @State private var availableSkills: [AvailableSkill] = []
    @State private var chosenSkillID: AvailableSkill.ID?
    @State private var isLoading = false
    @State private var isAttaching = false
    @State private var errorText: String?

    private var skill: Skill? { library.skill(withID: skillID) }

    var body: some View {
        AppSheetScaffold {
            SheetHeader(
                title: .verbatim("Attach a repository to \(skill?.displayName ?? "skill")"),
                subtitle: "Reinstall it from a repo so it can be updated from there.",
                icon: "link",
                onDismiss: { isPresented = false }
            )
        } content: {
            VStack(alignment: .leading, spacing: Spacing.md) {
                FormField(
                    "Repository",
                    hint: "owner/repo, a git URL, or a GitHub link to a folder",
                    error: errorText.map(LocalizedStringKey.verbatim)
                ) {
                    HStack(spacing: Spacing.xs) {
                        TextField("owner/repo", text: $sourceText)
                            .textFieldStyle(.largePadded)
                            .onSubmit(findSkills)
                        Button("Find Skills", action: findSkills)
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(sourceText.trimmingCharacters(in: .whitespaces).isEmpty || isLoading || isAttaching)
                    }
                }

                if isLoading || isAttaching {
                    HStack(spacing: Spacing.xs) {
                        ThinkingSpinner()
                        Text(isAttaching ? "Reinstalling with the skills CLI…" : "Looking for skills…")
                            .font(Typography.bodySmall)
                            .foregroundStyle(Color.textSecondary)
                    }
                } else if !availableSkills.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("Which skill in the repo is this?")
                            .font(Typography.captionSemibold)
                            .foregroundStyle(Color.textSecondary)
                        VStack(spacing: 0) {
                            DividedForEach(availableSkills) { availableSkill in
                                choiceRow(availableSkill)
                            }
                        }
                    }
                    Banner(
                        "The local copy is replaced",
                        message: .verbatimWithCode(replacementMessage),
                        style: .warning
                    )
                }
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.md)
        } footer: {
            ActionBar(
                confirmTitle: "Attach",
                isConfirmDisabled: chosenSkillID == nil || isLoading || isAttaching,
                onCancel: { isPresented = false },
                onConfirm: attach
            )
        }
        .frame(width: 560)
    }

    private func choiceRow(_ availableSkill: AvailableSkill) -> some View {
        let isChosen = chosenSkillID == availableSkill.id
        return Button {
            chosenSkillID = availableSkill.id
        } label: {
            HStack(alignment: .top, spacing: Spacing.sm) {
                RadioGlyph(isOn: isChosen)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey.verbatim(availableSkill.name))
                        .font(Typography.bodySmallSemibold)
                    if !availableSkill.summary.isEmpty {
                        Text(LocalizedStringKey.verbatim(availableSkill.summary))
                            .font(Typography.captionSmall)
                            .foregroundStyle(Color.textSecondary)
                            .lineLimit(2)
                    }
                    if !availableSkill.relativePath.isEmpty {
                        Text(LocalizedStringKey.verbatim(availableSkill.relativePath))
                            .font(Typography.codeTiny)
                            .foregroundStyle(Color.textTertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(FocusablePlainButtonStyle())
        .accessibilityAddTraits(isChosen ? [.isSelected] : [])
    }

    private var replacementMessage: String {
        let agents = skill?.agents.map(\.displayName).joined(separator: ", ") ?? ""
        return "Skills Buddy moves the current copy to the Trash and installs the repo's version for \(agents). Local edits that aren't in the repo won't carry over; they stay in the Trash."
    }

    private func findSkills() {
        guard let input = SkillSourceInput.parse(sourceText) else {
            errorText = "Enter owner/repo, a git URL, or a folder path."
            return
        }
        errorText = nil
        isLoading = true
        availableSkills = []
        chosenSkillID = nil
        let typedSource = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            defer { isLoading = false }
            do {
                let found = try await library.availableSkills(in: input)
                availableSkills = found
                listedSource = input
                listedSourceText = typedSource
                if found.isEmpty { errorText = "No SKILL.md files found in that source." }
                // Preselect the skill with the same name, the usual case.
                let localName = skill?.folderName ?? ""
                chosenSkillID = found.first { $0.name.caseInsensitiveCompare(localName) == .orderedSame }?.id
                    ?? (found.count == 1 ? found[0].id : nil)
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    private func attach() {
        guard let skill, let listedSource,
              let chosen = availableSkills.first(where: { $0.id == chosenSkillID }) else { return }
        let cliSource: String = if case .localFolder(let folderURL) = listedSource { folderURL.path } else { listedSourceText }
        isAttaching = true
        Task {
            defer { isAttaching = false }
            if await library.attachRepository(to: skill, source: cliSource, sourceSkillName: chosen.name) {
                isPresented = false
            } else {
                errorText = library.errorMessage
            }
        }
    }
}

#if DEBUG
#Preview(traits: .fixedLayout(width: 600, height: 520)) {
    AttachRepositorySheet(skillID: Skill.previewSamples[2].id, isPresented: .constant(true))
        .environment(SkillLibrary.preview)
        .blissTheme()
}
#endif
