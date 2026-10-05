import AppKit
import Darwin
import Foundation

enum APIClientCLI {
    static let usage = """
    用法：clipa <动词> [参数]

    动词
      status                     查询接口是否开启、当前工作区、令牌作用域
      search <查询…>             检索历史（排序与面板一致）
      get <id>                   读取一条
      copy <id>                  把一条放进系统剪贴板
      put --text <内容>          把内容写进历史（省略 --text 时读标准输入）
      note <id> --text <备注>    给一条写备注
      delete <id>                删除一条历史（需要 delete 作用域，不可恢复）

      id 说明
        get/copy/note 的 id 可以只写**前几位**（唯一即可，像 git 的短哈希）；
        大小写不敏感。人类可读的 search 输出给的就是前 12 位，可以直接拿去用；
        命中多条时报错而不是随便挑一条——要完整 id 用 --json。

    参数
      --limit N        检索条数（默认 10，上限 50）
      --offset N       search 跳过前 N 条，用于翻页（配合结果末尾的提示）
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

    static func run(arguments: [String]) -> Int32 {
        if arguments.contains("--help") || arguments.first == "help" {
            print(usage)
            return 0
        }

        guard let options = Options(arguments: arguments),
              let outcome = invoke(parsed: options) else {
            FileHandle.standardError.write(Data((usage + "\n").utf8))
            return 1
        }
        return report(outcome.response, options: options)
    }

    static func invoke(
        arguments: [String]
    ) -> (response: APIResponse, exitCode: Int32)? {
        guard let parsed = Options(arguments: arguments) else { return nil }
        return invoke(parsed: parsed)
    }

    static func invoke(
        parsed: Options
    ) -> (response: APIResponse, exitCode: Int32)? {
        guard !parsed.help, parsed.verb != nil else {
            return nil
        }

        let url = APIControlServer.socketURL(
            rootDirectory: ClipStore.defaultBaseDirectory()
        )

        if !APIControlServer.canConnect(to: url), !parsed.noLaunch,
           !Self.appIsRunning() {
            launchApp()
            for _ in 0..<20 where !APIControlServer.canConnect(to: url) {
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        guard APIControlServer.canConnect(to: url) else {
            return (
                .failure(.notEnabled, "应用未在运行，或控制面未开启"),
                APIErrorCode.notEnabled.exitCode
            )
        }

        let token = resolveToken(explicit: parsed.token)
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

        guard let response = send(request, to: url, timeout: parsed.timeout)
        else {
            return (
                .failure(.notEnabled, "连接失败或超时"),
                APIErrorCode.notEnabled.exitCode
            )
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

    static var tokenFileURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("clipa", isDirectory: true)
            .appendingPathComponent("token")
    }

    private static func resolveToken(explicit: String?) -> String {
        if let explicit, !explicit.isEmpty { return explicit }
        if let environment = ProcessInfo.processInfo.environment["CLIPA_TOKEN"],
           !environment.isEmpty {
            return environment.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let text = try? String(contentsOf: tokenFileURL, encoding: .utf8) {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    static func send(
        _ request: APIRequest,
        to url: URL,
        timeout: TimeInterval
    ) -> APIResponse? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

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

    private static func appIsRunning() -> Bool {
        guard let identifier = Bundle.main.bundleIdentifier else { return false }
        return !NSRunningApplication
            .runningApplications(withBundleIdentifier: identifier)
            .isEmpty
    }

    private static func launchApp() {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", "-a", bundle.path]
        try? process.run()
    }

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

                return "\(record.id.prefix(12))  \(record.sourceApp ?? "-")"
                    + "  \(record.lastCopiedAt)  \(snippet)"
            }

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

    struct Options {
        var verb: String?
        var query: String?
        var id: String?
        var text: String?
        var label: String?
        var note: String?
        var limit: Int?
        var offset: Int?
        var token: String?
        var timeout: TimeInterval = 5
        var json = false
        var help = false
        var noLaunch = false

        init?(arguments: [String]) {
            var rest = arguments
            guard !rest.isEmpty else { return nil }
            verb = rest.removeFirst()
            if verb == "--help" || verb == "help" {
                help = true
                return
            }
            var words: [String] = []
            var index = 0
            while index < rest.count {
                let argument = rest[index]
                func value(_ name: String) -> String? {

                    guard index + 1 < rest.count,
                          !rest[index + 1].hasPrefix("--") else {
                        return nil
                    }
                    index += 1
                    return rest[index]
                }
                switch argument {
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
