/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit

extension UserDefaults {
    private static let customIconKeyOld = "CustomTakoIcon"
    private static let customIconKeyNew = "CustomTakoIcon2"

    var appIcon: AppIcon? {
        get {
            // Always remove our old pre-docktileplugin values.
            defer {
                removeObject(forKey: Self.customIconKeyOld)
            }

            // Check if we have the new key for our dock tile plugin format.
            guard let data = data(forKey: Self.customIconKeyNew) else {
                return nil
            }
            return try? JSONDecoder().decode(AppIcon.self, from: data)
        }

        set {
            guard let newData = try? JSONEncoder().encode(newValue) else {
                return
            }

            set(newData, forKey: Self.customIconKeyNew)
        }
    }
}
