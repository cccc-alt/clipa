import AppKit
import Foundation

enum OnboardingProbe {
    @MainActor
    static func run() -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        var checks = 0
        var failures = 0
        func check(_ ok: Bool, _ name: String) {
            checks += 1
            if !ok { failures += 1 }
            print("[ONBOARDING] \(ok ? "PASS" : "FAIL") \(name)")
        }
        let suite = "ClipaOnboardingProbe-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        var loginRequests = [Bool]()
        let model = OnboardingModel(settings: settings, applyLogin: { loginRequests.append($0); return nil })
        check(model.needsPresentation && model.step == .welcome, "fresh install needs the welcome screen")
        settings.didOnboard = true
        check(model.needsPresentation, "legacy panel-open flag does not suppress the new guide")
        model.back()
        check(model.step == .welcome, "back stops at the first step")
        model.advance()
        check(settings.onboardingStep == 1 && settings.onboardingCompletedVersion == 0, "progress persists without premature completion")
        let resumed = OnboardingModel(settings: SettingsStore(defaults: defaults))
        check(resumed.step == .workflow, "interrupted guide resumes at its last step")
        model.skipSensitive = !settings.skipSensitive
        check(!settings.skipSensitive, "privacy choices remain drafts until completion")
        var completions = [Bool]()
        model.onFinish = { completions.append($0) }
        model.skip()
        model.skip()
        check(completions == [false], "skip finishes once without opening history")
        check(!settings.skipSensitive && loginRequests.isEmpty, "skip leaves existing preferences and system registration untouched")
        check(!OnboardingModel(settings: SettingsStore(defaults: defaults)).needsPresentation, "dismissal survives relaunch without repeated prompts")
        model.begin(replaying: true)
        check(model.step == .welcome && !model.needsPresentation, "replay begins at welcome without resetting completion")
        model.navigate(to: .privacy)
        check(settings.onboardingStep == 0, "replay does not alter first-run resume state")
        settings.pauseRecording = true
        model.skipSensitive = true
        model.navigate(to: .ready)
        model.finish()
        model.finish()
        check(settings.skipSensitive && completions == [false, true], "completion applies choices and opens the panel only once")
        check(settings.pauseRecording && loginRequests.isEmpty, "completion preserves recording pause and unchanged login preference")

        settings.onboardingCompletedVersion = 0
        let failed = OnboardingModel(settings: settings, applyLogin: { _ in "需要在系统设置中批准" })
        failed.launchAtLogin = true
        failed.navigate(to: .ready)
        failed.finish()
        check(failed.loginError != nil && !failed.finished && failed.needsPresentation, "failed login registration keeps the guide open with recovery")
        failed.finish(acceptPendingLogin: true)
        check(failed.finished && !failed.needsPresentation, "optional login issue can be deferred explicitly")

        var attempts = 0
        let retry = OnboardingModel(settings: settings, applyLogin: { _ in
            attempts += 1
            return attempts == 1 ? "模拟失败" : nil
        })
        retry.launchAtLogin = true
        retry.navigate(to: .ready)
        retry.finish()
        retry.finish()
        check(attempts == 2 && retry.finished && retry.loginError == nil, "retry completes after registration recovers")

        settings.onboardingStep = 1000
        let invalid = OnboardingModel(settings: settings)
        check(invalid.step == .welcome, "invalid saved progress falls back safely")
        var closeCount = 0
        let controller = OnboardingWindowController(model: invalid)
        controller.onFinish = { _ in closeCount += 1 }
        controller.show(replaying: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        controller.window?.performClose(nil)
        check(closeCount == 1 && invalid.finished, "native close button dismisses through the same completion policy")

        // A real fresh-launch path must show UI before touching the encrypted
        // store; otherwise a Keychain prompt can hide the guide indefinitely.
        settings.onboardingCompletedVersion = 0
        settings.onboardingStep = 0
        let root = ClipStore.defaultBaseDirectoryOverride!
        check(!FileManager.default.fileExists(atPath: root.path), "isolated store has not been initialized")
        let delegate = AppDelegate(settings: settings)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let guide = app.windows.first { $0.title == "Clipa 新手引导" && $0.isVisible }
        check(guide != nil, "first launch actually presents the welcome window")
        check(!FileManager.default.fileExists(atPath: root.path), "welcome does not create or read clipboard storage")
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        check(!FileManager.default.fileExists(atPath: root.path), "quitting before completion does not initialize storage")
        guide?.orderOut(nil)
        check(settings.onboardingCompletedVersion == 0, "quitting mid-guide keeps resumable progress")
        print("[ONBOARDING] \(checks - failures)/\(checks) passed")
        return failures == 0 ? 0 : 1
    }
}
