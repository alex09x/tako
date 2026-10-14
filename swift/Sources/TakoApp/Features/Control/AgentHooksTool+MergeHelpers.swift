/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation

extension AgentHooksTool {
    static func hasDisabledMatcherHook(in container: Any?, commandKey: String) -> Bool {
        guard let rawArray = container as? [Any] else { return false }
        for item in rawArray {
            guard let dict = item as? [String: Any] else { continue }
            let groupDisabled = (dict["enabled"] as? Bool) == false
            if let innerHooks = dict["hooks"] as? [[String: Any]] {
                for hook in innerHooks {
                    if (hook["command"] as? String)?.contains(commandKey) == true {
                        let hookDisabled = (hook["enabled"] as? Bool) == false
                        if groupDisabled || hookDisabled {
                            return true
                        }
                    }
                }
            }
        }
        return false
    }

    static func hasDisabledDirectHook(in container: Any?, commandKey: String) -> Bool {
        guard let rawArray = container as? [Any] else { return false }
        for item in rawArray {
            guard let dict = item as? [String: Any] else { continue }
            if (dict["command"] as? String)?.contains(commandKey) == true {
                if (dict["enabled"] as? Bool) == false {
                    return true
                }
            }
        }
        return false
    }

    static func mergeMatcherGroup(
        in existing: Any?,
        adding newGroup: [String: Any],
        commandKey: String,
        replacePattern: String? = nil
    ) -> [[String: Any]]? {
        guard let existing else {
            return [newGroup]
        }
        guard let rawArray = existing as? [Any] else {
            return nil
        }
        guard let newHook = (newGroup["hooks"] as? [[String: Any]])?.first else {
            return nil
        }
        var groups: [[String: Any]] = []
        var takoHookHandled = false

        for item in rawArray {
            guard let dict = item as? [String: Any] else {
                return nil
            }
            // Migrate legacy flat Tako entry (no "hooks" array, but has takoctl command)
            if let cmd = dict["command"] as? String, cmd.contains("takoctl status"), dict["hooks"] == nil {
                continue
            }
            // Matcher groups must contain a valid "hooks" array of dictionaries
            guard let hooksField = dict["hooks"], let innerList = hooksField as? [Any] else {
                return nil
            }

            var updatedGroup = dict
            var updatedHooks: [[String: Any]] = []

            for hookItem in innerList {
                guard let hookDict = hookItem as? [String: Any] else {
                    return nil
                }
                let cmd = hookDict["command"] as? String ?? ""
                let isOwnedTako = cmd.contains(commandKey) ||
                    (replacePattern != nil && !replacePattern!.isEmpty && cmd.contains(replacePattern!))

                if isOwnedTako {
                    if !takoHookHandled {
                        updatedHooks.append(newHook)
                        takoHookHandled = true
                    }
                } else {
                    // Sibling user hook: preserve byte-semantically
                    updatedHooks.append(hookDict)
                }
            }

            if !updatedHooks.isEmpty {
                updatedGroup["hooks"] = updatedHooks
                groups.append(updatedGroup)
            }
        }

        if !takoHookHandled {
            groups.append(newGroup)
        }
        return groups
    }

    static func mergeDirectHook(
        in existing: Any?,
        adding newHook: [String: Any],
        commandKey: String
    ) -> [[String: Any]]? {
        guard let existing else {
            return [newHook]
        }
        guard let rawArray = existing as? [Any] else {
            return nil
        }
        var list: [[String: Any]] = []
        for item in rawArray {
            guard let dict = item as? [String: Any] else {
                return nil
            }
            list.append(dict)
        }
        let alreadyHasActiveKey = list.contains { item in
            if (item["enabled"] as? Bool) == false { return false }
            return (item["command"] as? String)?.contains(commandKey) == true
        }
        if !alreadyHasActiveKey {
            list.append(newHook)
        }
        return list
    }
}
