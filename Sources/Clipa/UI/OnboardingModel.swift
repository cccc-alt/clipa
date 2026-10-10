import Combine
import Foundation

enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcome, workflow, privacy, ready
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .welcome: return "欢迎"
        case .workflow: return "快速上手"
        case .privacy: return "隐私保护"
        case .ready: return "准备就绪"
        }
    }
}

/// No database, pasteboard or permission requests are needed to show the guide.
@MainActor
final class OnboardingModel: ObservableObject {
    static let currentVersion = 1
    let settings: SettingsStore
    @Published private(set) var step: OnboardingStep = .welcome
    @Published var skipConfidential = true
    @Published var skipSensitive = false
    @Published var skipPasswordManagers = true
    @Published var launchAtLogin = false
    @Published private(set) var loginError: String?
    @Published private(set) var finished = false
    var onFinish: (Bool) -> Void = { _ in }
    private let applyLogin: (Bool) -> String?
    private var initialPrivacy = [Bool]()
    private var initialLogin = false
    private var replaying = false
    private var attemptedLogin: Bool?

    init(settings: SettingsStore, applyLogin: ((Bool) -> String?)? = nil) {
        self.settings = settings
        self.applyLogin = applyLogin ?? { settings.setLaunchAtLogin($0) }
        begin()
    }

    var needsPresentation: Bool { settings.onboardingCompletedVersion < Self.currentVersion }

    func begin(replaying: Bool = false) {
        self.replaying = replaying
        step = replaying ? .welcome : OnboardingStep(rawValue: settings.onboardingStep) ?? .welcome
        skipConfidential = settings.skipConfidentialPasteboard
        skipSensitive = settings.skipSensitive
        skipPasswordManagers = settings.ignorePasswordManagers
        launchAtLogin = settings.launchAtLogin
        initialPrivacy = [skipConfidential, skipSensitive, skipPasswordManagers]
        initialLogin = launchAtLogin
        attemptedLogin = nil
        loginError = nil
        finished = false
    }

    func advance() {
        guard !finished, let next = OnboardingStep(rawValue: step.rawValue + 1) else { return }
        navigate(to: next)
    }
    func back() {
        guard !finished, let previous = OnboardingStep(rawValue: step.rawValue - 1) else { return }
        navigate(to: previous)
    }
    func navigate(to next: OnboardingStep) {
        guard !finished else { return }
        step = next
        if !replaying { settings.onboardingStep = next.rawValue }
    }

    func finish(acceptPendingLogin: Bool = false) {
        guard !finished, step == .ready else { return }
        // Retry a failed request, including when the user changes their choice
        // back to its original value after a partial system registration.
        if launchAtLogin != initialLogin || attemptedLogin != nil {
            let acceptPrevious = acceptPendingLogin && loginError != nil && attemptedLogin == launchAtLogin
            if !acceptPrevious {
                attemptedLogin = launchAtLogin
                loginError = applyLogin(launchAtLogin)
                if loginError != nil { return }
            }
        }
        // Only intentional changes are applied, so replay cannot overwrite
        // preferences changed elsewhere while the guide was visible.
        if skipConfidential != initialPrivacy[0] { settings.skipConfidentialPasteboard = skipConfidential }
        if skipSensitive != initialPrivacy[1] { settings.skipSensitive = skipSensitive }
        if skipPasswordManagers != initialPrivacy[2] { settings.ignorePasswordManagers = skipPasswordManagers }
        complete(openClipboard: true)
    }

    /// Closing or skipping is explicit dismissal; it does not apply draft
    /// privacy choices or prompt for login registration. Reopen in Settings.
    func skip() {
        guard !finished else { return }
        complete(openClipboard: false)
    }

    private func complete(openClipboard: Bool) {
        finished = true
        settings.didOnboard = true
        settings.onboardingCompletedVersion = max(settings.onboardingCompletedVersion, Self.currentVersion)
        settings.onboardingStep = 0
        onFinish(openClipboard)
    }
}
