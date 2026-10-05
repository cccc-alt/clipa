import Darwin
import Foundation

/// Local Unix-socket server for the token+scope gated control plane.
final class APIControlServer: @unchecked Sendable {
    static let shared = APIControlServer()

    private let queue = DispatchQueue(label: "com.clipa.api-control")
    private var listenFD: Int32 = -1

    private var claimLockFD: Int32 = -1

    private var cachedService: (root: URL, service: APIControlService)?
    private var source: DispatchSourceRead?
    private(set) var lastError: String?

    private var store: ClipStore?
    private var settings: SettingsStore?
    private var rootDirectory: URL?

    var isRunning: Bool { listenFD >= 0 }

    static func socketURL(rootDirectory: URL) -> URL {
        rootDirectory.appendingPathComponent("clipa.sock")
    }

    @MainActor
    func start(
        store: ClipStore = .shared,
        settings: SettingsStore = .shared,
        rootDirectory: URL? = nil
    ) {
        stop()

        APITokenStore.shared.reload()
        self.store = store
        self.settings = settings
        self.rootDirectory = rootDirectory ?? ClipStore.defaultBaseDirectory()
        let url = Self.socketURL(
            rootDirectory: self.rootDirectory ?? ClipStore.defaultBaseDirectory()
        )

        let lockURL = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".claim")
        claimLockFD = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard claimLockFD >= 0 else {
            lastError = "无法创建接口占位锁 \(lockURL.lastPathComponent)"
            return
        }
        guard flock(claimLockFD, LOCK_EX | LOCK_NB) == 0 else {
            close(claimLockFD)
            claimLockFD = -1
            lastError = "已有实例在服务 \(url.lastPathComponent)，本次不接管"
            NSLog("Clipa API control: \(lastError ?? "")")
            return
        }
        if Self.canConnect(to: url) {

            unlink(url.path)
        }
        guard var address = Self.address(for: url) else {
            lastError = "socket 路径过长：\(url.path)"
            return
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            lastError = "socket() 失败"
            return
        }

        SocketProtection.disableSigPipe(fd)
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, size)
            }
        }
        guard bound == 0 else {
            lastError = "bind 失败：\(String(cString: strerror(errno)))"
            close(fd)
            return
        }

        chmod(url.path, 0o600)
        guard listen(fd, 32) == 0 else {
            lastError = "listen 失败：\(String(cString: strerror(errno)))"
            close(fd)
            unlink(url.path)
            return
        }
        listenFD = fd
        let readSource = DispatchSource.makeReadSource(
            fileDescriptor: fd,
            queue: queue
        )
        readSource.setEventHandler { [weak self] in
            guard let self else { return }
            self.acceptOne()
        }

        readSource.setCancelHandler { [fd] in
            close(fd)
        }
        readSource.resume()
        source = readSource
        lastError = nil
        NSLog("Clipa API control listening on \(url.path)")
    }

    @MainActor
    func stop() {

        source?.cancel()
        source = nil
        listenFD = -1
        if claimLockFD >= 0 {
            close(claimLockFD)
            claimLockFD = -1
        }
        let url = Self.socketURL(
            rootDirectory: rootDirectory ?? ClipStore.defaultBaseDirectory()
        )
        unlink(url.path)
    }

    private func acceptOne() {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }

        SocketProtection.disableSigPipe(client)

        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(
            client,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
        let peer = Self.peerDescription(of: client)
        let peerPID = Self.peerPID(of: client)

        Task.detached(priority: .utility) { [weak self] in
            guard let line = Self.readLine(from: client, limit: 64 * 1024)
            else {
                close(client)
                return
            }

            guard let response = await self?.service.handle(
                line: line,
                peer: peer,
                peerPID: peerPID
            ) else {
                close(client)
                return
            }
            let payload = Self.encodedLine(response) ?? Data()
            Self.sendPayload(payload, to: client)
            close(client)
        }
    }

    @MainActor
    private var service: APIControlService {
        let root = rootDirectory ?? ClipStore.defaultBaseDirectory()
        if let cached = cachedService, cached.root == root {
            return cached.service
        }
        let fresh = APIControlService(
            store: store ?? .shared,
            settings: settings ?? .shared,
            rootDirectory: root,
            copyClip: { clip in
                await ClipboardWriter.shared.copyAsync(clip, store: .shared)
            }
        )
        cachedService = (root, fresh)
        return fresh
    }

    private static func readLine(from fd: Int32, limit: Int) -> String? {
        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while buffer.count < limit {
            let count = read(fd, &chunk, chunk.count)
            if count <= 0 { break }
            buffer.append(contentsOf: chunk[0..<count])
            if let newline = buffer.firstIndex(of: 0x0A) {
                buffer = Array(buffer[..<newline])
                break
            }
        }
        guard !buffer.isEmpty else { return nil }
        return String(bytes: buffer, encoding: .utf8)
    }

    static func encodedLine(_ response: APIResponse) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let data = try? encoder.encode(response) else { return nil }
        return data + Data([0x0A])
    }

    static func sendPayload(_ payload: Data, to fd: Int32) {
        payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = send(
                    fd,
                    base.advanced(by: offset),
                    raw.count - offset,
                    0
                )
                if written <= 0 { break }
                offset += written
            }
        }
    }

    private static func peerDescription(of fd: Int32) -> String {
        guard let pid = peerPID(of: fd) else {
            return "unknown"
        }
        var buffer = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
            return "\(String(cString: buffer)) (pid \(pid))"
        }
        return "pid \(pid)"
    }

    private static func peerPID(of fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0,
              pid > 0 else {
            return nil
        }
        return pid
    }

    private static func address(for url: URL) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(url.path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else { return nil }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(
                to: CChar.self,
                capacity: capacity
            ) { destination in
                for (index, byte) in pathBytes.enumerated() {
                    destination[index] = CChar(bitPattern: byte)
                }
                destination[pathBytes.count] = 0
            }
        }
        return address
    }

    static func canConnect(to url: URL) -> Bool {
        guard var address = address(for: url) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, size)
            }
        }
        return result == 0
    }
}
