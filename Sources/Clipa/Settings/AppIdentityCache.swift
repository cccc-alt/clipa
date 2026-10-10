import AppKit
import Foundation

/// Display identity for a bundle identifier.
struct AppIdentity: Equatable {
    let bundleID: String
    let name: String
    let icon: NSImage?
}

/// Resolves bundle identifiers to a name and icon for the settings list.
///
/// Only apps LaunchServices already knows about are resolved. Nothing is
/// scanned on disk, so an app the user deleted or moved simply falls back to
/// its raw bundle id in the UI — and looking at an app bundle that lives in a
/// TCC-protected folder (Desktop, Documents, Downloads, removable volumes)
/// never happens, so this cannot raise a permission prompt.
@MainActor
final class AppIdentityCache {
    static let shared = AppIdentityCache()

    private var cache: [String: AppIdentity] = [:]
    /// Negative cache: repeated lookups of a missing app stay cheap.
    private var missing: Set<String> = []

    private init() {}

    /// Returns `nil` when the app is not installed (or is not an app bundle).
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

    /// Name to show for a bundle id, falling back to the raw id.
    func displayName(for rawBundleID: String) -> String {
        identity(for: rawBundleID)?.name ?? rawBundleID
    }

    /// Reads the bundle identifier out of a user-picked app bundle.
    func bundleID(forApplicationAt url: URL) -> String? {
        (Bundle(url: url)?.bundleIdentifier)
            .flatMap(BundleIDNormalizer.normalize)
    }
}
