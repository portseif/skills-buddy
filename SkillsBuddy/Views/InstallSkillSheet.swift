//
//  InstallSkillSheet.swift
//  SkillsBuddy
//

import BlissUI
import SwiftUI

/// Paste a source, see the skills in it, pick some, install them with the
/// `skills` CLI for the agents you pick.
struct InstallSkillSheet: View {
    @Environment(SkillLibrary.self) private var library
    @Binding var isPresented: Bool

    @State private var sourceText = ""
    /// The source the listed skills came from; installing uses this, not the live text.
    @State private var listedSource: SkillSourceInput?
    @State private var listedSourceText = ""
    @State private var availableSkills: [AvailableSkill] = []
    @State private var selectedSkillIDs: Set<AvailableSkill.ID> = []
    @State private var isLoading = false
    @State private var isInstalling = false
    @State private var errorText: String?
    /// Seeded from the library on appear (the CLI's last pick).
    @State private var selectedAgentKeys: Set<String> = []

    init(isPresented: Binding<Bool>, previewSkills: [AvailableSkill] = []) {
        self._isPresented = isPresented
        self._availableSkills = State(initialValue: previewSkills)
    }

    var body: some View {
        AppSheetScaffold {
            SheetHeader(
                title: "Install Skills",
                subtitle: "From a GitHub repo, a git URL, or a folder on this Mac.",
                icon: "square.and.arrow.down",
                onDismiss: dismiss
            )
        } content: {
            VStack(alignment: .leading, spacing: Spacing.md) {
                FormField(
                    "Source",
                    hint: "owner/repo, a git URL, or a GitHub link to a folder",
                    error: errorText.map(LocalizedStringKey.verbatim)
                ) {
                    HStack(spacing: Spacing.xs) {
                        TextField("vercel-labs/agent-skills", text: $sourceText)
                            .textFieldStyle(.largePadded)
                            .onSubmit(findSkills)
                        Button("Find Skills", action: findSkills)
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(sourceText.trimmingCharacters(in: .whitespaces).isEmpty || isLoading || isInstalling)
                    }
                }

                if isLoading {
                    HStack(spacing: Spacing.xs) {
                        ThinkingSpinner()
                        Text("Looking for skills…")
                            .font(Typography.bodySmall)
                            .foregroundStyle(Color.textSecondary)
                    }
                } else if isInstalling {
                    HStack(spacing: Spacing.xs) {
                        ThinkingSpinner()
                        Text("Installing with the skills CLI…")
                            .font(Typography.bodySmall)
                            .foregroundStyle(Color.textSecondary)
                    }
                } else if !availableSkills.isEmpty {
                    skillList
                    agentPicker
                }
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.md)
        } footer: {
            ActionBar(
                confirmTitle: installTitle,
                isConfirmDisabled: selectedSkillIDs.isEmpty || selectedAgentKeys.isEmpty || isInstalling || isLoading,
                onCancel: dismiss,
                onConfirm: install
            )
        }
        .frame(width: 560)
        .onAppear { selectedAgentKeys = library.defaultInstallAgentKeys }
    }

    // MARK: - Agents

    private var agentPicker: some View {
        FormField("Install for", hint: "The agents that get these skills. Others are left alone.") {
            FlowLayout(spacing: Spacing.xs) {
                ForEach(library.installableAgents) { agent in
                    let isSelected = selectedAgentKeys.contains(agent.key)
                    Button {
                        if isSelected { selectedAgentKeys.remove(agent.key) } else { selectedAgentKeys.insert(agent.key) }
                    } label: {
                        HStack(spacing: Spacing.xs) {
                            CheckboxGlyph(isOn: isSelected)
                            Text(LocalizedStringKey.verbatim(agent.displayName))
                                .font(Typography.bodySmall)
                        }
                    }
                    .buttonStyle(OutlineButtonStyle(compact: true))
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                }
            }
        }
    }

    // MARK: - List

    private var skillList: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text(availableSkills.count == 1 ? "1 skill found" : "\(availableSkills.count) skills found")
                    .font(Typography.captionSemibold)
                    .foregroundStyle(Color.textSecondary)
                Spacer()
                Button(allSelected ? "Select None" : "Select All") {
                    selectedSkillIDs = allSelected ? [] : Set(availableSkills.map(\.id))
                }
                .buttonStyle(GhostButtonStyle())
            }

            // No scroll view here: AppSheetScaffold scrolls its content between
            // the pinned header and footer.
            VStack(spacing: 0) {
                DividedForEach(availableSkills) { availableSkill in
                    AvailableSkillRow(
                        availableSkill: availableSkill,
                        isSelected: selectedSkillIDs.contains(availableSkill.id),
                        isInstalled: library.isInstalled(named: availableSkill.name)
                    ) {
                        toggleSelection(of: availableSkill)
                    }
                }
            }
        }
    }

    private var allSelected: Bool {
        !availableSkills.isEmpty && selectedSkillIDs.count == availableSkills.count
    }

    private var installTitle: String {
        selectedSkillIDs.isEmpty ? "Install" : "Install \(selectedSkillIDs.count)"
    }

    private func toggleSelection(of availableSkill: AvailableSkill) {
        if selectedSkillIDs.contains(availableSkill.id) {
            selectedSkillIDs.remove(availableSkill.id)
        } else {
            selectedSkillIDs.insert(availableSkill.id)
        }
    }

    // MARK: - Actions

    private func findSkills() {
        guard let input = SkillSourceInput.parse(sourceText) else {
            errorText = "Enter owner/repo, a git URL, or a folder path."
            return
        }
        errorText = nil
        isLoading = true
        availableSkills = []
        selectedSkillIDs = []
        let typedSource = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            defer { isLoading = false }
            do {
                let found = try await library.availableSkills(in: input)
                availableSkills = found
                listedSource = input
                listedSourceText = typedSource
                if found.isEmpty { errorText = "No SKILL.md files found in that source." }
                // One new skill: nothing to choose between.
                if found.count == 1, !library.isInstalled(named: found[0].name) { selectedSkillIDs = [found[0].id] }
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    private func install() {
        guard let listedSource else { return }
        let skillNames = availableSkills.filter { selectedSkillIDs.contains($0.id) }.map(\.name)
        // The CLI runs from home, so give it an absolute path for local folders.
        let cliSource: String = if case .localFolder(let folderURL) = listedSource { folderURL.path } else { listedSourceText }
        isInstalling = true

        Task {
            defer { isInstalling = false }
            if await library.install(source: cliSource, skillNames: skillNames, agentKeys: selectedAgentKeys.sorted()) {
                dismiss()
            } else {
                errorText = library.errorMessage
            }
        }
    }

    private func dismiss() {
        isPresented = false
    }
}

/// One skill in a source, with a checkbox.
private struct AvailableSkillRow: View {
    let availableSkill: AvailableSkill
    let isSelected: Bool
    let isInstalled: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(alignment: .top, spacing: Spacing.sm) {
                CheckboxGlyph(isOn: isSelected)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Spacing.xs) {
                        Text(LocalizedStringKey.verbatim(availableSkill.name))
                            .font(Typography.bodySmallSemibold)
                        if isInstalled {
                            Badge("Installed").badgeStyle(.success)
                        }
                    }
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
    }
}

#if DEBUG
#Preview(traits: .fixedLayout(width: 600, height: 600)) {
    InstallSkillSheet(isPresented: .constant(true), previewSkills: AvailableSkill.previewSamples)
        .environment(SkillLibrary.preview)
        .blissTheme()
}
#endif
