import Darwin
import Foundation

/// Permissions are established before SQLite can create journals or write pages.
enum DatabaseFiles {
    /// macOS itself aliases /var and /tmp. Resolve parent aliases after checking
    /// the final file with O_NOFOLLOW; SQLite's flag rejects parent aliases too.
    static func sqlitePath(_ path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        // Foundation deliberately shortens /private/var back to /var on macOS.
        // realpath retains the physical path required by SQLITE_OPEN_NOFOLLOW.
        guard let resolved = realpath(parent, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved) + "/" + (path as NSString).lastPathComponent
    }

    static func protectDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure() }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(),
              fchmod(fd, 0o700) == 0 else { throw failure() }
    }

    @discardableResult
    static func protectFile(_ path: String, create: Bool = false) throws -> Bool {
        let flags = O_RDWR | O_NOFOLLOW | O_CLOEXEC | (create ? O_CREAT : 0)
        let fd = open(path, flags, 0o600)
        if fd < 0, !create, errno == ENOENT { return false }
        guard fd >= 0 else { throw failure() }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1,
              fchmod(fd, 0o600) == 0 else { throw failure() }
        return true
    }

    static func protectDatabase(_ path: String) throws {
        for suffix in ["", "-wal", "-shm", "-journal", ".plain-backup"] {
            try protectFile(path + suffix)
        }
    }

    /// Serialize the check/export/replace sequence across application instances.
    /// The lock is only held during open, so ordinary encrypted readers coexist.
    static func lockOpen(_ path: String) throws -> Int32 {
        let lockPath = path + ".open-lock"
        try protectFile(lockPath, create: true)
        let fd = open(lockPath, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure() }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            throw DatabaseError.connectionFailed("另一实例正在打开或迁移数据库，请稍后重试")
        }
        return fd
    }

    static func unlockOpen(_ fd: Int32) { Darwin.close(fd) }

    private static func failure() -> DatabaseError {
        .connectionFailed("数据目录或文件必须由当前用户独占，且不能是符号链接或硬链接")
    }
}
