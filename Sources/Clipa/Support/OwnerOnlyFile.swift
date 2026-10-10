import Foundation

/// 只有本人可读的文件写入（`0600`）：**令牌文件与审计文件**走这一条。
///
/// 它原先住在 `APIExport` 里（M1 只读导出的产物），M1 移除后它就是控制面自己在用的
/// 基础设施，所以单独成文件、名字照着它真正做的事起。
enum OwnerOnlyFile {
    enum WriteError: LocalizedError {
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .writeFailed(let path): return "写入文件失败：\(path)"
            }
        }
    }

    /// 原子写 + `0600`：先在目标目录建一个 `0600` 的临时文件，再 `rename(2)` 覆盖。
    ///
    /// 不用 `Data.write(options: .atomic)`：它先落一个**默认权限**的临时文件再换名，
    /// 中间那一刻文件是 `0644` 的。这里自己拿着权限位走完整个过程，读文件的程序永远
    /// 只会看到"旧的完整版本"或"新的完整版本"。
    static func write(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let temporary = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )
        guard FileManager.default.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw WriteError.writeFailed(temporary.path)
        }
        guard rename(temporary.path, destination.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw WriteError.writeFailed(destination.path)
        }
    }

    /// 文件权限是不是 `0600`（自检用：这是这些文件唯一的技术性保护）。
    static func isOwnerOnly(at url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path
        ), let permissions = attributes[.posixPermissions] as? NSNumber else {
            return false
        }
        return permissions.intValue & 0o077 == 0
    }
}
