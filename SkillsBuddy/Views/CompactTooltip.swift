//
//  CompactTooltip.swift
//  SkillsBuddy
//
//  Every tooltip in the app uses BlissUI's `.compact` envelope.
//

import BlissUI
import SwiftUI

extension View {
    /// A one-line-ish hint in the compact tooltip.
    func compactTooltip(_ text: LocalizedStringKey, position: TooltipPosition = .above) -> some View {
        tooltip(configuration: .compact, position: position) {
            Text(text)
        }
    }

    /// Custom content in the compact tooltip.
    func compactTooltip<Content: View>(position: TooltipPosition = .above, @ViewBuilder content: @escaping () -> Content) -> some View {
        tooltip(configuration: .compact, position: position, content)
    }
}
