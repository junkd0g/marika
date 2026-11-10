#if DEBUG
import Foundation

/// A native test bundle can carry fixture settings without replacing its executable with a shell wrapper.
enum DebugFixtureSettings {
    static func value(_ name: String) -> String? {
        if let value = ProcessInfo.processInfo.environment[name] { return value }
        guard Bundle.main.bundleIdentifier?.hasPrefix("app.marika.testing.") == true else { return nil }
        return (Bundle.main.object(forInfoDictionaryKey: "MarikaTesting") as? [String: String])?[name]
    }
}
#endif
