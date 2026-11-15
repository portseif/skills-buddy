//
//  SkillsBuddyTheme.swift
//  SkillsBuddy
//
//  The app icon's colors as a BlissUI theme: its violet as the accent (a
//  step deeper in light mode, so violet text stays above 5:1 on every surface), deep
//  indigo surfaces in dark mode and lavender ones in light, the antenna
//  spark's amber for warnings and the cheeks' pink for destructive actions.
//  Registered at launch and used until someone picks another theme in
//  Settings › Appearance.
//

import AppKit
import BlissUI
import SwiftUI

extension BlissTheme {
    static let skillsBuddy = BlissTheme(
        id: "skills-buddy",
        name: "Skills Buddy",
        light: ThemePalette(
            windowBackground: ThemeRGB(0xF1EEFA), contentBackground: ThemeRGB(0xFFFFFF),
            elevatedBackground: ThemeRGB(0xFBFAFF), border: ThemeRGB(0xE2DCF5), accent: ThemeRGB(0x6D28D9),
            status: ThemeStatusColors(warning: 0xF59E0B, danger: 0xEC4899),
            // Text with a touch of the icon's indigo.
            foreground: ThemeRGB(0x1E1B2E)
        ),
        dark: ThemePalette(
            windowBackground: ThemeRGB(0x16132A), contentBackground: ThemeRGB(0x1B1733),
            elevatedBackground: ThemeRGB(0x25203F), border: ThemeRGB(0x342D57), accent: ThemeRGB(0xA78BFA),
            status: ThemeStatusColors(warning: 0xF59E0B, danger: 0xF472B6),
            foreground: ThemeRGB(0xECE9F7)
        ),
        swatch: [ThemeRGB(0x2E1065), ThemeRGB(0xA78BFA), ThemeRGB(0xF472B6), ThemeRGB(0xF59E0B)]
    )

    /// Adds the theme to the picker and makes it the default for anyone who
    /// hasn't chosen one.
    static func registerSkillsBuddyTheme() {
        register(.skillsBuddy)
        UserDefaults.standard.register(defaults: [BlissAppearance.Keys.theme: BlissTheme.skillsBuddy.id])
    }
}

extension DockIconOption {
    /// The Dock icons Settings offers: the app icon and Midnight, the same
    /// robot on a deep indigo tile (`design/app-icon-midnight.svg`).
    static let skillsBuddyOptions: [DockIconOption] = [
        .appIcon(name: "Violet"),
        DockIconOption(id: "midnight", name: "Midnight", image: NSImage(named: "DockIconMidnight")),
    ]
}
