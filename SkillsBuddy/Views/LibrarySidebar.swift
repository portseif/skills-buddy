//
//  LibrarySidebar.swift
//  SkillsBuddy
//

import BlissUI
import SwiftUI

/// Filters on the window's shell color: everything, pending updates, each
/// agent, each source, and each repository.
struct LibrarySidebar: View {
    @Environment(SkillLibrary.self) private var library
    @Binding var filter: LibraryFilter
    var isCollapsed = false

    var body: some View {
        Sidebar(selection: $filter, isCollapsed: isCollapsed) {
            // The extra inset goes on the rows, inside the scroll view, so the
            // scroll view spans the sidebar and its thumb sits at the edge.
            VStack(alignment: .leading, spacing: 0) {
                SidebarSection {
                    SidebarRow("All Skills", icon: "square.stack.3d.up", value: LibraryFilter.all, count: library.skills.count)
                    SidebarRow("Updates Available", icon: "arrow.down.circle", value: LibraryFilter.updatesAvailable, count: library.skillsWithUpdates.count)
                    if library.disabledSkillCount > 0 {
                        SidebarRow("Disabled", icon: "pause.circle", value: LibraryFilter.disabled, count: library.disabledSkillCount)
                    }
                }

                if !library.agentSkillCounts.isEmpty {
                    SidebarDivider()
                    SidebarSection("Agents") {
                        ForEach(library.agentSkillCounts, id: \.agentName) { entry in
                            SidebarRow(.verbatim(entry.agentName), icon: "icon-robot", value: LibraryFilter.agent(entry.agentName), count: entry.count)
                        }
                    }
                }

                SidebarDivider()

                SidebarSection("Sources") {
                    ForEach(SkillSourceKind.allCases, id: \.self) { kind in
                        let count = library.sourceCounts[kind, default: 0]
                        if count > 0 {
                            SidebarRow(.verbatim(kind.title), icon: kind.systemImage, value: LibraryFilter.source(kind), count: count)
                        }
                    }
                }

                if !library.repositoryCounts.isEmpty {
                    SidebarDivider()
                    SidebarSection("Repositories") {
                        ForEach(library.repositoryCounts, id: \.repository) { entry in
                            SidebarRow(.verbatim(entry.repository.displayName), icon: "book.closed", value: LibraryFilter.repository(entry.repository), count: entry.count)
                        }
                    }
                }
            }
            // Collapsed, `Sidebar`'s own inset already centers the icons in the
            // rail; more would push them past the middle.
            .padding(.horizontal, isCollapsed ? 0 : Spacing.sm)
        }
        // `Sidebar` keeps `Spacing.xs` above the first row for its focus ring;
        // pulling up by that much puts the first row level with the top of the
        // content panel beside it.
        .padding(.top, -Spacing.xs)
    }
}

#if DEBUG
#Preview(traits: .fixedLayout(width: 240, height: 640)) {
    LibrarySidebar(filter: .constant(.all))
        .environment(SkillLibrary.preview)
        .background(Color.appShell)
        .blissTheme()
}

#Preview("Collapsed", traits: .fixedLayout(width: 56, height: 640)) {
    LibrarySidebar(filter: .constant(.all), isCollapsed: true)
        .environment(SkillLibrary.preview)
        .background(Color.appShell)
        .blissTheme()
}
#endif
