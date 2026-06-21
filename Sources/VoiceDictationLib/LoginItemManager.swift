import Foundation
import ServiceManagement

/// Manages registering VoiceDictation as a macOS "open at login" item.
///
/// The original code called `SMAppService.mainApp.register()` on launch.
/// Run from the SwiftPM `.build` dev directory, the binary is ad-hoc signed
/// and its signature changes on every rebuild, so macOS's Background Task
/// Management treated each rebuild as a brand-new login item and never
/// removed the old ones. They piled up and macOS launched all of them at
/// login — the root cause of the duplicate instances.
///
/// This type only ever touches the login-item database when running from an
/// installed, stably-signed `.app` bundle, and exposes it as an explicit
/// user preference instead of registering silently.
public final class LoginItemManager {
    public static let shared = LoginItemManager()
    private init() {}

    /// True when running from an installed `.app` bundle rather than the dev
    /// build (`.build/.../debug/VoiceDictation`) or a test runner. Only an
    /// installed bundle has a stable signing identity, so only then is it
    /// safe to register a login item.
    public static func isRunningFromAppBundle(
        executablePath: String = Bundle.main.executablePath ?? CommandLine.arguments.first ?? ""
    ) -> Bool {
        executablePath.contains(".app/Contents/MacOS/")
    }

    /// Whether the OS currently has the app registered to open at login.
    public var isRegistered: Bool {
        guard #available(macOS 13.0, *) else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    /// Reconciles the OS login-item registration to `enabled`.
    ///
    /// No-op (returns `false`) when running from the dev build or a test
    /// runner, so rebuilding never accumulates stale login items.
    /// - Returns: `true` if a system change was successfully made or already
    ///   in the desired state; `false` if skipped or it failed.
    @discardableResult
    public func setEnabled(_ enabled: Bool) -> Bool {
        guard #available(macOS 13.0, *) else { return false }
        guard LoginItemManager.isRunningFromAppBundle() else { return false }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            return true
        } catch {
            return false
        }
    }

    /// Applies the user's stored preference to the OS at launch.
    public func syncWithStoredPreference() {
        setEnabled(PreferencesManager.shared.launchAtLogin)
    }
}
