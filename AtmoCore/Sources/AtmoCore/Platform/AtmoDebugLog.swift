import Foundation

/// Opt-in stderr diagnostics for request failures the view models
/// otherwise swallow (they degrade to empty results by design). Set
/// `ATMO_DEBUG=1` in the environment to see them — used while bringing up
/// the Linux port, harmless elsewhere.
public enum AtmoDebugLog {
    nonisolated(unsafe) private static let enabled = ProcessInfo.processInfo.environment["ATMO_DEBUG"] != nil

    public static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        FileHandle.standardError.write(Data(("[atmo] " + message() + "\n").utf8))
    }
}
