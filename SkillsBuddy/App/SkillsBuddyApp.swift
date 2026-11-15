//
//  SkillsBuddyApp.swift
//  SkillsBuddy
//
//  Finds your Claude skills, shows where each came from, and updates them.
//

import BlissUI
import SwiftUI

@main
struct SkillsBuddyApp: App {
    @State private var library = SkillLibrary()
    /// Repositories found for skills with no source; kept while the app runs.
    @State private var repoFinder = RepoFinder()
    /// Settings mode on the main window and its page; here so they survive the
    /// theme modifier rebuilding the window when a theme is picked in them.
    @State private var isSettingsPresented = false
    @State private var settingsPage = SettingsPage.appearance
    /// How far the settings page is scrolled, so a font or theme change (which
    /// rebuilds the window) doesn't jump it back to the top.
    @State private var settingsScroll = SettingsScrollMemory()

    init() {
        BlissTheme.registerSkillsBuddyTheme()
    }

    var body: some Scene {
        WindowGroup("Skills Buddy") {
            // ContentView hosts the app sheets, centered on the whole window.
            ContentView(isSettingsPresented: $isSettingsPresented, settingsPage: $settingsPage, settingsScroll: settingsScroll)
                .frame(minWidth: 1000, minHeight: 620)
                .globalToast()
                // Outside the sheet host: sheets render there and need the library too.
                .environment(library)
                .environment(repoFinder)
                .blissTheme()
                .blissWindowChrome()
                .persistsWindowFrame(key: "skillsBuddy.windowFrame")
                .task {
                    BlissAppearance.applyDockIcon(from: DockIconOption.skillsBuddyOptions)
                    // The test bundle runs inside the app; don't scan or hit the network there.
                    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
                    await library.refresh()
                    await library.checkForUpdates()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 780)
        .commands {
            // ⌘, toggles settings mode on the main window instead of opening a
            // separate Settings window.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { isSettingsPresented.toggle() }
                    .keyboardShortcut(",")
            }
            // One window: ⌘N installs a skill (the title bar's Install) instead
            // of opening a second window.
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .newItem) {
                Button("Rescan and Check for Updates") {
                    Task {
                        await library.refresh()
                        await library.checkForUpdates()
                    }
                }
                .keyboardShortcut("r")
                .disabled(library.isBusy)
            }
        }
    }
}
