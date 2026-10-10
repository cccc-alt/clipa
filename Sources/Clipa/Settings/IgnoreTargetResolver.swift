import AppKit
import Foundation

/// Outcome of asking "which app does the user mean by 当前应用?".
enum IgnoreTargetResolution: Equatable {
    case resolved(bundleID: String, name: String)
    /// Clipa is frontmost and no external app has been seen yet, so any answer
    /// would be a guess. Callers must refuse instead of guessing.
    case unavailable
    /// The app is known but has no bundle identifier (plain executables).
    case missingBundleID(name: String)

    /// Explanation to show when nothing was added; `nil` when it worked.
    var failureMessage: String? {
        switch self {
        case .resolved:
            return nil
        case .unavailable:
            return "无法确定要忽略的应用：请先在目标应用中使用一次剪贴板，再回来添加。"
        case .missingBundleID(let name):
            return "“\(name)”没有应用标识（bundle ID），Clipa 无法按应用忽略它。"
        }
    }
}

/// Resolves the app that "ignore the current app" refers to.
///
/// Pure so the rules stay testable: while Clipa's own window is frontmost (the
/// floating panel) the answer is the last app the user was actually working in
/// — never Clipa itself.
enum IgnoreTargetResolver {
    /// The two facts the decision needs about an app.
    struct Candidate: Equatable {
        let bundleID: String?
        let name: String?
    }

    static func resolve(
        frontmost: NSRunningApplication?,
        lastExternal: NSRunningApplication?,
        ownBundleID: String? = Bundle.main.bundleIdentifier
    ) -> IgnoreTargetResolution {
        resolve(
            frontmost: frontmost.map {
                Candidate(bundleID: $0.bundleIdentifier, name: $0.localizedName)
            },
            lastExternal: lastExternal.map {
                Candidate(bundleID: $0.bundleIdentifier, name: $0.localizedName)
            },
            ownBundleID: ownBundleID
        )
    }

    static func resolve(
        frontmost: Candidate?,
        lastExternal: Candidate?,
        ownBundleID: String?
    ) -> IgnoreTargetResolution {
        let own = ownBundleID.flatMap(BundleIDNormalizer.normalize)
        if let frontmost {
            let front = BundleIDNormalizer.normalize(frontmost.bundleID ?? "")
            if front != own {
                guard let front else {
                    return .missingBundleID(
                        name: frontmost.name ?? "未知应用"
                    )
                }
                return .resolved(
                    bundleID: front,
                    name: frontmost.name ?? front
                )
            }
        }
        // Clipa itself is frontmost (or nothing is): fall back to the last app
        // the user actually worked in.
        guard let lastExternal,
              let bundleID = BundleIDNormalizer.normalize(
                  lastExternal.bundleID ?? ""
              ),
              bundleID != own else {
            return .unavailable
        }
        return .resolved(
            bundleID: bundleID,
            name: lastExternal.name ?? bundleID
        )
    }
}

@MainActor
enum IgnoreTargetActions {
    /// The app "忽略当前前台应用" means *right now*, or why there is no answer.
    ///
    /// The caller resolves once and renders the result into the menu item, then
    /// adds the bundle id that item carries. Resolving twice — once to label,
    /// once to act — would let the label and the effect disagree.
    static func currentTarget() -> IgnoreTargetResolution {
        IgnoreTargetResolver.resolve(
            frontmost: NSWorkspace.shared.frontmostApplication,
            lastExternal: ActiveAppTracker.shared.lastExternalApp
        )
    }

    /// Adds one bundle id, normalized and deduplicated. Returns `false` when
    /// the id was empty or already on the list.
    @discardableResult
    static func add(
        bundleID rawBundleID: String,
        to settings: SettingsStore = .shared
    ) -> Bool {
        guard let bundleID = BundleIDNormalizer.normalize(rawBundleID) else {
            return false
        }
        guard !settings.ignoredApps.contains(bundleID) else { return false }
        settings.ignoredApps.append(bundleID)
        return true
    }

    /// What a batch add (the "choose application…" panel) produced.
    struct BatchResult: Equatable {
        var added: [String] = []
        var alreadyListed: [String] = []
        var unusable: [String] = []
    }

    /// Adds every picked app bundle. Bundles without a bundle identifier (plain
    /// executables, broken bundles) are reported instead of silently ignored.
    @discardableResult
    static func addApplications(
        at urls: [URL],
        to settings: SettingsStore = .shared
    ) -> BatchResult {
        var result = BatchResult()
        for url in urls {
            guard let bundleID = AppIdentityCache.shared
                .bundleID(forApplicationAt: url) else {
                result.unusable.append(url.lastPathComponent)
                continue
            }
            if settings.ignoredApps.contains(bundleID) {
                result.alreadyListed.append(bundleID)
            } else {
                settings.ignoredApps.append(bundleID)
                result.added.append(bundleID)
            }
        }
        return result
    }
}

/// What the 忽略与跳过 line says, and whether it can be clicked at all.
///
/// Pure so the wording is pinned by tests instead of by the menu: the previous
/// item was always clickable and always answered "已忽略 X", including when X was
/// already on the list and nothing had changed — a claim rather than a fact.
/// Now an app that is already ignored says so and cannot be clicked, an app that
/// cannot be resolved explains why instead of failing silently on click, and the
/// click acts on the bundle id this value carries, so the label and the effect
/// cannot disagree.
enum IgnoreTargetPresentation: Equatable {
    case actionable(title: String, bundleID: String)
    case alreadyIgnored(title: String)
    case unavailable(title: String, reason: String?)

    static func make(
        resolution: IgnoreTargetResolution,
        isAlreadyIgnored: (String) -> Bool
    ) -> IgnoreTargetPresentation {
        switch resolution {
        case .resolved(let bundleID, let name):
            guard !isAlreadyIgnored(bundleID) else {
                return .alreadyIgnored(title: "已忽略「\(name)」")
            }
            return .actionable(title: "忽略「\(name)」", bundleID: bundleID)
        case .missingBundleID(let name):
            return .unavailable(
                title: "无法忽略「\(name)」",
                reason: resolution.failureMessage
            )
        case .unavailable:
            return .unavailable(
                title: "忽略当前前台应用",
                reason: resolution.failureMessage
            )
        }
    }

    var title: String {
        switch self {
        case .actionable(let title, _), .alreadyIgnored(let title),
             .unavailable(let title, _):
            return title
        }
    }

    /// The app to add when clicked; `nil` when there is nothing to add.
    var bundleID: String? {
        guard case .actionable(_, let bundleID) = self else { return nil }
        return bundleID
    }

    var isEnabled: Bool { bundleID != nil }

    /// Shown on hover. The bundle id is what the rule matches on, so it stays
    /// readable even when two builds of an app share a name.
    var toolTip: String? {
        switch self {
        case .actionable(_, let bundleID):
            return bundleID
        case .alreadyIgnored:
            return "该应用已在忽略清单中；点下面那一条可以恢复记录"
        case .unavailable(_, let reason):
            return reason
        }
    }
}
