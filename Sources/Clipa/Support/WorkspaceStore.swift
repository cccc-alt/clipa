import Foundation

struct WorkspaceDescriptor: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    let createdAt: Date

    var directoryName: String?

    var historyLimit: Int? = nil

    var isDefault: Bool { directoryName == nil }
}

@MainActor
final class WorkspaceStore: ObservableObject {
    static let shared = WorkspaceStore()

    @Published private(set) var workspaces: [WorkspaceDescriptor] = []
    @Published private(set) var activeID: UUID = UUID()

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

    nonisolated static func registryURL(in rootDirectory: URL) -> URL {
        rootDirectory.appendingPathComponent(
            "workspaces.json",
            isDirectory: false
        )
    }

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
              let directoryName = active.directoryName
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

    func baseDirectory(for workspace: WorkspaceDescriptor) -> URL {
        guard let directoryName = workspace.directoryName else {
            return rootDirectory
        }
        return rootDirectory
            .appendingPathComponent("workspaces", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    @discardableResult
    func createWorkspace(
        named rawName: String? = nil,
        historyLimit: Int? = nil
    ) throws -> WorkspaceDescriptor {
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
        workspaces.append(descriptor)
        try save()
        return descriptor
    }

    func rename(_ id: UUID, to rawName: String) throws {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let index = workspaces.firstIndex(where: { $0.id == id })
        else { return }
        workspaces[index].name = Self.uniqueName(
            name,
            existing: workspaces.filter { $0.id != id }.map(\.name)
        )
        try save()
    }

    func delete(_ id: UUID) throws {
        guard let index = workspaces.firstIndex(where: { $0.id == id }),
              !workspaces[index].isDefault,
              id != activeID,
              workspaces.count > 1
        else { return }
        let descriptor = workspaces[index]
        let directory = baseDirectory(for: descriptor)
        if fileManager.fileExists(atPath: directory.path) {
            var trashed: NSURL?
            try fileManager.trashItem(
                at: directory,
                resultingItemURL: &trashed
            )
        }
        workspaces.remove(at: index)
        try save()
    }

    func setActive(_ id: UUID) throws {
        guard workspaces.contains(where: { $0.id == id }) else { return }
        activeID = id
        try save()
    }

    func storedHistoryLimit(for id: UUID) -> Int? {
        workspaces.first { $0.id == id }?.historyLimit
    }

    func setHistoryLimit(_ value: Int, for id: UUID) {
        guard value >= 0,
              let index = workspaces.firstIndex(where: { $0.id == id }),
              workspaces[index].historyLimit != value
        else { return }
        workspaces[index].historyLimit = value
        try? save()
    }

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
        if let data = try? Data(contentsOf: registryURL),
           let registry = try? JSONDecoder().decode(Registry.self, from: data),
           !registry.workspaces.isEmpty {
            workspaces = registry.workspaces
            activeID = registry.workspaces.contains {
                $0.id == registry.activeID
            } ? registry.activeID : registry.workspaces[0].id
            return
        }

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

    private func save() throws {
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
