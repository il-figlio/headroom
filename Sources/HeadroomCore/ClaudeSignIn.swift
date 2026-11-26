import Foundation
#if canImport(Security)
import Security
#endif
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

/// Quota switches the app layer owns. Core defaults to no Keychain access,
/// so nothing (tests included) reaches the login Keychain unless the app
/// turns it on: Limits on and "Use Claude Code's Keychain sign-in" on.
public enum QuotaSettings {
    /// Persisted "Use Claude Code's Keychain sign-in" preference; on when unset.
    public static let claudeKeychainKey = "limitsUseClaudeKeychain"
    private static let lock = NSLock()
    private static var keychain = false

    public static var useClaudeKeychain: Bool {
        get { lock.lock(); defer { lock.unlock() }; return keychain }
        set { lock.lock(); keychain = newValue; lock.unlock() }
    }
}

/// Metadata about Claude Code's Keychain item. Never carries the secret.
public struct KeychainItemInfo: Equatable, Sendable {
    public var modified: Date?
    public init(modified: Date?) { self.modified = modified }
}

/// Outcome of a non-interactive secret read.
public enum KeychainSecret: Equatable, Sendable {
    case found(Data)
    case missing
    /// The item exists but reading it would need a prompt (or consent was refused).
    case needsPrompt
    case failed(OSStatus)
}

/// Claude Code's "Claude Code-credentials" login-Keychain item, behind a
/// protocol so tests never touch the real Keychain. Neither call may show UI.
public protocol ClaudeKeychain: Sendable {
    /// Attributes only (existence and modification date): no secret, no UI.
    func itemInfo() -> KeychainItemInfo?
    /// The secret, read with UI disabled; fails instead of prompting.
    func readSecret() -> KeychainSecret
}

struct SystemClaudeKeychain: ClaudeKeychain {
    static let service = "Claude Code-credentials"
    typealias CopyMatching = @Sendable (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    var copyMatching: CopyMatching = { SecItemCopyMatching($0, $1) }

    /// Both no-UI switches: `LAContext.interactionNotAllowed` is the modern
    /// one, but alone it doesn't stop the legacy login Keychain's
    /// Allow/Deny sheet, which `kSecUseAuthenticationUIFail` does.
    static func query(returning key: CFString) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            key as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        #if canImport(LocalAuthentication)
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        #endif
        return query
    }

    func itemInfo() -> KeychainItemInfo? {
        var item: CFTypeRef?
        guard copyMatching(Self.query(returning: kSecReturnAttributes) as CFDictionary, &item) == errSecSuccess
        else { return nil }
        let attributes = item as? [String: Any]
        return KeychainItemInfo(modified: attributes?[kSecAttrModificationDate as String] as? Date)
    }

    func readSecret() -> KeychainSecret {
        var item: CFTypeRef?
        let status = copyMatching(Self.query(returning: kSecReturnData) as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return .failed(status) }
            return .found(data)
        case errSecItemNotFound: return .missing
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled, errSecNoAccessForItem:
            return .needsPrompt
        default: return .failed(status)
        }
    }
}

/// What a sign-in change looks like from the outside: file modification
/// times and the Keychain item's modification date. Gathered without
/// opening a file or reading a secret. A cached token is reused only while
/// this is unchanged since it was read, and a credential failure is retried
/// early once it changes.
struct SignInStamp: Equatable, Sendable {
    var claudeFile: Date?
    var anteFile: Date?
    var keychain: KeychainItemInfo?
}
