//
//  LibraryFilter.swift
//  SkillsBuddy
//
//  The sidebar's selection: which slice of the library the table shows.
//

import Foundation

enum LibraryFilter: Hashable {
    case all
    case updatesAvailable
    case disabled
    case agent(String)
    case source(SkillSourceKind)
    case repository(SkillRepository)

    var title: String {
        switch self {
        case .all: "All Skills"
        case .updatesAvailable: "Updates Available"
        case .disabled: "Disabled"
        case .agent(let agentName): agentName
        case .source(let kind): kind.title
        case .repository(let repository): repository.displayName
        }
    }

    func includes(_ skill: Skill, status: SkillUpdateStatus) -> Bool {
        switch self {
        case .all: true
        case .updatesAvailable: status.canUpdate
        case .disabled: !skill.disabledEntries.isEmpty
        // Disabled ones too, so they can be turned back on from there.
        case .agent(let agentName): skill.isInstalled(forAgentNamed: agentName) || skill.disabledAgentNames.contains(agentName)
        case .source(let kind): skill.sourceKind == kind
        case .repository(let repository): skill.repository == repository
        }
    }
}
