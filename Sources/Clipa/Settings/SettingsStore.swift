import AppKit
import Combine
import CryptoKit
import Foundation
import ServiceManagement

enum LaunchAtLoginAction: Equatable {
    case none
    case refresh
    case register
    case leaveForUser
    case needsApproval
}

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore(defaults: .standard)

    private enum Keys {
        static let historyLimit = "historyLimit"
        static let autoPauseAtLimit = "autoPauseAtLimit"
        static let autoPausedByLimit = "autoPausedByLimit"
        static let pauseRecording = "pauseRecording"
        static let ignorePasswordManagers = "ignorePasswordManagers"
        static let skipSensitive = "skipSensitive"
        static let skipConfidentialPasteboard = "skipConfidentialPasteboard"
        static let ignoredApps = "ignoredApps"
        static let launchAtLogin = "launchAtLogin"
        static let launchAtLoginSynced = "launchAtLoginSynced"

        static let launchAtLoginSyncedBuild = "launchAtLoginSyncedBuild"
        static let didOnboard = "didOnboard"
        static let secureEraseHistoryOnClear = "secureEraseHistoryOnClear"

        static let apiControlEnabled = "apiControlEnabled"
    }

    let defaults: UserDefaults

    private(set) var historyLimitScope: HistoryLimitScope = .global

    private var isAdoptingHistoryLimit = false

    @Published var historyLimit: Int {
        didSet {
            guard !isAdoptingHistoryLimit else { return }
            persistHistoryLimit(historyLimit)
            if historyLimit > oldValue && autoPausedByLimit {
                pauseRecording = false
                autoPausedByLimit = false
            }
        }
    }

    enum HistoryLimitScope: Equatable {

        case global

        case workspace(UUID)
    }

    var globalHistoryLimit: Int {
        defaults.object(forKey: Keys.historyLimit) as? Int ?? 500
    }

    func adoptHistoryLimit(_ value: Int, scope: HistoryLimitScope) {
        historyLimitScope = scope
        guard historyLimit != value else { return }
        isAdoptingHistoryLimit = true
        historyLimit = value
        isAdoptingHistoryLimit = false
    }

    var workspaceHistoryLimitWriter: ((UUID, Int) -> Void)?

    private func persistHistoryLimit(_ value: Int) {
        switch historyLimitScope {
        case .global:
            defaults.set(value, forKey: Keys.historyLimit)
        case .workspace(let id):
            guard let writer = workspaceHistoryLimitWriter else {
                defaults.set(value, forKey: Keys.historyLimit)
                return
            }
            writer(id, value)
        }
    }

    static func historyLimitDeletionCount(
        current: Int,
        requested: Int,
        rowCount: Int
    ) -> Int? {
        let shrinks = requested > 0 && (current == 0 || requested < current)
        guard shrinks else { return nil }
        let excess = rowCount - requested
        return excess > 0 ? excess : nil
    }
    @Published var pauseRecording: Bool {
        didSet { defaults.set(pauseRecording, forKey: Keys.pauseRecording) }
    }

    @Published var autoPauseAtLimit: Bool {
        didSet { defaults.set(autoPauseAtLimit, forKey: Keys.autoPauseAtLimit) }
    }
    @Published var ignorePasswordManagers: Bool {
        didSet { defaults.set(ignorePasswordManagers, forKey: Keys.ignorePasswordManagers) }
    }
    @Published var skipSensitive: Bool {
        didSet { defaults.set(skipSensitive, forKey: Keys.skipSensitive) }
    }

    @Published var skipConfidentialPasteboard: Bool {
        didSet {
            defaults.set(
                skipConfidentialPasteboard,
                forKey: Keys.skipConfidentialPasteboard
            )
        }
    }

    @Published var secureEraseHistoryOnClear: Bool {
        didSet {
            defaults.set(
                secureEraseHistoryOnClear,
                forKey: Keys.secureEraseHistoryOnClear
            )
        }
    }

    @Published var apiControlEnabled: Bool {
        didSet {
            defaults.set(apiControlEnabled, forKey: Keys.apiControlEnabled)
        }
    }
    @Published var ignoredApps: [String] {
        didSet {

            let normalized = BundleIDNormalizer.normalize(ignoredApps)
            if normalized != ignoredApps {

                ignoredApps = normalized
            }
            if let data = try? JSONEncoder().encode(normalized) {
                defaults.set(data, forKey: Keys.ignoredApps)
            }
        }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
            guard !isApplyingLaunchAtLogin else { return }
            applyLaunchAtLogin(launchAtLogin)
        }
    }

    private var isApplyingLaunchAtLogin = false

    @discardableResult
    func setLaunchAtLogin(_ enable: Bool) -> String? {
        isApplyingLaunchAtLogin = true
        launchAtLogin = enable
        isApplyingLaunchAtLogin = false
        return applyLaunchAtLogin(enable)
    }
    @Published var didOnboard: Bool {
        didSet { defaults.set(didOnboard, forKey: Keys.didOnboard) }
    }

    @Published var autoPausedByLimit = false {
        didSet {
            defaults.set(autoPausedByLimit, forKey: Keys.autoPausedByLimit)
        }
    }

    init(
        defaults: UserDefaults,
    ) {
        self.defaults = defaults
        let d = defaults
        apiControlEnabled = d.object(forKey: Keys.apiControlEnabled) as? Bool ?? false
        historyLimit = d.object(forKey: Keys.historyLimit) as? Int ?? 500
        autoPauseAtLimit = d.object(forKey: Keys.autoPauseAtLimit) as? Bool ?? false
        pauseRecording = d.object(forKey: Keys.pauseRecording) as? Bool ?? false
        autoPausedByLimit =
            d.object(forKey: Keys.autoPausedByLimit) as? Bool ?? false
        ignorePasswordManagers = d.object(forKey: Keys.ignorePasswordManagers) as? Bool ?? true
        skipSensitive = d.object(forKey: Keys.skipSensitive) as? Bool ?? false
        skipConfidentialPasteboard =
            d.object(forKey: Keys.skipConfidentialPasteboard) as? Bool ?? true
        secureEraseHistoryOnClear =
            d.object(forKey: Keys.secureEraseHistoryOnClear) as? Bool ?? false
        let storedIgnoredApps = (try? JSONDecoder().decode(
            [String].self,
            from: d.data(forKey: Keys.ignoredApps) ?? Data()
        )) ?? []
        let normalizedIgnoredApps = BundleIDNormalizer.normalize(storedIgnoredApps)
        ignoredApps = normalizedIgnoredApps

        if normalizedIgnoredApps != storedIgnoredApps,
           let data = try? JSONEncoder().encode(normalizedIgnoredApps) {
            d.set(data, forKey: Keys.ignoredApps)
        }
        launchAtLogin = d.object(forKey: Keys.launchAtLogin) as? Bool ?? false
        didOnboard = d.object(forKey: Keys.didOnboard) as? Bool ?? false

        if !pauseRecording {
            autoPausedByLimit = false
        }
    }

    static let defaultPasswordManagerBundleIDs = [

        "com.agilebits.onepassword7",
        "com.agilebits.onepassword",
        "com.1password.1password",
        "com.1password.1password-setapp",

        "com.bitwarden.desktop",
        "com.joeblau.bitwarden",

        "org.keepassxc.keepassxc",

        "com.lastpass.lastpass",

        "com.dashlane.dashlane",

        "com.apple.passwords",
        "com.apple.keychainaccess"
    ]

    var autoIgnoredApps: [String] {
        guard ignorePasswordManagers else { return [] }
        return BundleIDNormalizer.normalize(Self.defaultPasswordManagerBundleIDs)
    }

    var effectiveIgnoredApps: [String] {
        var list = ignoredApps
        list.append(contentsOf: autoIgnoredApps)
        return BundleIDNormalizer.normalize(list)
    }

    func isIgnored(bundleID: String?) -> Bool {
        guard let bundleID = bundleID,
              let normalized = BundleIDNormalizer.normalize(bundleID) else {
            return false
        }
        return effectiveIgnoredApps.contains(normalized)
    }

    static func currentBuildIdentity() -> String? {
        guard let url = Bundle.main.executableURL,
              let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }
            .joined()
    }

    private var syncedBuildIdentity: String? {
        defaults.string(forKey: Keys.launchAtLoginSyncedBuild)
    }

    static func launchAtLoginAction(
        status: SMAppService.Status,
        wantsLoginItem: Bool,
        identityMatchesRegistration: Bool
    ) -> LaunchAtLoginAction {
        guard wantsLoginItem else { return .none }
        switch status {
        case .enabled:
            return identityMatchesRegistration ? .none : .refresh
        case .notRegistered, .notFound:
            return identityMatchesRegistration ? .leaveForUser : .register
        case .requiresApproval:
            return .needsApproval
        @unknown default:
            return .none
        }
    }

    private func finishRegistration(_ service: SMAppService) -> String? {
        if service.status == .enabled,
           let identity = syncedBuildIdentity,
           identity == Self.currentBuildIdentity() {
            return nil
        }

        if service.status == .enabled {
            try? service.unregister()
        }
        do {
            try service.register()
            switch service.status {
            case .enabled:
                defaults.set(true, forKey: Keys.launchAtLoginSynced)
                if let identity = Self.currentBuildIdentity() {
                    defaults.set(identity, forKey: Keys.launchAtLoginSyncedBuild)
                }
                return nil
            case .requiresApproval:
                return "需在 系统设置 → 通用 → 登录项 中批准"
            default:
                defaults.removeObject(forKey: Keys.launchAtLoginSynced)
                return "注册失败：请确认 Clipa 位于 /Applications 后重试"
            }
        } catch {
            defaults.removeObject(forKey: Keys.launchAtLoginSynced)
            NSLog("Clipa launch-at-login error: \(error.localizedDescription)")
            return error.localizedDescription
        }
    }

    @discardableResult
    func applyLaunchAtLogin(_ enable: Bool) -> String? {
        let service = SMAppService.mainApp
        if enable {
            return finishRegistration(service)
        }
        switch service.status {
        case .enabled, .requiresApproval:
            do {
                try service.unregister()
            } catch {
                NSLog(
                    "Clipa launch-at-login error: \(error.localizedDescription)"
                )
                return error.localizedDescription
            }
        case .notRegistered, .notFound:
            break
        @unknown default:
            break
        }
        defaults.removeObject(forKey: Keys.launchAtLoginSynced)
        defaults.removeObject(forKey: Keys.launchAtLoginSyncedBuild)
        return nil
    }

    @discardableResult
    func reconcileLaunchAtLogin() -> String? {
        let service = SMAppService.mainApp
        if launchAtLogin {
            let identity = Self.currentBuildIdentity()
            let matches = identity != nil && identity == syncedBuildIdentity
            switch Self.launchAtLoginAction(
                status: service.status,
                wantsLoginItem: true,
                identityMatchesRegistration: matches
            ) {
            case .none:
                return nil
            case .refresh, .register:

                let path = Bundle.main.bundlePath
                let installed = path.hasPrefix("/Applications/")
                    || path.hasPrefix(NSHomeDirectory() + "/Applications/")
                guard installed else {
                    return "未注册：请把 Clipa 放入「应用程序」文件夹后运行"
                }
                return finishRegistration(service)
            case .leaveForUser:
                return "系统登录项中当前未启用；可能是你在系统设置里关掉了。"
                    + "如需自启，请关闭后再打开此开关"
            case .needsApproval:
                return "需在 系统设置 → 通用 → 登录项 中批准"
            }
        } else {
            defaults.removeObject(forKey: Keys.launchAtLoginSynced)
            defaults.removeObject(forKey: Keys.launchAtLoginSyncedBuild)
            if service.status == .enabled {
                return applyLaunchAtLogin(false)
            }
            return nil
        }
    }
}
