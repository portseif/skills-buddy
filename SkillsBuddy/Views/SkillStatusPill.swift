//
//  SkillStatusPill.swift
//  SkillsBuddy
//

import BlissUI
import SwiftUI

/// A skill's update status as a colored dot and label.
struct SkillStatusPill: View {
    let status: SkillUpdateStatus

    var body: some View {
        StatusDotPill(label: .verbatim(status.title), color: color)
            .compactTooltip(.verbatim(tooltipText))
    }

    private var color: Color {
        switch status {
        case .upToDate: Success.success500
        case .updateAvailable: Info.info500
        case .locallyModified, .pinned, .noUpstream: Warning.warning500
        case .failed: Danger.danger500
        // Gray 500 as text on its own tint was about 3:1; the text token stays above 4.5:1.
        case .unchecked, .checking, .notTracked, .managedByPlugin, .disabled: Color.textSecondary
        }
    }

    private var tooltipText: String {
        switch status {
        case .failed(let reason): reason
        case .locallyModified: "The clone has uncommitted changes, so it won't be updated."
        case .notTracked: "No recorded source to check for updates."
        case .managedByPlugin: "Updated through Claude Code's plugin system."
        case .pinned: "Restored to an older version. Updates skip it until you restore the latest."
        case .disabled: "No agent loads it. Enable puts it back."
        case .noUpstream: "The clone doesn't track a remote branch, so there's nothing to check against."
        default: status.title
        }
    }
}

#Preview(traits: .fixedLayout(width: 220, height: 260)) {
    VStack(alignment: .leading, spacing: Spacing.sm) {
        SkillStatusPill(status: .upToDate)
        SkillStatusPill(status: .updateAvailable)
        SkillStatusPill(status: .locallyModified)
        SkillStatusPill(status: .pinned)
        SkillStatusPill(status: .disabled)
        SkillStatusPill(status: .checking)
        SkillStatusPill(status: .notTracked)
        SkillStatusPill(status: .managedByPlugin)
        SkillStatusPill(status: .failed("Network unreachable"))
    }
    .padding()
    .blissTheme()
}
