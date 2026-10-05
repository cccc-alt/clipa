import AppKit
import Foundation

struct AppIdentity: Equatable {
    let bundleID: String
    let name: String
    let icon: NSImage?
}

@MainActor
final class AppIdentityCache {
    static let shared = AppIdentityCache()

    private var cache: [String: AppIdentity] = [:]

    private var missing: Set<String> = []

    private init() {}

    func identity(for rawBundleID: String) -> AppIdentity? {
        guard let bundleID = BundleIDNormalizer.normalize(rawBundleID) else {
            return nil
        }
        if let cached = cache[bundleID] { return cached }
        guard !missing.contains(bundleID) else { return nil }
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleID
        ) else {
            missing.insert(bundleID)
            return nil
        }
        let bundle = Bundle(url: url)
        let displayName = bundle?.object(
            forInfoDictionaryKey: "CFBundleDisplayName"
        ) as? String
        let bundleName = bundle?.object(
            forInfoDictionaryKey: "CFBundleName"
        ) as? String
        let identity = AppIdentity(
            bundleID: bundleID,
            name: displayName
                ?? bundleName
                ?? url.deletingPathExtension().lastPathComponent,
            icon: NSWorkspace.shared.icon(forFile: url.path)
        )
        cache[bundleID] = identity
        return identity
    }

    func displayName(for rawBundleID: String) -> String {
        identity(for: rawBundleID)?.name ?? rawBundleID
    }

    func bundleID(forApplicationAt url: URL) -> String? {
        (Bundle(url: url)?.bundleIdentifier)
            .flatMap(BundleIDNormalizer.normalize)
    }
}
