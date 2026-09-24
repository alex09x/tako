import Foundation

extension UserDefaults {
    static var takoSuite: String? {
        #if DEBUG
        ProcessInfo.processInfo.environment["TAKO_USER_DEFAULTS_SUITE"]
        #else
        nil
        #endif
    }

    static var tako: UserDefaults {
        takoSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }
}
