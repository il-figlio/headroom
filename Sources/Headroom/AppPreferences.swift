import Foundation
import HeadroomCore
import SwiftUI

/// Opt-ins that gate work, not just visibility. Created first thing at launch
/// so the install check sees preferences as the previous launch left them.
final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()

    /// Off: nothing looks for or reads sign-ins (the monitor and Settings
    /// alike), no CLI runs, no quota request is made, and the monitor drops
    /// the cached token and deletes the cached readings.
    @Published private(set) var limitsEnabled: Bool
    /// "Use Claude Code's Keychain sign-in"; only has an effect while Limits is on.
    @Published private(set) var claudeKeychainEnabled: Bool
    /// Settled at launch; the welcome window shows at most once per install.
    let showWelcome: Bool
    var changed: (() -> Void)?

    private init() {
        // Screenshot mode never reads or writes preferences, or the Keychain.
        if ScreenshotExport.active {
            limitsEnabled = true; claudeKeychainEnabled = true; showWelcome = false
            QuotaSettings.useClaudeKeychain = false
            return
        }
        let defaults = UserDefaults.standard
        let state = Onboarding.migrate(defaults) {
            Onboarding.isExistingInstall(store: defaults, supportDirectory: HistoryStore.defaultDirectory)
        }
        limitsEnabled = state.limitsEnabled
        claudeKeychainEnabled = defaults.object(forKey: QuotaSettings.claudeKeychainKey) as? Bool ?? true
        showWelcome = state.showWelcome
        syncQuotaSettings()
    }

    /// Core reaches the Keychain only while both Limits and this setting are on.
    private func syncQuotaSettings() {
        QuotaSettings.useClaudeKeychain = !ScreenshotExport.active && limitsEnabled && claudeKeychainEnabled
    }

    func setLimitsEnabled(_ enabled: Bool) {
        guard enabled != limitsEnabled else { return }
        limitsEnabled = enabled
        if !ScreenshotExport.active { UserDefaults.standard.set(enabled, forKey: Onboarding.limitsKey) }
        syncQuotaSettings()
        changed?()
    }

    func setClaudeKeychainEnabled(_ enabled: Bool) {
        guard enabled != claudeKeychainEnabled else { return }
        claudeKeychainEnabled = enabled
        if !ScreenshotExport.active { UserDefaults.standard.set(enabled, forKey: QuotaSettings.claudeKeychainKey) }
        syncQuotaSettings()
        // After the sync, so no new read can reach the Keychain: a token
        // already read from it goes now, not at a fetch that may never come.
        if !enabled { QuotaSources.forgetKeychainSignIn() }
        changed?()
    }

    func welcomePresented() {
        guard !ScreenshotExport.active else { return }
        Onboarding.welcomeShown(UserDefaults.standard)
    }

    var limitsBinding: Binding<Bool> {
        Binding(get: { self.limitsEnabled }, set: { self.setLimitsEnabled($0) })
    }

    var claudeKeychainBinding: Binding<Bool> {
        Binding(get: { self.claudeKeychainEnabled }, set: { self.setClaudeKeychainEnabled($0) })
    }
}
