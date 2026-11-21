/*
 * tako — Settings row choosing the sound for one activity event
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import SwiftUI

/// `activity-sound-<event>`: a menu of the macOS system sounds (and None),
/// which plays the sound picked, and ▶ to hear the current one again.
/// Accessibility: `DesktopSetting-activity-sound-<event>` (menu),
/// `…-play` (▶).
struct DesktopActivitySoundRow: View {
    let event: ActivityEvent
    @ObservedObject var preferences: DesktopPreferenceStore
    let palette: DesktopPalette

    private var key: String { event.soundKey }

    var body: some View {
        let copy = DesktopSettingCopy.of(key)
        let current = ActivitySounds.resolve(preferences.value(key), for: event) ?? ActivitySounds.none
        DesktopPrefRow(title: copy?.title ?? event.rawValue, detail: copy?.detail ?? "",
                       key: "\(key) · immediately", palette: palette) {
            HStack(spacing: 8) {
                Picker("", selection: Binding(get: { current }, set: choose)) {
                    Text("None").tag(ActivitySounds.none)
                    Divider()
                    ForEach(ActivitySounds.names, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 130)
                .accessibilityIdentifier(DesktopRegistryRow.identifier(key))
                Button { if current != ActivitySounds.none { ActivityAlert.play(current) } } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(DesktopButtonStyle(palette: palette))
                .disabled(current == ActivitySounds.none)
                .help("Play")
                .accessibilityLabel("Play \(copy?.title ?? event.rawValue) sound")
                .accessibilityIdentifier("\(DesktopRegistryRow.identifier(key))-play")
                if preferences.isOverridden(key) {
                    Button { preferences.reset(key) } label: { Text("↺") }
                        .buttonStyle(.plain).foregroundStyle(Color(palette.muted))
                        .help("Restore Default")
                        .accessibilityIdentifier("DesktopSettingReset-\(key)")
                }
            }
        }
        .id(DesktopRegistryRow.identifier(key))
    }

    /// Saved, and heard at once.
    private func choose(_ sound: String) {
        preferences.set(key, sound)
        if sound != ActivitySounds.none { ActivityAlert.play(sound) }
    }
}
