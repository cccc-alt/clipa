import Foundation

/// One workspace: a name plus where its database lives.
///
/// The default workspace keeps the legacy layout (`Clipa/clips.sqlite` at the
/// top level) so existing data never has to move and an older build can still
/// open it. Every other workspace owns a directory under `workspaces/`.
struct WorkspaceDescriptor: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    let createdAt: Date
    /// `nil` = the default workspace, whose base directory is the store root.
    var directoryName: String?
    /// This workspace's own history limit; `nil` = never set, so the reader
    /// falls back to the shared default. `0` means 无限制.
    ///
    /// Optional and defaulted so a registry written by an earlier build still
    /// decodes, and so an older build reading this one simply ignores it.
    var historyLimit: Int? = nil

    var isDefault: Bool { directoryName == nil }
}

/// Registry of workspaces plus which one is active.
///
/// The registry is a small JSON file next to the databases, so a backup or a
/// restore of the Clipa directory carries the workspace list with the data.
/// It deliberately does not touch the databases themselves: switching is done
/// by `WorkspaceManager`, which rebuilds the store and the panel.
@MainActor
final class WorkspaceStore: ObservableObject {
    static let shared = WorkspaceStore()

    @Published private(set) var workspaces: [WorkspaceDescriptor] = []
    @Published private(set) var activeID: UUID = UUID()
    @Published private(set) var loadError: String?

    /// `Clipa/` — the directory that holds `clips.sqlite` and `workspaces.json`.
    let rootDirectory: URL

    private let registryURL: URL
    private let fileManager = FileManager.default

    init(rootDirectory: URL? = nil) {
        let root = rootDirectory ?? Self.defaultRootDirectory()
        self.rootDirectory = root
        self.registryURL = Self.registryURL(in: root)
        load()
    }

    nonisolated static func defaultRootDirectory() -> URL {
        if let override = ClipStore.defaultBaseDirectoryOverride {
            return override
        }
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return support.appendingPathComponent("Clipa", isDirectory: true)
    }

    nonisolated static func isSafeDirectoryName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && !name.contains("/") && !name.contains("\\")
            && name.rangeOfCharacter(from: .controlCharacters) == nil
    }

    nonisolated static func registryURL(in rootDirectory: URL) -> URL {
        rootDirectory.appendingPathComponent(
            "workspaces.json",
            isDirectory: false
        )
    }

    /// The active workspace's base directory, read straight off disk.
    ///
    /// `ClipStore.shared` is a static, and a static is initialized on first
    /// use from whatever thread gets there first, so it cannot ask this
    /// `@MainActor` type for anything. It does need the active workspace
    /// though: `ClipStore.shared` used to always open the *default* database,
    /// so launching with another workspace active first loaded the default
    /// one (103k rows ≈ 283MB) and kept it alive for the rest of the session.
    ///
    /// Read-only and non-throwing: an unreadable or missing registry means
    /// "default workspace", which is also what a fresh install gets.
    nonisolated static func activeBaseDirectoryOnDisk(
        rootDirectory: URL? = nil
    ) -> URL {
        let root = rootDirectory ?? defaultRootDirectory()
        guard let data = try? Data(contentsOf: registryURL(in: root)),
              let registry = try? JSONDecoder().decode(
                  Registry.self,
                  from: data
              ),
              let active = registry.workspaces.first(where: {
                  $0.id == registry.activeID
              }) ?? registry.workspaces.first,
              let directoryName = active.directoryName,
              isSafeDirectoryName(directoryName)
        else { return root }
        return root
            .appendingPathComponent("workspaces", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    var activeWorkspace: WorkspaceDescriptor {
        workspaces.first { $0.id == activeID }
            ?? workspaces[0]
    }

    var canDeleteWorkspaces: Bool { workspaces.count > 1 }

    /// Base directory that `ClipStore`/`DatabaseManager` should open.
    func baseDirectory(for workspace: WorkspaceDescriptor) -> URL {
        guard let directoryName = workspace.directoryName else {
            return rootDirectory
        }
        return rootDirectory
            .appendingPathComponent("workspaces", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    // MARK: - Mutations

    @discardableResult
    func createWorkspace(
        named rawName: String? = nil,
        historyLimit: Int? = nil
    ) throws -> WorkspaceDescriptor {
        try requireWritableRegistry()
        let name = Self.uniqueName(
            rawName?.trimmingCharacters(in: .whitespacesAndNewlines),
            existing: workspaces.map(\.name)
        )
        let id = UUID()
        let descriptor = WorkspaceDescriptor(
            id: id,
            name: name,
            createdAt: Date(),
            directoryName: id.uuidString,
            historyLimit: historyLimit
        )
        try fileManager.createDirectory(
            at: baseDirectory(for: descriptor),
            withIntermediateDirectories: true
        )
        let previous = workspaces
        workspaces.append(descriptor)
        do { try save() }
        catch {
            workspaces = previous
            try? fileManager.removeItem(at: baseDirectory(for: descriptor))
            throw error
        }
        return descriptor
    }

    func rename(_ id: UUID, to rawName: String) throws {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let index = workspaces.firstIndex(where: { $0.id == id })
        else { return }
        let previous = workspaces
        workspaces[index].name = Self.uniqueName(
            name,
            existing: workspaces.filter { $0.id != id }.map(\.name)
        )
        do { try save() }
        catch { workspaces = previous; throw error }
    }

    /// Moves a workspace's directory to the Trash and forgets it. The default
    /// workspace and the active workspace are never removed.
    func delete(_ id: UUID) throws {
        try requireWritableRegistry()
        guard let index = workspaces.firstIndex(where: { $0.id == id }),
              !workspaces[index].isDefault,
              id != activeID,
              workspaces.count > 1
        else { return }
        let descriptor = workspaces[index]
        let directory = baseDirectory(for: descriptor)
        var trashed: NSURL?
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.trashItem(
                at: directory,
                resultingItemURL: &trashed
            )
        }
        let previous = workspaces
        workspaces.remove(at: index)
        do { try save() }
        catch {
            workspaces = previous
            if let trashed {
                do { try fileManager.moveItem(at: trashed as URL, to: directory) }
                catch {
                    throw NSError(domain: "ClipaWorkspace", code: 1, userInfo: [NSLocalizedDescriptionKey:
                        "工作区文件已在废纸篓中，但列表保存失败。请先从废纸篓恢复该工作区。"])
                }
            }
            throw error
        }
    }

    func setActive(_ id: UUID) throws {
        guard workspaces.contains(where: { $0.id == id }) else { return }
        let previous = activeID
        activeID = id
        do { try save() }
        catch { activeID = previous; throw error }
    }

    // MARK: - Per-workspace history limit

    /// The limit this workspace stores itself, or `nil` when it never set one
    /// (the caller then uses the shared default).
    ///
    /// The limit lives with the workspace rather than in `UserDefaults` so a
    /// backup of the Clipa directory carries it along with the data it
    /// describes. The default workspace deliberately stores nothing: it keeps
    /// the historical global key, which is what an older build reads too.
    func storedHistoryLimit(for id: UUID) -> Int? {
        workspaces.first { $0.id == id }?.historyLimit
    }

    /// Records a workspace's own history limit. `0` means 无限制.
    func setHistoryLimit(_ value: Int, for id: UUID) {
        try? setHistoryLimitChecked(value, for: id)
    }

    func setHistoryLimitChecked(_ value: Int, for id: UUID) throws {
        guard value >= 0,
              let index = workspaces.firstIndex(where: { $0.id == id }),
              workspaces[index].historyLimit != value
        else { return }
        let previous = workspaces
        workspaces[index].historyLimit = value
        do { try save() }
        catch { workspaces = previous; throw error }
    }

    // MARK: - Persistence

    private struct Registry: Codable {
        var version: Int
        var activeID: UUID
        var workspaces: [WorkspaceDescriptor]
    }

    private func load() {
        try? fileManager.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: registryURL.path) {
            do {
                let registry = try JSONDecoder().decode(Registry.self, from: Data(contentsOf: registryURL))
                guard !registry.workspaces.isEmpty,
                      Set(registry.workspaces.map(\.id)).count == registry.workspaces.count,
                      registry.workspaces.allSatisfy({ item in
                          guard let directory = item.directoryName else { return true }
                          return Self.isSafeDirectoryName(directory)
                      }) else {
                    throw NSError(domain: "ClipaWorkspace", code: 2, userInfo: [NSLocalizedDescriptionKey: "工作区列表格式无效"])
                }
                workspaces = registry.workspaces
                activeID = registry.workspaces.contains { $0.id == registry.activeID }
                    ? registry.activeID : registry.workspaces[0].id
                return
            } catch {
                // Keep the unreadable registry intact instead of replacing it
                // with an empty default list and losing every workspace entry.
                loadError = "工作区列表无法读取。请恢复 workspaces.json 后重新启动。现有数据目录未被更改。"
            }
        }
        // First run (or an unreadable registry): adopt the existing database
        // as the default workspace. No files move.
        let descriptor = WorkspaceDescriptor(
            id: UUID(),
            name: "默认工作区",
            createdAt: Date(),
            directoryName: nil
        )
        workspaces = [descriptor]
        activeID = descriptor.id
        try? save()
    }

    private func requireWritableRegistry() throws {
        if let loadError {
            throw NSError(domain: "ClipaWorkspace", code: 3, userInfo: [NSLocalizedDescriptionKey: loadError])
        }
    }

    private func save() throws {
        try requireWritableRegistry()
        let registry = Registry(
            version: 1,
            activeID: activeID,
            workspaces: workspaces
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(registry)
        try data.write(to: registryURL, options: .atomic)
    }

    private static func uniqueName(
        _ requested: String?,
        existing: [String]
    ) -> String {
        let base = (requested?.isEmpty == false)
            ? requested!
            : "工作区 \(existing.count + 1)"
        guard existing.contains(base) else { return base }
        var index = 2
        var candidate = "\(base) \(index)"
        while existing.contains(candidate) {
            index += 1
            candidate = "\(base) \(index)"
        }
        return candidate
    }
}
