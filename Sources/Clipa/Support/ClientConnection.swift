import AppKit
import Darwin
import Foundation

enum IntegrationClient: String, CaseIterable, Codable, Identifiable {
    case cursor, claude, codex, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cursor: return "Cursor"
        case .claude: return "Claude Desktop"
        case .codex: return "Codex"
        case .custom: return "其他 MCP 客户端"
        }
    }
    func configURL(home: URL) -> URL? {
        switch self {
        case .cursor: return home.appendingPathComponent(".cursor/mcp.json")
        case .claude: return home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        case .codex:
            let base = (home == FileManager.default.homeDirectoryForCurrentUser ? ProcessInfo.processInfo.environment["CODEX_HOME"] : nil).map { URL(fileURLWithPath: $0) }
                ?? home.appendingPathComponent(".codex")
            return base.appendingPathComponent("config.toml")
        case .custom: return nil
        }
    }
}

/// Only this owner-readable file contains a managed connection's bearer token.
/// Client configs contain the opaque profile ID, never the token itself.
struct ClientCredential: Codable {
    let id: UUID
    let tokenID: String
    let client: IntegrationClient
    var secret: String
    let createdAt: Date
}

enum ClientCredentials {
    static func directory(root: URL = ClipStore.defaultBaseDirectory()) -> URL {
        root.appendingPathComponent("connections", isDirectory: true)
    }
    static func url(_ id: UUID, root: URL = ClipStore.defaultBaseDirectory()) -> URL {
        directory(root: root).appendingPathComponent(id.uuidString + ".json")
    }
    static func read(_ id: UUID, root: URL = ClipStore.defaultBaseDirectory()) throws -> ClientCredential {
        let path = url(id, root: root)
        let fd = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw WorkflowError.message("连接凭据不存在，请在 Clipa 中重新连接。") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_size > 0, info.st_size <= 16_384 else {
            throw WorkflowError.message("连接凭据权限或格式异常，请重新连接。")
        }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
        guard count == data.count else { throw WorkflowError.message("连接凭据读取不完整，请重试。") }
        let result = try JSONDecoder().decode(ClientCredential.self, from: data)
        guard result.id == id, !result.secret.isEmpty else { throw WorkflowError.message("连接凭据不匹配。") }
        return result
    }
    static func write(_ credential: ClientCredential, root: URL = ClipStore.defaultBaseDirectory()) throws {
        try DatabaseFiles.protectDirectory(directory(root: root))
        try OwnerOnlyFile.write(JSONEncoder().encode(credential), to: url(credential.id, root: root))
    }
    static func remove(_ id: UUID, root: URL = ClipStore.defaultBaseDirectory()) throws {
        let path = url(id, root: root)
        if unlink(path.path) != 0 && errno != ENOENT { throw WorkflowError.message("授权已撤销，但本地凭据文件未能删除。") }
    }
}

struct ClientInstallResult {
    let destination: URL?
    let backup: URL?
    let config: String
}

enum ClientConfigurationInstaller {
    typealias Runner = (URL, [String]) throws -> (Int32, Data)

    static func config(id: UUID, helper: URL, codex: Bool = false) -> String {
        if codex {
            // JSON string escaping is compatible with a TOML basic string here.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            let escaped = String(data: try! encoder.encode(helper.path), encoding: .utf8)!
            return "[mcp_servers.clipa]\ncommand = \(escaped)\nenv = { CLIPA_CONNECTION = \"\(id.uuidString)\" }\n"
        }
        let value: [String: Any] = ["mcpServers": ["clipa": entry(id: id, helper: helper)]]
        return String(data: try! JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!
    }

    private static func entry(id: UUID, helper: URL) -> [String: Any] {
        ["command": helper.path, "env": ["CLIPA_CONNECTION": id.uuidString]]
    }

    /// Merge only Clipa's entry. A pre-existing entry needs explicit replacement
    /// in the connection form, and its full file is backed up before mutation.
    static func install(client: IntegrationClient, id: UUID, helper: URL,
                        replaceExisting: Bool, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                        codexCLI: URL? = nil, runner: Runner = run) throws -> ClientInstallResult {
        let text = config(id: id, helper: helper, codex: client == .codex)
        guard let destination = client.configURL(home: home) else {
            return ClientInstallResult(destination: nil, backup: nil, config: text)
        }
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: destination.path)
        if exists {
            let attrs = try fm.attributesOfItem(atPath: destination.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular,
                  (attrs[.size] as? NSNumber)?.intValue ?? Int.max <= 2 * 1024 * 1024 else {
                throw WorkflowError.message("配置文件不是普通文件或过大，请通过客户端手动添加。")
            }
        }
        let original = exists ? try Data(contentsOf: destination) : nil
        let backup = original.map { _ in destination.deletingLastPathComponent()
            .appendingPathComponent(destination.lastPathComponent + ".clipa-backup-" + UUID().uuidString) }

        if client == .codex {
            guard let executable = codexCLI ?? findCodexCLI() else {
                throw WorkflowError.message("未找到 Codex CLI。安装 Codex 后重试，或选择“其他 MCP 客户端”复制配置。")
            }
            // Let Codex parse and preserve its own TOML instead of rewriting it.
            let existing = try runner(executable, ["mcp", "get", "clipa", "--json"])
            if existing.0 == 0 && !replaceExisting { throw WorkflowError.message("已有 Clipa 配置。勾选“替换已有配置”后重试。") }
            if let original, let backup { try OwnerOnlyFile.write(original, to: backup) }
            let result = try runner(executable, ["mcp", "add", "clipa", "--env", "CLIPA_CONNECTION=\(id.uuidString)", "--", helper.path])
            guard result.0 == 0 else {
                throw WorkflowError.message("Codex 未能保存配置。原配置备份：\(backup?.path ?? "无原文件")。可重试或手动配置。")
            }
            let verified = try runner(executable, ["mcp", "get", "clipa", "--json"])
            let object = (try? JSONSerialization.jsonObject(with: verified.1)) as? [String: Any]
            let transport = object?["transport"] as? [String: Any]
            let environment = transport?["env"] as? [String: String]
            guard verified.0 == 0, transport?["command"] as? String == helper.path,
                  environment?["CLIPA_CONNECTION"] == id.uuidString, environment?["CLIPA_TOKEN"] == nil else {
                throw WorkflowError.message("Codex 配置写入后的校验未通过，请检查客户端配置或使用手动配置。")
            }
        } else {
            var object: [String: Any] = [:]
            if let original {
                guard let parsed = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
                    throw WorkflowError.message("客户端配置不是 JSON 对象，原文件未更改。")
                }
                object = parsed
            }
            if let raw = object["mcpServers"], !(raw is [String: Any]) {
                throw WorkflowError.message("mcpServers 格式异常，原文件未更改。")
            }
            var servers = object["mcpServers"] as? [String: Any] ?? [:]
            if servers["clipa"] != nil && !replaceExisting {
                throw WorkflowError.message("已有 Clipa 配置。勾选“替换已有配置”后重试。")
            }
            servers["clipa"] = entry(id: id, helper: helper)
            object["mcpServers"] = servers
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            // Refuse to overwrite concurrent edits by the other application.
            if original != (fm.fileExists(atPath: destination.path) ? try Data(contentsOf: destination) : nil) {
                throw WorkflowError.message("配置刚刚被其他程序修改，请重试。")
            }
            if let original, let backup { try OwnerOnlyFile.write(original, to: backup) }
            try OwnerOnlyFile.write(data, to: destination)
        }
        return ClientInstallResult(destination: destination, backup: backup, config: text)
    }

    static func findCodexCLI() -> URL? {
        let paths = ["/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex",
                     "/Applications/Codex.app/Contents/Resources/codex",
                     "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/codex" }
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    static func run(_ executable: URL, _ arguments: [String]) throws -> (Int32, Data) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15, execute: timeout)
        defer { timeout.cancel() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }
}
