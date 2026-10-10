import AppKit
import Darwin
import Foundation

/// `clipa` 客户端：把一个请求写到 socket、读回一个响应、打印出来。
///
/// 它**不读数据库、不判策略、不认识私密标记** —— 所有策略都在应用进程里，CLI 只是一根
/// 管子。它长得这么短是有意的：多一件事在这里做，就多一份会和应用漂移的策略。
enum APIClientCLI {
    static let usage = """
    用法：clipa <动词> [参数]

    动词
      status                     查询接口是否开启、当前工作区、令牌作用域
      diagnose                   检测应用、接口和授权状态，不读取剪贴板正文
      connect                    打开 Clipa 的连接/重新授权页面
      workspaces                 列出已授权工作区
      search <查询…>             检索历史（排序与面板一致）
      get <id>                   读取一条
      copy <id>                  把一条放进系统剪贴板
      put --text <内容>          把内容写进历史（省略 --text 时读标准输入）
      note <id> --text <备注>    给一条写备注
      delete <id>                删除一条历史（需要 delete 作用域，不可恢复）
      collections                列出资料集
      collection-create --name 名称
      collection-rename --collection ID --name 名称
      collection-delete --collection ID
      collection-add --collection ID --ids UUID,UUID
      collection-remove --collection ID --ids UUID,UUID

      id 说明
        get/copy/note 的 id 可以只写**前几位**（唯一即可，像 git 的短哈希）；
        大小写不敏感。人类可读的 search 输出给的就是前 12 位，可以直接拿去用；
        命中多条时报错而不是随便挑一条——要完整 id 用 --json。

    参数
      --limit N        检索条数（默认 10，上限 50）
      --offset N       search 跳过前 N 条，用于翻页（配合结果末尾的提示）
      --workspace UUID 授权工作区；省略时固定使用授权中的首个工作区
      --kind TYPE      text / image / file
      --source APP     来源应用名称
      --after ISO8601  最近复制时间下界（含）
      --before ISO8601 最近复制时间上界（含）
      --max-bytes N    get 正文页大小，默认 65536，上限 262144
      --byte-offset N  get 正文字节偏移，使用返回的 next_byte_offset
      --field NAME     get 读取 text 正文或 note 备注，默认 text
      --connection ID 使用 Clipa 管理的连接；也可设置 CLIPA_CONNECTION
      --label NAME     put 的来源标签，默认用令牌名
      --token S        令牌；也可以放在 CLIPA_TOKEN 或 ~/.config/clipa/token
      --json           输出 JSON（错误也是 JSON），便于脚本解析
      --timeout S      超时秒数（默认 5）
      --no-launch      应用没在运行时不要尝试拉起它
      --help           这份说明

    退出码
      0 成功（含 0 结果）  1 参数或内部错误  2 未授权  3 接口未开启或应用未运行
      4 被策略拒绝         5 协议版本不一致
    """

    // MARK: - 入口

    static func run(arguments: [String]) -> Int32 {
        if arguments.contains("--help") || arguments.first == "help" {
            print(usage)
            return 0
        }
        // P3 修复（2026-10-03）：Options 只解析一次（原来 run 与 invoke 各一遍）。
        guard let options = Options(arguments: arguments),
              let outcome = invoke(parsed: options) else {
            FileHandle.standardError.write(Data((usage + "\n").utf8))
            return 1
        }
        return report(outcome.response, options: options)
    }

    /// 发一个请求、拿回响应与退出码，**不打印**。MCP 薄壳复用这一条路 ——
    /// 令牌解析、拉起应用、超时语义与 CLI 是同一份，不存在第二套会漂移的实现。
    static func invoke(
        arguments: [String]
    ) -> (response: APIResponse, exitCode: Int32)? {
        guard let parsed = Options(arguments: arguments) else { return nil }
        return invoke(parsed: parsed)
    }

    /// P3 修复（2026-10-03）：拆出"用已解析的选项发请求"——`run` 与薄壳各
    /// 解析一遍 Options 的重复消失，两处仍是同一条管道。
    static func invoke(
        parsed: Options
    ) -> (response: APIResponse, exitCode: Int32)? {
        guard !parsed.help, parsed.verb != nil else {
            return nil
        }

        if parsed.verb == "connect" {
            let suffix = parsed.connection.map { "?connection=" + $0.uuidString } ?? ""
            guard let url = URL(string: "clipa://connect" + suffix), NSWorkspace.shared.open(url) else {
                return (.failure(.appNotRunning, "无法打开 Clipa，请从应用程序文件夹手动打开。"), 3)
            }
            var response = APIResponse(ok: true, schema: APIContract.protocolVersion)
            response.diagnostic = APIDiagnostic(state: "approval_pending", message: "已打开 Clipa，等待用户确认授权。",
                                                recovery: "在 Clipa 中确认工作区和权限后，重新运行检测。", connectionID: parsed.connection)
            return (response, 0)
        }

        let url = APIControlServer.socketURL(
            rootDirectory: ClipStore.defaultBaseDirectory()
        )
        // 先看接口在不在，再看令牌：两句提示的可操作性不同 —— 接口没开时让人去建令牌，
        // 会把人引到错的下一步。
        if !APIControlServer.canConnect(to: url), !parsed.noLaunch,
           !Self.appIsRunning() {
            launchApp()
            for _ in 0..<20 where !APIControlServer.canConnect(to: url) {
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        guard APIControlServer.canConnect(to: url) else {
            let code: APIErrorCode = appIsRunning() ? .notEnabled : .appNotRunning
            return (
                .failure(code, code == .appNotRunning ? "Clipa 未运行" : "接口未开启，或首次引导尚未完成"),
                code.exitCode
            )
        }

        let token: String
        do { token = try resolveToken(explicit: parsed.token, connection: parsed.connection) }
        catch { return (.failure(.notAuthorized, error.localizedDescription), 2) }
        guard !token.isEmpty else {
            return (
                .failure(.notAuthorized, "没有令牌"),
                APIErrorCode.notAuthorized.exitCode
            )
        }

        var request = APIRequest()
        request.schema = APIContract.protocolVersion
        request.token = token
        request.verb = parsed.verb ?? ""
        request.args.query = parsed.query
        request.args.id = parsed.id
        request.args.text = parsed.text
        request.args.label = parsed.label
        request.args.note = parsed.note
        request.args.limit = parsed.limit
        request.args.offset = parsed.offset
        request.args.workspaceID = parsed.workspaceID
        request.args.kind = parsed.kind
        request.args.source = parsed.source
        request.args.after = parsed.after
        request.args.before = parsed.before
        request.args.maxBytes = parsed.maxBytes
        request.args.byteOffset = parsed.byteOffset
        request.args.collectionID = parsed.collectionID
        request.args.name = parsed.name
        request.args.ids = parsed.ids
        request.args.field = parsed.field

        guard var response = send(request, to: url, timeout: parsed.timeout)
        else {
            return (
                .failure(.notEnabled, "连接失败或超时"),
                APIErrorCode.notEnabled.exitCode
            )
        }
        if parsed.verb == "diagnose" {
            response.diagnostic = APIDiagnostic(state: response.ok ? "ready" : response.error?.code ?? "unknown",
                message: response.ok ? "本机接口与授权检测通过" : response.error?.message ?? "连接失败",
                recovery: response.ok ? "让 AI 客户端调用 clipa_status，确认客户端配置已加载。" : response.error?.hint ?? "在 Clipa 中重新连接。",
                connectionID: parsed.connection)
            // Diagnostics do not disclose content, counts, workspace names or scopes.
            response.status = nil
            response.count = nil
            response.workspaceID = nil
        }
        let exitCode: Int32
        if let code = response.error?.code,
           let error = APIErrorCode(rawValue: code) {
            exitCode = error.exitCode
        } else {
            exitCode = response.ok ? 0 : 1
        }
        return (response, exitCode)
    }

    // MARK: - 令牌

    static var tokenFileURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("clipa", isDirectory: true)
            .appendingPathComponent("token")
    }

    private static func resolveToken(explicit: String?, connection: UUID?) throws -> String {
        if let explicit, !explicit.isEmpty { return explicit }
        if let connection { return try ClientCredentials.read(connection).secret }
        if let environment = ProcessInfo.processInfo.environment["CLIPA_TOKEN"],
           !environment.isEmpty {
            return environment.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let text = try? String(contentsOf: tokenFileURL, encoding: .utf8) {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    // MARK: - 传输

    static func send(
        _ request: APIRequest,
        to url: URL,
        timeout: TimeInterval
    ) -> APIResponse? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        // CLI 是写请求的一方：服务端若是被杀/重启，这里的 write 不能变成
        // SIGPIPE 把 CLI 自己带走（MCP 宿主还会把它当服务器崩溃）。
        SocketProtection.disableSigPipe(fd)
        defer { close(fd) }
        var timeoutValue = timeval(
            tv_sec: Int(timeout),
            tv_usec: 0
        )
        setsockopt(
            fd,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeoutValue,
            socklen_t(MemoryLayout<timeval>.size)
        )
        setsockopt(
            fd,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &timeoutValue,
            socklen_t(MemoryLayout<timeval>.size)
        )
        guard let address = Self.address(for: url) else { return nil }
        var mutableAddress = address
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &mutableAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, size)
            }
        }
        guard connected == 0 else { return nil }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let payload = try? encoder.encode(request) else { return nil }
        var line = payload
        line.append(0x0A)
        line.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = write(
                    fd,
                    base.advanced(by: offset),
                    raw.count - offset
                )
                if written <= 0 { break }
                offset += written
            }
        }

        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while buffer.count < 4 * 1024 * 1024 {
            let count = read(fd, &chunk, chunk.count)
            if count <= 0 { break }
            buffer.append(contentsOf: chunk[0..<count])
            if buffer.contains(0x0A) { break }
        }
        guard !buffer.isEmpty else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(APIResponse.self, from: Data(buffer))
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

    /// 应用在不在跑。
    ///
    /// 这一步是**为了别白等**：只看 socket 的话，"应用开着、但接口没开"会先盲目地
    /// 去拉起应用再等满 5 秒才报错 —— 而那是最常见的一种失败，明明可以立刻回答。
    private static func appIsRunning() -> Bool {
        let identifier = "com.clipa.desktop"
        return !NSRunningApplication
            .runningApplications(withBundleIdentifier: identifier)
            .isEmpty
    }

    /// 应用没在运行时试着拉起它（**不抢焦点**：`-g`）。
    private static func launchApp() {
        var bundle = Bundle.main.bundleURL
        if bundle.pathExtension != "app", let executable = Bundle.main.executableURL {
            bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        }
        guard bundle.pathExtension == "app" else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", "-a", bundle.path]
        try? process.run()
    }

    // MARK: - 输出

    private static func report(
        _ response: APIResponse,
        options: Options
    ) -> Int32 {
        if options.json {
            print(jsonString(for: response))
        } else {
            print(humanText(for: response))
        }
        if let code = response.error?.code,
           let error = APIErrorCode(rawValue: code) {
            if !options.json {
                FileHandle.standardError.write(
                    Data((error.hint + "\n").utf8)
                )
            }
            return error.exitCode
        }
        return response.ok ? 0 : 1
    }

    static func jsonString(for response: APIResponse) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted, .sortedKeys, .withoutEscapingSlashes
        ]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(response),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    private static func humanText(for response: APIResponse) -> String {
        if let error = response.error {
            return "错误：\(error.message)"
        }
        if let diagnostic = response.diagnostic { return diagnostic.message + "\n" + diagnostic.recovery }
        if let collections = response.collections { return collections.map { "\($0.id)  \($0.name)  \($0.count) 条" }.joined(separator: "\n") }
        if let workspaces = response.workspaces { return workspaces.map { "\($0.id)  \($0.name)" }.joined(separator: "\n") }
        if let status = response.status {
            return [
                "应用：\(status.version)",
                "协议：\(status.protocolVersion)",
                "工作区：\(status.workspace)",
                "令牌：\(status.tokenLabel)",
                "作用域：\(status.scopes.joined(separator: " · "))",
                "历史条数：\(status.clipCount)",
                "含写能力：\(status.writesAllowed ? "是" : "否")"
            ].joined(separator: "\n")
        }
        if let results = response.results {
            guard !results.isEmpty else { return "（没有命中）" }
            var lines = results.map { record in
                let text = record.text.replacingOccurrences(of: "\n", with: " ")
                let snippet = text.isEmpty ? "（无正文）" : String(text.prefix(80))
                // 12 位（48 bit）而不是 8 位：8 位只有 32 bit，几万条时前缀碰撞就
                // 不再可忽略——撞上不会出错（会报"有歧义"），但会平白打扰。
                // 这段前缀现在可以**直接喂回** `get`/`copy`/`note`（见 resolve）。
                return "\(record.id.prefix(12))  \(record.sourceApp ?? "-")"
                    + "  \(record.lastCopiedAt)  \(snippet)"
            }
            // 分页提示（2026-10-01 U1）：人类可读输出不再"看起来就这些了"。
            if let total = response.total, total > results.count {
                let start = (response.offset ?? 0) + 1
                let end = (response.offset ?? 0) + results.count
                var footer = "第 \(start)–\(end) 条 · 共 \(total) 条命中"
                if let next = response.nextOffset {
                    footer += " · 继续翻页加 --offset \(next)"
                }
                lines.append(footer)
            }
            return lines.joined(separator: "\n")
        }
        if let clip = response.clip {
            return [
                "id：\(clip.id)",
                "来源：\(clip.sourceApp ?? "-")",
                "时间：\(clip.lastCopiedAt)",
                "正文：",
                clip.text.isEmpty ? "（无）" : clip.text
            ].joined(separator: "\n")
        }
        return "OK"
    }

    // MARK: - 参数

    struct Options {
        var verb: String?
        var query: String?
        var id: String?
        var text: String?
        var label: String?
        var note: String?
        var limit: Int?
        var offset: Int?
        var workspaceID: UUID?
        var connection: UUID?
        var kind: String?
        var source: String?
        var after: String?
        var before: String?
        var maxBytes: Int?
        var byteOffset: Int?
        var collectionID: UUID?
        var name: String?
        var ids: [String]?
        var field: String?
        var token: String?
        var timeout: TimeInterval = 5
        var json = false
        var help = false
        var noLaunch = false

        /// MCP passes typed parameters directly. Clipboard text is never
        /// reinterpreted as a CLI option (for example a literal "--help").
        init?(verb: String, parameters: APIRequest.Arguments) {
            self.verb = verb
            query = parameters.query; id = parameters.id; text = parameters.text; label = parameters.label
            note = parameters.note ?? (verb == "note" ? parameters.text : nil)
            limit = parameters.limit; offset = parameters.offset; workspaceID = parameters.workspaceID
            kind = parameters.kind; source = parameters.source; after = parameters.after; before = parameters.before
            maxBytes = parameters.maxBytes; byteOffset = parameters.byteOffset
            collectionID = parameters.collectionID; name = parameters.name; ids = parameters.ids
            field = parameters.field
            json = true; noLaunch = true
            if let value = ProcessInfo.processInfo.environment["CLIPA_CONNECTION"] {
                guard let id = UUID(uuidString: value) else { return nil }
                connection = id
            }
        }

        init?(arguments: [String]) {
            var rest = arguments
            guard !rest.isEmpty else { return nil }
            verb = rest.removeFirst()
            if verb == "--help" || verb == "help" {
                help = true
                return
            }
            var words: [String] = []
            if let raw = ProcessInfo.processInfo.environment["CLIPA_CONNECTION"] {
                guard let id = UUID(uuidString: raw) else { return nil }
                connection = id
            }
            var index = 0
            while index < rest.count {
                let argument = rest[index]
                func value(_ name: String) -> String? {
                    // P3 修复（2026-10-03）：值必须是**下一个真实值**——
                    // 旧实现无条件吞下一个 token，`--label --json` 会把
                    // --json 吃成 label 内容，顺带丢掉 json 开关。
                    guard index + 1 < rest.count,
                          !rest[index + 1].hasPrefix("--") else {
                        return nil
                    }
                    index += 1
                    return rest[index]
                }
                switch argument {
                case "--field": field = value(argument); if field == nil { return nil }
                case "--connection":
                    guard let raw = value(argument), let id = UUID(uuidString: raw) else { return nil }; connection = id
                case "--workspace":
                    guard let raw = value(argument), let id = UUID(uuidString: raw) else { return nil }; workspaceID = id
                case "--collection":
                    guard let raw = value(argument), let id = UUID(uuidString: raw) else { return nil }; collectionID = id
                case "--kind": kind = value(argument); if kind == nil { return nil }
                case "--source": source = value(argument); if source == nil { return nil }
                case "--after": after = value(argument); if after == nil { return nil }
                case "--before": before = value(argument); if before == nil { return nil }
                case "--name": name = value(argument); if name == nil { return nil }
                case "--ids": ids = value(argument)?.split(separator: ",").map(String.init); if ids == nil { return nil }
                case "--max-bytes": maxBytes = value(argument).flatMap(Int.init); if maxBytes == nil { return nil }
                case "--byte-offset": byteOffset = value(argument).flatMap(Int.init); if byteOffset == nil { return nil }
                case "--json": json = true
                case "--help": help = true
                case "--no-launch": noLaunch = true
                case "--limit": limit = value("--limit").flatMap(Int.init)
                case "--offset": offset = value("--offset").flatMap(Int.init)
                case "--token": token = value("--token")
                case "--text": text = value("--text")
                case "--label": label = value("--label")
                case "--note": note = value("--note")
                case "--timeout": timeout = value("--timeout").flatMap(Double.init) ?? 5
                default:
                    if argument.hasPrefix("--") {
                        // 不认识的开关：宁可报错，也不要静默忽略（脚本会以为它生效了）。
                        FileHandle.standardError.write(
                            Data("不认识的参数：\(argument)\n".utf8)
                        )
                        return nil
                    }
                    words.append(argument)
                }
                index += 1
            }
            switch verb {
            case "search":
                query = words.isEmpty ? nil : words.joined(separator: " ")
                // 常见手误：把 `--limit 50` 写成 `limit 50` —— 少了横杠的参数
                // 会被当成搜索词拼进查询，结果就是"（没有命中）"，而用户会以为
                // 历史里没数据。宁可多说一句，也不让手误静默吞掉。
                let knownFlags: Set<String> = [
                    "limit", "offset", "json", "token", "label",
                    "text", "note", "timeout", "no-launch", "help",
                ]
                let suspects = words.filter { knownFlags.contains($0) }
                if !suspects.isEmpty {
                    FileHandle.standardError.write(Data(
                        ("提示：参数要带两个横杠（如 --limit 50）；"
                            + "本次把「\(suspects.joined(separator: " "))」"
                            + "当成了搜索词。\n").utf8
                    ))
                }
            case "get", "copy", "delete":
                id = words.first
            case "note":
                id = words.first
                if note == nil { note = text }
            case "put":
                if text == nil { text = readStandardInput() }
            default:
                break
            }
            if verb == "put", text == nil {
                FileHandle.standardError.write(
                    Data("put 需要 --text 或标准输入\n".utf8)
                )
                return nil
            }
        }

        /// `--text` 省略时读标准输入：`echo "..." | clipa put` 是最顺手的写法。
        private func readStandardInput() -> String? {
            guard isatty(STDIN_FILENO) == 0 else { return nil }
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8) else {
                return nil
            }
            return text.trimmingCharacters(in: .newlines)
        }
    }
}
