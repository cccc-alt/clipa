import Darwin
import Foundation

/// 本地控制面的 socket 服务端。
///
/// 传输：`<root>/clipa.sock`（unix domain socket，权限 `0600`）。**不开任何网络监听**，
/// 不做 HTTP，也不引入常驻 gateway。
///
/// 协议：客户端写一行 JSON 请求 → 服务端回一行 JSON 响应 → 关闭。一行一个往返，没有
/// 长连接、没有推送。这个线格式**不是对外契约**（契约是 CLI 的 `--json` 输出）——
/// 公开第二个协议面就多一份版本管理与校验。
///
/// 单实例：`bind` 之前先试着连一下已存在的 socket。能连上说明已有实例在服务，本次
/// **不接管** —— 这也顺手补上了这个应用一直缺的那道单实例守卫（至少是控制面这一侧）。
final class APIControlServer: @unchecked Sendable {
    static let shared = APIControlServer()

    private let queue = DispatchQueue(label: "com.clipa.api-control")
    private var listenFD: Int32 = -1
    private let clientSlots = DispatchSemaphore(value: 16)
    private let ioQueue = DispatchQueue(
        label: "com.clipa.api-control.io", qos: .utility, attributes: .concurrent
    )
    /// socket 占位锁（见 `start`）：进程存活期持有，防止双实例互相拆 socket。
    private var claimLockFD: Int32 = -1
    /// 复用的策略服务（P1 修复 2026-10-02）：原来每个请求都新建
    /// `APIControlService`，而限流计数 `callsByToken` 是实例状态——每请求从零
    /// 开始，60 次/分的限流从未生效。按根目录缓存；切工作区会重新 `start`、
    /// 根目录变化，缓存自动失效重建，保留"跟着当前工作区走"的原语义。
    private var cachedService: (root: URL, service: APIControlService)?
    private var source: DispatchSourceRead?
    private(set) var lastError: String?

    /// 依赖由图传进来（默认就是应用自己的 store / 设置 / 数据目录）。
    /// 让探针能起一个**指向隔离世界**的服务端，于是"socket 往返"这一层也能被验证，
    /// 而不是只能验证策略层。
    private var store: ClipStore?
    private var settings: SettingsStore?
    private var rootDirectory: URL?

    var isRunning: Bool { listenFD >= 0 }

    static func socketURL(rootDirectory: URL) -> URL {
        rootDirectory.appendingPathComponent("clipa.sock")
    }

    // MARK: - 生命周期

    @MainActor
    func start(
        store: ClipStore = .shared,
        settings: SettingsStore = .shared,
        rootDirectory: URL? = nil
    ) {
        stop()
        // **必须在监听之前读一次令牌文件**：`APITokenStore` 是内存里的数组，不读它
        // 就是空的 —— 那会让"接口开着、socket 也在，但任何令牌都无效"。实测踩过。
        APITokenStore.shared.reload()
        self.store = store
        self.settings = settings
        self.rootDirectory = rootDirectory ?? ClipStore.defaultBaseDirectory()
        let url = Self.socketURL(
            rootDirectory: self.rootDirectory ?? ClipStore.defaultBaseDirectory()
        )
        // P2 修复（2026-10-03）：占位改成**进程生命周期的独占锁**。旧流程
        // canConnect → unlink → bind 三步分离，两个实例同时启动都能通过检查、
        // 然后各自 unlink——后者把前者的活 socket 拆掉再挂自己的，前者的
        // 菜单还显示"接口已开"，客户端却连不上。flock 在进程退出时自动释放，
        // 无死锁残留。
        let lockURL = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".claim")
        claimLockFD = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
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
        // Hold the claim until bind/listen succeeds; failed starts own no socket.
        var started = false
        defer {
            if !started {
                close(claimLockFD)
                claimLockFD = -1
            }
        }
        if Self.canConnect(to: url) {
            lastError = "已有服务占用接口，本次不接管"
            return
        }
        unlink(url.path)
        guard var address = Self.address(for: url) else {
            lastError = "socket 路径过长：\(url.path)"
            return
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            lastError = "socket() 失败"
            return
        }
        // 监听 fd 虽然只 accept 不 send，也一并设上——统一为"本服务的每个
        // socket 都不开 SIGPIPE 口子"。
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
        // 0600：只有当前用户能连。这是这个 socket 唯一的技术性保护。
        guard chmod(url.path, 0o600) == 0 else {
            lastError = "无法设置接口权限"
            close(fd)
            unlink(url.path)
            return
        }
        guard listen(fd, 32) == 0 else {
            lastError = "listen 失败：\(String(cString: strerror(errno)))"
            close(fd)
            unlink(url.path)
            return
        }
        // A cancelled/consumed readiness event must not block in accept().
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        listenFD = fd
        started = true
        let readSource = DispatchSource.makeReadSource(
            fileDescriptor: fd,
            queue: queue
        )
        readSource.setEventHandler { [weak self] in
            guard let self else { return }
            self.acceptOne(listener: fd)
        }
        // P1 修复（2026-10-02）：fd 的关闭归事件源的取消流程管。cancel 是异步
        // 生效的，旧 stop() "先 cancel 再立刻 close"存在竞态——accept 可能正
        // 拿着这个 fd，close 之后同号 fd 被其它 open() 复用，accept 就作用在
        // 无关 fd 上。cancelHandler 由系统保证在事件源完全停止后执行，无竞态。
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
        let ownedSocket = listenFD >= 0
        source?.cancel()
        source = nil
        listenFD = -1
        cachedService = nil
        store = nil
        // A failed second instance must never unlink the first one's endpoint.
        // Keep the claim lock held until our own endpoint has been removed.
        if ownedSocket {
            let url = Self.socketURL(
                rootDirectory: rootDirectory ?? ClipStore.defaultBaseDirectory()
            )
            unlink(url.path)
        }
        if claimLockFD >= 0 {
            close(claimLockFD)
            claimLockFD = -1
        }
    }

    @MainActor
    func rebind(store: ClipStore) {
        self.store = store
        cachedService = nil
    }

    // MARK: - 连接

    private func acceptOne(listener: Int32) {
        let client = accept(listener, nil, nil)
        guard client >= 0 else { return }
        var user: uid_t = 0
        var group: gid_t = 0
        guard getpeereid(client, &user, &group) == 0, user == geteuid(),
              clientSlots.wait(timeout: .now()) == .success else {
            close(client)
            return
        }
        _ = fcntl(client, F_SETFD, FD_CLOEXEC)
        _ = fcntl(client, F_SETFL, 0)
        SocketProtection.disableSigPipe(client)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        for option in [SO_RCVTIMEO, SO_SNDTIMEO] {
            setsockopt(client, SOL_SOCKET, option, &timeout, socklen_t(MemoryLayout<timeval>.size))
        }
        let peer = Self.peerDescription(of: client)
        let peerPID = Self.peerPID(of: client)
        let slots = clientSlots
        let ioQueue = self.ioQueue
        Task.detached(priority: .utility) { [weak self] in
            defer { close(client); slots.signal() }
            // Blocking socket I/O belongs on a bounded GCD queue, never on
            // Swift's cooperative executor or the listener queue.
            let line: String? = await withCheckedContinuation { continuation in
                ioQueue.async {
                    continuation.resume(returning: Self.readLine(from: client, limit: 64 * 1024))
                }
            }
            guard let line,
                  let response = await self?.service.handle(line: line, peer: peer, peerPID: peerPID) else { return }
            let payload = Self.encodedLine(response) ?? Data()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                ioQueue.async {
                    Self.sendPayload(payload, to: client)
                    continuation.resume()
                }
            }
        }
    }

    /// 复用缓存的策略服务；只有根目录变了（切工作区后重新 `start`）才重建，
    /// 限流计数因此能在请求之间延续。
    @MainActor
    private var service: APIControlService {
        let root = rootDirectory ?? ClipStore.defaultBaseDirectory()
        if let cached = cachedService, cached.root == root {
            return cached.service
        }
        let boundStore = store ?? .shared
        let fresh = APIControlService(
            store: boundStore,
            settings: settings ?? .shared,
            rootDirectory: root,
            copyClip: { clip in
                await ClipboardWriter.shared.copyAsync(clip, store: boundStore)
            }
        )
        cachedService = (root, fresh)
        return fresh
    }

    // MARK: - 读写

    /// A request needs a newline, a strict byte limit and an absolute deadline.
    /// Per-read timeouts alone allow a slow peer to keep a slot forever.
    static func readLine(from fd: Int32, limit: Int, timeout: TimeInterval = 5) -> String? {
        guard limit > 0 else { return nil }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, timeout) * 1_000_000_000)
        var buffer = [UInt8]()
        buffer.reserveCapacity(min(limit, 4096))
        var chunk = [UInt8](repeating: 0, count: 4096)
        while buffer.count <= limit {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return nil }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let milliseconds = Int32(min((deadline - now) / 1_000_000 + 1, UInt64(Int32.max)))
            let ready = poll(&descriptor, 1, milliseconds)
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { return nil }
            let count = read(fd, &chunk, min(chunk.count, limit - buffer.count + 1))
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }
            // Only inspect new bytes; rescanning the growing buffer was O(n²).
            if let newline = chunk[..<count].firstIndex(of: 0x0A) {
                guard buffer.count + newline <= limit else { return nil }
                buffer.append(contentsOf: chunk[..<newline])
                return buffer.isEmpty ? nil : String(bytes: buffer, encoding: .utf8)
            }
            buffer.append(contentsOf: chunk[..<count])
        }
        return nil
    }

    static func encodedLine(_ response: APIResponse) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let data = try? encoder.encode(response) else { return nil }
        return data + Data([0x0A])
    }

    static func sendPayload(_ payload: Data, to fd: Int32, timeout: TimeInterval = 5) {
        // Darwin Unix sockets also need O_NONBLOCK for a large send to honor
        // the deadline; MSG_DONTWAIT alone can still block in the kernel.
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return }
        defer { _ = fcntl(fd, F_SETFL, flags) }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, timeout) * 1_000_000_000)
        payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { return }
                let written = send(
                    fd,
                    base.advanced(by: offset),
                    raw.count - offset,
                    MSG_DONTWAIT
                )
                if written < 0, errno == EINTR { continue }
                if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    let milliseconds = Int32(min((deadline - now) / 1_000_000 + 1, UInt64(Int32.max)))
                    let ready = poll(&descriptor, 1, milliseconds)
                    if ready < 0, errno == EINTR { continue }
                    guard ready > 0 else { return }
                    continue
                }
                if written <= 0 { return }
                offset += written
            }
        }
    }

    // MARK: - 对端与地址

    /// 对端身份：可执行文件路径 + pid。**它只用于审计**，不是准入条件 ——
    /// 准入看令牌（理由见 `APIToken` 的注释：Agent 多半不是签名 app）。
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

    /// 对端 pid（2026-10-04 起除审计外还喂给 `put`：把写入条目归因到
    /// 调用方的宿主应用，徽标才有真图标可解析）。
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

    /// 有人在这个地址上服务吗？（`bind` 前的单实例检查，也给 CLI 判断"应用在不在"。）
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
