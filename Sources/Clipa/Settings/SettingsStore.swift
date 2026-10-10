import AppKit
import Combine
import CryptoKit
import Foundation
import ServiceManagement

/// 「开机自启」下一步动作（见 `SettingsStore.launchAtLoginAction`）。
enum LaunchAtLoginAction: Equatable {
    case none          // 登记在，且绑定当前 bundle
    case refresh       // 登记在，但绑定的是旧 bundle —— 重登记刷新
    case register      // 没登记，且应当登记（重装后登记失效）
    case leaveForUser  // 没登记，指纹没变 —— 视作用户在系统设置里关的，不抢
    case needsApproval // 系统要求用户去系统设置批准
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
        /// 办登记时那个 bundle 的指纹（可执行文件 SHA-256）。与当前指纹不一致
        /// = 重装过 = 系统里的登记指向旧代码，需要重登记（见 `currentBuildIdentity`）。
        static let launchAtLoginSyncedBuild = "launchAtLoginSyncedBuild"
        static let didOnboard = "didOnboard"
        static let onboardingCompletedVersion = "onboardingCompletedVersion"
        static let onboardingStep = "onboardingStep"
        static let secureEraseHistoryOnClear = "secureEraseHistoryOnClear"
        // `apiExportEnabled` / `apiExportIncludeSensitive`（M1 只读导出的两个开关）
        // 随功能于 2026-09-26 移除。用户 defaults 里可能还留着这两个键，不读就无害。
        static let apiControlEnabled = "apiControlEnabled"
    }

    let defaults: UserDefaults

    /// Where the live `historyLimit` is written. See `HistoryLimitScope`.
    private(set) var historyLimitScope: HistoryLimitScope = .global
    /// Set while a workspace switch adopts another workspace's value, so the
    /// `didSet` below does not write it back to the workspace being left.
    private var isAdoptingHistoryLimit = false

    /// The live history limit of the active workspace. 0 means "无限制".
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

    /// The limit is per workspace, so the live value has to be written
    /// somewhere that follows the active one.
    enum HistoryLimitScope: Equatable {
        /// The historical global key in `UserDefaults`. Used by the default
        /// workspace (so an upgrade or a rollback changes nothing for an
        /// existing install), by tests, and by any single-store caller.
        case global
        /// A named workspace's own entry in the workspace registry.
        case workspace(UUID)
    }

    /// The shared value the default workspace uses, and the fallback for a
    /// workspace that never stored its own. Read straight from `UserDefaults`
    /// rather than from the (possibly adopted) live value.
    var globalHistoryLimit: Int {
        defaults.object(forKey: Keys.historyLimit) as? Int ?? 500
    }

    /// Points the live limit at another workspace. `value` is that workspace's
    /// effective limit (its own, or the shared fallback); nothing is written
    /// back to the workspace being left.
    func adoptHistoryLimit(_ value: Int, scope: HistoryLimitScope) {
        historyLimitScope = scope
        guard historyLimit != value else { return }
        isAdoptingHistoryLimit = true
        historyLimit = value
        isAdoptingHistoryLimit = false
    }

    /// Where a workspace-scoped limit is written. The app points this at the
    /// workspace registry; it stays `nil` in tests and in any single-store
    /// caller, which keeps every other install and the whole test suite on the
    /// plain shared key.
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

    /// How many rows lowering the limit to `requested` would delete right now.
    ///
    /// `nil` means the change does not shrink the history (raising it, picking
    /// "unlimited", or having nothing to delete), which the settings page
    /// applies without asking.
    ///
    /// `current == 0` means *unlimited*, so it has no numeric bound to compare
    /// against: switching from unlimited to a finite limit shrinks the history
    /// exactly like lowering a numeric limit. Treating it as "0 rows allowed"
    /// (the old `requested < current` test) made that direction silently skip
    /// the confirmation and delete the whole overflow on the next capture.
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
    /// When enabled, recording pauses automatically once the
    /// history reaches the configured limit (does NOT pause immediately).
    @Published var autoPauseAtLimit: Bool {
        didSet { defaults.set(autoPauseAtLimit, forKey: Keys.autoPauseAtLimit) }
    }
    @Published var ignorePasswordManagers: Bool {
        didSet { defaults.set(ignorePasswordManagers, forKey: Keys.ignorePasswordManagers) }
    }
    @Published var skipSensitive: Bool {
        didSet { defaults.set(skipSensitive, forKey: Keys.skipSensitive) }
    }
    /// Honour the source app's own pasteboard marker instead of relying on a
    /// bundle-id list: password managers, browser password fields and terminal
    /// secret prompts mark their copy as concealed (`org.nspasteboard.*`), and
    /// apps that copy content programmatically for a one-off paste mark it
    /// transient. Defaults on — a copy the source app called secret should not
    /// reach the history because its tool happens not to be on our list.
    @Published var skipConfidentialPasteboard: Bool {
        didSet {
            defaults.set(
                skipConfidentialPasteboard,
                forKey: Keys.skipConfidentialPasteboard
            )
        }
    }
    /// When enabled, "clear history" asks SQLite to overwrite deleted cells,
    /// truncates WAL, and runs VACUUM. Slower, but reduces recoverable
    /// remnants in the database file.
    @Published var secureEraseHistoryOnClear: Bool {
        didSet {
            defaults.set(
                secureEraseHistoryOnClear,
                forKey: Keys.secureEraseHistoryOnClear
            )
        }
    }
    /// 本地控制面（M2 socket）：允许本机其它程序**按令牌与作用域**查询、复制、写入。
    ///
    /// **默认关闭**，这是设计里的硬规则之一：打开它意味着"任何以你的身份运行的程序，
    /// 只要拿着令牌，就能按作用域读你的剪贴板历史（私密条目永远取不到）"。所以它必须
    /// 由人显式打开一次，而不是"装好就有"。
    ///
    /// 它现在是本地接口**唯一**的一档：原先还有一个「只读导出」（写一份脱敏快照到盘上，
    /// 任何同 uid 进程 `cat` 就能读、不需要令牌也不进审计），2026-09-26 随 M1 移除。
    @Published var apiControlEnabled: Bool {
        didSet {
            defaults.set(apiControlEnabled, forKey: Keys.apiControlEnabled)
        }
    }
    @Published var ignoredApps: [String] {
        didSet {
            // Normalize on every write so no caller can introduce a duplicate
            // or a differently-cased entry, then persist that same value.
            let normalized = BundleIDNormalizer.normalize(ignoredApps)
            if normalized != ignoredApps {
                // Assigning inside didSet does not re-enter the observer.
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

    /// Set by `setLaunchAtLogin` so the `didSet` above does not run the
    /// registration a second time.
    private var isApplyingLaunchAtLogin = false

    /// Flips the login item and hands back the system's answer.
    ///
    /// The `didSet` keeps the preference and the registration in step for every
    /// other writer, but it throws the outcome away — and "needs approval" or
    /// "must live in /Applications" is exactly what the menu bar has to tell the
    /// user, since a silent failure reads as a broken switch.
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

    // Independent of the old flag, which only meant that the clipboard panel
    // had opened once. Existing installations see the actual guide once too.
    @Published var onboardingCompletedVersion: Int {
        didSet { defaults.set(onboardingCompletedVersion, forKey: Keys.onboardingCompletedVersion) }
    }
    var onboardingStep: Int {
        get { defaults.integer(forKey: Keys.onboardingStep) }
        set { defaults.set(newValue, forKey: Keys.onboardingStep) }
    }

    /// True while the active pause came from the history limit, so raising the
    /// limit — or making room — can auto-resume without ever clearing a pause
    /// the user asked for.
    ///
    /// Persisted on purpose. Reconstructing it as
    /// `autoPauseAtLimit && pauseRecording` misread a *manual* pause as an
    /// automatic one, and the launch-time resume then silently switched
    /// recording back on for someone who had paused it deliberately.
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
        // Converge the stored list once, so entries written by older versions
        // or edited by hand match the way Clipa compares them.
        if normalizedIgnoredApps != storedIgnoredApps,
           let data = try? JSONEncoder().encode(normalizedIgnoredApps) {
            d.set(data, forKey: Keys.ignoredApps)
        }
        launchAtLogin = d.object(forKey: Keys.launchAtLogin) as? Bool ?? false
        didOnboard = d.object(forKey: Keys.didOnboard) as? Bool ?? false
        onboardingCompletedVersion = d.integer(forKey: Keys.onboardingCompletedVersion)

        // An auto-pause flag is only meaningful while recording is paused.
        if !pauseRecording {
            autoPausedByLimit = false
        }
    }

    // MARK: - Ignore rules

    /// Password managers skipped automatically while the toggle is on. The
    /// list is intentionally conservative: only apps whose job is holding
    /// secrets, and only ids that are actually shipped by those products.
    /// Command-line companions are excluded — they never write the pasteboard.
    static let defaultPasswordManagerBundleIDs = [
        // 1Password 7 / 8 / Setapp
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword",
        "com.1password.1password",
        "com.1password.1password-setapp",
        // Bitwarden desktop (direct + App Store builds)
        "com.bitwarden.desktop",
        "com.joeblau.bitwarden",
        // KeePassXC
        "org.keepassxc.keepassxc",
        // LastPass
        "com.lastpass.lastpass",
        // Dashlane
        "com.dashlane.dashlane",
        // Apple: Passwords.app and Keychain Access
        "com.apple.passwords",
        "com.apple.keychainaccess"
    ]

    /// The password-manager defaults that are actually in effect, so the
    /// settings pane can show the user what is being skipped for them.
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

    // MARK: - Login item repair

    /// 当前可执行文件的 SHA-256 指纹。本应用是 ad-hoc 签名，每次重新构建/
    /// 重装的 CDHash 都不同 —— 所以这个指纹能可靠回答一个问题：
    /// **"系统里那条登录项登记，是给现在这个 bundle 办的吗？"**
    /// 答案是否，登记就指向旧代码，登录时启动会静默失败
    /// （2026-10-01 修复的 bug：菜单显示已开启、系统记录 enabled，却从不启动）。
    static func currentBuildIdentity() -> String? {
        guard let url = Bundle.main.executableURL,
              let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }
            .joined()
    }

    /// 办登记那一刻记下的 bundle 指纹。与当前指纹不一致 = 重装过。
    private var syncedBuildIdentity: String? {
        defaults.string(forKey: Keys.launchAtLoginSyncedBuild)
    }

    /// 「开机自启」此刻该做什么。**纯函数**，自检把整个决策矩阵钉死。
    ///
    /// 关键的区分：`.notRegistered` 既可能是"用户在系统设置里关了"
    /// （不能抢回来，否则会跟用户打架），也可能是"重装后登记失效"（必须修）。
    /// 区分依据是 bundle 指纹：指纹没变而登记没了，按用户主动关闭处理；
    /// 指纹变了，说明装了新版，按失效修复。
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

    /// 把登记办成"绑定当前 bundle"的状态：旧登记先摘、再登记、
    /// 成功后把当前指纹记下来。开关打开与启动自愈都走这里。
    private func finishRegistration(_ service: SMAppService) -> String? {
        if service.status == .enabled,
           let identity = syncedBuildIdentity,
           identity == Self.currentBuildIdentity() {
            return nil
        }
        // 旧 bundle 的登记指向旧签名，先摘掉再登记，保证记录绑定当前代码。
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

    /// Registers/unregisters Clipa as a login item. Returns a user-facing
    /// message when the system needs approval or when registration fails.
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

    /// Called at startup and when the user asks to re-verify.
    ///
    /// 2026-10-01 重写：旧版看到 `.enabled` 就认为万事大吉 —— 但登记可能绑定的是
    /// **重装前的旧 bundle**（ad-hoc 签名每次构建的 CDHash 都不同），登录启动会
    /// 静默失败，而偏好与系统状态双双显示正常，bug 永远不会自愈。现在由
    /// `launchAtLoginAction` 按指纹判断：重装过就重登记刷新记录；指纹没变而
    /// 登记没了，才按"用户在系统设置里关了"处理，不跟用户打架。
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
                // P2 修复（2026-10-03）：~/Applications 也是合法安装位置——
                // 旧判断写死 /Applications，装在个人目录的用户重装后永远
                // 无法自愈。
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
