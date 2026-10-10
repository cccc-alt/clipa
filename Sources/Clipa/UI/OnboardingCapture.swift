import AppKit

enum OnboardingCapture {
    @MainActor
    static func run(path: String, step: OnboardingStep, dark: Bool, loginError: Bool) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let suite = "ClipaOnboardingCapture-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = OnboardingModel(settings: SettingsStore(defaults: defaults), applyLogin: { _ in "需在系统设置 → 通用 → 登录项中批准。" })
        let controller = OnboardingWindowController(model: model)
        controller.show()
        model.navigate(to: step)
        if loginError { model.launchAtLogin = true; model.finish() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        guard let window = controller.window, let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
        do { try data.write(to: URL(fileURLWithPath: path)) }
        catch { print("[ONBOARDING-CAPTURE] failed: \(error)"); exit(1) }
        window.orderOut(nil)
        print("[ONBOARDING-CAPTURE] \(step.title) → \(path)")
    }
}
