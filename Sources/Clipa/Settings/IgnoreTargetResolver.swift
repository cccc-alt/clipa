import AppKit
import Foundation

enum IgnoreTargetResolution: Equatable {
    case resolved(bundleID: String, name: String)

    case unavailable

    case missingBundleID(name: String)

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

enum IgnoreTargetResolver {

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

    static func currentTarget() -> IgnoreTargetResolution {
        IgnoreTargetResolver.resolve(
            frontmost: NSWorkspace.shared.frontmostApplication,
            lastExternal: ActiveAppTracker.shared.lastExternalApp
        )
    }

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

    struct BatchResult: Equatable {
        var added: [String] = []
        var alreadyListed: [String] = []
        var unusable: [String] = []
    }

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

    var bundleID: String? {
        guard case .actionable(_, let bundleID) = self else { return nil }
        return bundleID
    }

    var isEnabled: Bool { bundleID != nil }

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
