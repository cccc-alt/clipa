import AppKit
import Foundation

/// 控制面的对外契约：请求 / 响应 / 错误码。
///
/// 线格式（socket 上的一行 JSON）**不是**对外承诺；承诺的是 CLI 的 `--json` 输出，
/// 以及这里列出的字段与错误码。公开第二个协议面就多一份版本管理与校验。
struct APIRequest: Codable {
    var schema: Int?
    var token: String = ""
    var verb: String = ""
    var args: Arguments = Arguments()

    struct Arguments: Codable {
        var query: String?
        var id: String?
        var text: String?
        var label: String?
        var note: String?
        var limit: Int?
        /// search 翻页：跳过前 N 条（在**过滤之后**切片）。缺省 0，
        /// 旧请求不带它行为不变 —— `schema` 不用升。
        var offset: Int?
    }
}

/// 错误码 → 退出码（CLI 直接用它，所以只有一处定义）。
enum APIErrorCode: String, Codable {
    case notEnabled = "not_enabled"
    case notAuthorized = "not_authorized"
    case denied
    case badRequest = "bad_request"
    case notFound = "not_found"
    case rateLimited = "rate_limited"
    case versionMismatch = "version_mismatch"
    case internalError = "internal"

    var exitCode: Int32 {
        switch self {
        case .notAuthorized: return 2
        case .notEnabled: return 3
        case .denied: return 4
        case .versionMismatch: return 5
        case .denied, .badRequest, .notFound, .rateLimited, .internalError:
            return 1
        }
    }

    /// 给人看的一句，能照做的那种。
    var hint: String {
        switch self {
        case .notEnabled:
            return "本地接口未开启：Clipa 菜单 → 设置… → 应用集成 → 允许授权程序访问"
        case .notAuthorized:
            return "未授权：Clipa 菜单 → 设置… → 应用集成 → 新建授权，把令牌放进 CLIPA_TOKEN"
        case .denied:
            return "这条请求被策略拒绝"
        case .rateLimited:
            return "调用过于频繁，稍后再试"
        case .versionMismatch:
            return "CLI 与应用的协议版本不一致，请更新"
        case .notFound:
            return "找不到这条记录"
        case .badRequest:
            return "请求不合法"
        case .internalError:
            return "应用内部错误"
        }
    }
}

struct APIResponse: Codable {
    var ok: Bool
    var schema: Int
    var status: Status?
    var results: [APIRecord]?
    var clip: APIRecord?
    var count: Int?
    var truncated: Bool?
    /// search 专属的一组翻页字段（2026-10-01 U1）：过滤私密后的总命中数、
    /// 本页起点、下一页起点（没有下一页就是 null）。纯加法，旧客户端照常解析。
    var total: Int?
    var offset: Int?
    var nextOffset: Int?
    var error: ErrorBody?

    struct Status: Codable {
        let version: String
        let protocolVersion: Int
        let workspace: String
        let tokenLabel: String
        let scopes: [String]
        let clipCount: Int
        let writesAllowed: Bool
    }

    struct ErrorBody: Codable {
        let code: String
        let message: String
        let hint: String
    }

    static func failure(_ code: APIErrorCode, _ message: String) -> APIResponse {
        APIResponse(
            ok: false,
            schema: APIContract.protocolVersion,
            error: ErrorBody(
                code: code.rawValue,
                message: message,
                hint: code.hint
            )
        )
    }
}

/// 对外常量。**故意不放在 `@MainActor` 类型里**：协议版本要在非隔离上下文里读
/// （CLI 构造请求、响应构造错误体），挂在 actor 上会变成"只有主线程能问版本号"。
enum APIContract {
    static let protocolVersion = 1
    /// 每个令牌每分钟的调用上限。防的是"Agent 卡在循环里把库刷爆"。
    static let rateLimitPerMinute = 60
    /// `status` 里报出的应用版本。
    ///
    /// 原先由 M1 的导出协调器提供；M1 移除后它搬到这里 —— 调用方要判断"对面是什么版本"，
    /// 而它与协议版本是两件事（应用升级不一定改协议，改协议一定动 protocolVersion）。
    ///
    /// CLI / MCP 助手是裸可执行文件，`Bundle.main` 不是 .app，读不到版本 ——
    /// 顺着可执行文件往上找所在的 .app 包，对外别报一个让人起疑的 "dev"。
    static var appVersion: String {
        let version = Bundle.main.infoDictionary?[
            "CFBundleShortVersionString"
        ] as? String
            ?? Bundle.main.executableURL.flatMap { url -> String? in
                var candidate = url
                for _ in 0..<3 {
                    candidate = candidate.deletingLastPathComponent()
                    guard candidate.pathExtension == "app",
                          let bundle = Bundle(url: candidate),
                          let value = bundle.infoDictionary?[
                              "CFBundleShortVersionString"
                          ] as? String else { continue }
                    return value
                }
                return nil
            }
            ?? "dev"
        return "Clipa \(version)"
    }
}

/// 控制面的策略层：**所有动词的唯一实现**。
///
/// socket 服务端与 `--api-probe` 都调这里，所以"探针验证过的"就是"线上跑的"——
/// 上一轮脱敏功能的教训（改了 A、渲染的是 B）不该在这里重演。
///
/// 三条硬规则集中落在这一个类型里：
/// 1. **私密条目在任何动词下都取不到**，而且对外表现为"不存在"（连"它存在"都不承认）；
/// 2. 作用域逐动词检查，写能力默认不给；
/// 3. `put` 走**与捕获完全相同的那条闸**（`ClipboardProcessor`），否则它就成了
///    "绕过 skip.md 与敏感判定"的后门。
@MainActor
final class APIControlService {
    static let protocolVersion = APIContract.protocolVersion
    static let rateLimitPerMinute = APIContract.rateLimitPerMinute

    private let store: ClipStore
    private let settings: SettingsStore
    private let rootDirectory: URL
    /// 写剪贴板的动作由外部注入：`Support` 层不引 AppKit。App 传真正的写入器（它内部
    /// 会调 `ignoreNextChange()`），探针传一个只做记录的假实现 —— 于是"私密条目绝不被
    /// 复制"这条能直接断言成"它没被调用"。
    private let copyClip: (Clip) async -> Bool
    private var callsByToken: [String: [Date]] = [:]

    init(
        store: ClipStore,
        settings: SettingsStore,
        rootDirectory: URL,
        copyClip: @escaping (Clip) async -> Bool
    ) {
        self.store = store
        self.settings = settings
        self.rootDirectory = rootDirectory
        self.copyClip = copyClip
    }

    /// 从一行 JSON 进来（socket 的入口）。解码失败就是 `bad_request`，不让异常外溢。
    func handle(
        line: String,
        peer: String,
        peerPID: pid_t? = nil
    ) async -> APIResponse {
        guard let data = line.data(using: .utf8) else {
            return .failure(.badRequest, "请求不是 UTF-8")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let request = try? decoder.decode(APIRequest.self, from: data) else {
            audit(
                tokenLabel: "-",
                peer: peer,
                verb: "?",
                query: nil,
                hits: nil,
                denied: APIErrorCode.badRequest.rawValue
            )
            return .failure(.badRequest, "请求不是合法 JSON")
        }
        return await handle(request, peer: peer, peerPID: peerPID)
    }

    /// 处理一个请求。**不碰 socket、不碰网络** —— 传进来一个请求、还回一个响应，
    /// 所以探针能直接调它。
    func handle(
        _ request: APIRequest,
        peer: String,
        peerPID: pid_t? = nil
    ) async -> APIResponse {
        let verb = request.verb.lowercased()

        if let schema = request.schema, schema != Self.protocolVersion {
            return finish(
                .failure(.versionMismatch, "请求协议版本 \(schema)，本应用是 \(Self.protocolVersion)"),
                tokenLabel: "-",
                peer: peer,
                verb: verb,
                query: nil
            )
        }
        guard settings.apiControlEnabled else {
            return finish(
                .failure(.notEnabled, "本地接口未开启"),
                tokenLabel: "-",
                peer: peer,
                verb: verb,
                query: nil
            )
        }
        guard let token = APITokenStore.shared.verify(secret: request.token) else {
            return finish(
                .failure(.notAuthorized, "令牌无效或已过期"),
                tokenLabel: "-",
                peer: peer,
                verb: verb,
                query: nil
            )
        }
        APITokenStore.shared.recordUse(id: token.id)
        guard rateLimitAllows(token: token) else {
            return finish(
                .failure(.rateLimited, "超过每分钟 \(Self.rateLimitPerMinute) 次"),
                tokenLabel: token.displayName,
                peer: peer,
                verb: verb,
                query: request.args.query
            )
        }

        let response: APIResponse
        switch verb {
        case "status":
            response = status(for: token)
        case "search":
            guard token.allows(.searchMeta) else {
                response = .failure(.notAuthorized, "缺少 search.meta 作用域")
                break
            }
            response = await search(request, token: token)
        case "get":
            response = get(request, token: token)
        case "copy":
            response = await copy(request, token: token)
        case "put":
            response = put(request, token: token, peerPID: peerPID)
        case "note":
            response = note(request, token: token)
        case "delete":
            response = deleteClip(request, token: token)
        default:
            response = .failure(.badRequest, "不认识的动词：\(request.verb)")
        }
        return finish(
            response,
            tokenLabel: token.displayName,
            peer: peer,
            verb: verb,
            query: request.args.query
        )
    }

    // MARK: - 动词

    private func status(for token: APIToken) -> APIResponse {
        var response = APIResponse(
            ok: true,
            schema: Self.protocolVersion,
            status: APIResponse.Status(
                version: APIContract.appVersion,
                protocolVersion: Self.protocolVersion,
                workspace: WorkspaceStore.shared.activeWorkspace.name,
                tokenLabel: token.label,
                scopes: token.scopes.map(\.rawValue),
                clipCount: store.items.count,
                writesAllowed: token.scopes.contains { $0.isWrite }
            )
        )
        response.count = store.items.count
        return response
    }

    private func search(
        _ request: APIRequest,
        token: APIToken
    ) async -> APIResponse {
        let query = (request.args.query ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = min(max(request.args.limit ?? 10, 1), 50)
        // 快照在 main actor 上取（O(1)），检索在后台跑 —— 与面板用的是同一条管线，
        // 因此"Agent 看到的顺序"就是"你在面板里看到的顺序"。
        let snapshot = SearchSnapshot(store: store)
        let pipeline = DefaultSearchPipeline(
            store: snapshot,
            localSearchEngine: LocalSearchEngine(
                database: snapshot.database,
                store: snapshot
            )
        )
        let outcome = await pipeline.performLocalSearchAsync(
            query: query,
            uiFilter: SearchFilter(),
            dataSource: snapshot
        )
        // 硬规则 1：私密与隐藏条目**不进结果**。面板里它们照常出现（那是给人的视角），
        // 这里是给程序的，规则不同。
        let visible = outcome.clips.filter { !$0.isPrivate && !$0.isHidden }
        let formatter = Self.formatter()
        // 分页（2026-10-01 U1）：在**过滤之后**切片 —— 私密硬规则在切片之前
        // 已经生效，翻页不可能变成绕过它的口子。
        let offset = max(request.args.offset ?? 0, 0)
        let records = visible.dropFirst(offset).prefix(limit).map {
            Self.record(
                for: $0,
                formatter: formatter,
                byteLimit: Self.snippetBytes,
                token: token
            )
        }
        var response = APIResponse(
            ok: true,
            schema: Self.protocolVersion,
            results: Array(records)
        )
        response.count = records.count
        response.total = visible.count
        response.offset = offset
        response.truncated = offset + records.count < visible.count
        if response.truncated == true {
            response.nextOffset = offset + records.count
        }
        return response
    }

    private func get(_ request: APIRequest, token: APIToken) -> APIResponse {
        // 作用域与查找要分开判：把"没这个作用域"报成"找不到这条"，用户会去查条目，
        // 而问题其实在令牌上。
        //
        // P2 修复（2026-10-03）：`get` 的承诺是"读取整条正文"，对应作用域
        // **read.full**——旧实现只查 search.text + 4096 字节截断，而剪贴板
        // 内容绝大多数短于 4KB，等于没约束（用户实测报告）。现在动词与
        // 作用域一一对应：search → search.meta（片段另需 search.text）、
        // get → read.full；只要 search.text 的令牌用 `search` 看片段。
        guard token.allows(.readFull) else {
            return .failure(
                .notAuthorized,
                "缺少 read.full 作用域（search.text 只覆盖 search 的正文片段）"
            )
        }
        guard let clip = resolve(request, token: token) else {
            return resolveFailure(request, token: token)
        }
        return APIResponse(
            ok: true,
            schema: Self.protocolVersion,
            clip: Self.record(
                for: clip,
                formatter: Self.formatter(),
                byteLimit: Int.max,
                token: token
            )
        )
    }

    private func copy(_ request: APIRequest, token: APIToken) async -> APIResponse {
        guard token.allows(.copy) else {
            return .failure(.notAuthorized, "缺少 copy 作用域")
        }
        guard let clip = resolve(request, token: token) else {
            return resolveFailure(request, token: token)
        }
        // 写剪贴板走注入的实现：App 里是现有写入器（它内部会调 `ignoreNextChange()`，
        // 所以这次复制**不会**在历史里多出一条、也不会更新已有那条）。
        guard await copyClip(clip) else {
            return .failure(.internalError, "写入剪贴板失败")
        }
        var response = APIResponse(
            ok: true,
            schema: Self.protocolVersion,
            clip: Self.record(
                for: clip,
                formatter: Self.formatter(),
                byteLimit: 0,
                token: token
            )
        )
        response.count = 1
        return response
    }

    /// 调用方宿主应用的 bundleID。peer pid 先看是不是**活着的 app 进程**
    /// （NSRunningApplication），再从可执行路径推断所在的 .app 包
    /// （`…/X.app/Contents/MacOS|Helpers/…` → X.app）。裸可执行文件
    /// （ssh、脚本解释器等无 .app 宿主）返回 nil——不猜。
    private static func hostBundleID(forPID pid: pid_t?) -> String? {
        guard let pid, pid > 0 else { return nil }
        if let running = NSWorkspace.shared.runningApplications.first(
            where: { $0.processIdentifier == pid }
        ) {
            return running.bundleIdentifier
        }
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else {
            return nil
        }
        let path = String(cString: buffer)
        // 从最内层往外找：路径里可能有嵌套 bundle。
        guard let marker = path.range(of: ".app/", options: .backwards) else {
            return nil
        }
        let bundlePath = String(path[path.startIndex..<marker.lowerBound]) + ".app"
        return Bundle(url: URL(fileURLWithPath: bundlePath))?.bundleIdentifier
    }

    private func put(
        _ request: APIRequest,
        token: APIToken,
        peerPID: pid_t? = nil
    ) -> APIResponse {
        guard token.allows(.put) else {
            return .failure(.notAuthorized, "缺少 put 作用域")
        }
        guard let text = request.args.text, !text.isEmpty else {
            return .failure(.badRequest, "缺少 text")
        }
        let label = (request.args.label?.isEmpty == false ? request.args.label : token.label)
            ?? "agent"
        // **与捕获完全同一条闸**：skip.md、敏感跳过、分类、敏感标记都由它判。
        // 少了这一步，put 就是"绕过不记录规则"的后门。
        //
        // 2026-10-04：写入条目同时归因到**调用方的宿主应用**（source_bundle）
        // ——Agent/CLI 从哪个 app 里跑（终端、CodeBuddy…），徽标就显示哪个
        // 的图标。显示名保持 "Agent: label"（用户声明的意图），bundle 只管
        // 图标解析。解析不出宿主（裸可执行）就是 nil，徽标不显示——不猜。
        let decision = ClipboardProcessor().process(
            capture: CaptureResult(kind: .text, text: text, fileURLs: []),
            sourceName: "Agent: \(label)",
            sourceBundle: Self.hostBundleID(forPID: peerPID),
            policy: CapturePolicySnapshot(settings: settings)
        )
        switch decision {
        case .captured(let draft):
            guard store.insert(draft) else {
                return .failure(.internalError, "写入失败")
            }
            if let inserted = store.clip(id: draft.id) {
                return APIResponse(
                    ok: true,
                    schema: Self.protocolVersion,
                    clip: Self.record(
                        for: inserted,
                        formatter: Self.formatter(),
                        byteLimit: 0,
                        token: token
                    )
                )
            }
            return APIResponse(ok: true, schema: Self.protocolVersion)
        case .sensitiveSkipped:
            return .failure(.denied, "被「跳过疑似敏感内容」拒绝")
        case .paused:
            return .failure(.denied, "记录已暂停")
        case .confidentialSkipped, .ignoredSource, .noContent:
            return .failure(.denied, "这条内容不记录")
        }
    }

    private func note(_ request: APIRequest, token: APIToken) -> APIResponse {
        guard token.allows(.note) else {
            return .failure(.notAuthorized, "缺少 note 作用域")
        }
        guard let clip = resolve(request, token: token) else {
            return resolveFailure(request, token: token)
        }
        guard let note = request.args.note else {
            return .failure(.badRequest, "缺少 note")
        }
        guard store.setNote(note, for: clip) else {
            return .failure(.internalError, "写备注失败")
        }
        return APIResponse(ok: true, schema: Self.protocolVersion)
    }

    /// 删除一条历史。**高危写动词**：作用域单独一把锁（`delete`，默认不授予），
    /// 私密/隐藏条目走与读取相同的"按不存在处理"——能读到才删得掉，这同时意味着
    /// "猜不出的 id 删不了东西"。审计照常落一条（不含正文），限流照常计数。
    private func deleteClip(
        _ request: APIRequest,
        token: APIToken
    ) -> APIResponse {
        guard token.allows(.delete) else {
            return .failure(.notAuthorized, "缺少 delete 作用域")
        }
        guard let clip = resolve(request, token: token) else {
            return resolveFailure(request, token: token)
        }
        switch store.delete(clip) {
        case .deleted:
            var response = APIResponse(
                ok: true,
                schema: Self.protocolVersion
            )
            response.count = 1
            return response
        case .failed:
            return .failure(.internalError, "删除失败")
        }
    }

    // MARK: - 查找与拒绝

    /// 找到一个条目：`id` 可以是完整 UUID，也可以只是**前几位**（唯一即命中）。
    ///
    /// 前缀匹配是必须的，因为 CLI 的人类可读输出打印的就是 id 的前 8 位。原先只认
    /// 完整 UUID，于是那份输出给出的是个**没法用的 id**：照着它敲 `copy` 只会得到
    /// "找不到这条记录"。`--json` 那条路一直是完整的，所以这个缺陷只在人手敲的时候
    /// 露出来——正是最容易被测试漏掉的形状。
    ///
    /// 私密/隐藏条目按**不存在**处理：连"它存在"都不承认，免得 id 变成探测私密内容
    /// 的工具。前缀匹配**只在可见条目里做**，因为"前缀有歧义"这条错误本身就能泄露
    /// 一个私密 id 的存在（见 `resolveFailure`）。
    private func resolve(
        _ request: APIRequest,
        token: APIToken
    ) -> Clip? {
        guard let raw = request.args.id else { return nil }
        let needle = Self.normalizedID(raw)
        guard !needle.isEmpty else { return nil }
        if let uuid = UUID(uuidString: needle),
           let clip = store.clip(id: uuid) {
            guard !clip.isPrivate, !clip.isHidden else { return nil }
            return clip
        }
        let matches = visibleClips(matchingPrefix: needle)
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    /// `id` 参数归一化：大小写不敏感、容忍首尾空白（Agent 拼字符串时最容易带进来）。
    private static func normalizedID(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// 可见条目里 id 前缀命中 `prefix` 的那些。
    private func visibleClips(matchingPrefix prefix: String) -> [Clip] {
        store.items.filter { clip in
            guard !clip.isPrivate, !clip.isHidden else { return false }
            return clip.id.uuidString.lowercased().hasPrefix(prefix)
        }
    }

    private func resolveFailure(
        _ request: APIRequest,
        token: APIToken
    ) -> APIResponse {
        guard let raw = request.args.id else {
            return .failure(.badRequest, "缺少 id")
        }
        let needle = Self.normalizedID(raw)
        let matches = visibleClips(matchingPrefix: needle).count
        if matches > 1 {
            // 只统计**可见**条目：私密条目也计入的话，"有歧义"会变成"存在一个私密
            // 条目，它的 id 以这几位开头"。
            return .failure(
                .badRequest,
                "id 前缀有歧义：\(matches) 条命中，多写几位"
            )
        }
        return .failure(.notFound, "找不到这条记录")
    }

    // MARK: - 记录与审计

    /// search 正文片段上限（2026-10-03 从 200 定为 64）：64 字节 = 中文约
    /// 21 字或 ASCII 64 字符——够辨认是哪条内容、不够把整篇读走；取正文
    /// 走 `get`（需 read.full）。`bounded` 按字符边界切，不产出坏字节。
    private static let snippetBytes = 64

    private static func formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone.current
        return formatter
    }

    /// 字段映射集中在 `APIRecord.make` —— 形状只有一处。
    ///
    /// （原先快照与控制面共用它，理由是"两条路别给同一个字段写不同的名字"。M1 已于
    /// 2026-09-26 移除，这条理由对剩下的控制面同样成立。）
    ///
    /// `redacted` 这个字段**留在协议里**、恒为 false：规则包（`redact.md`）已于
    /// 2026-09-27 删除，控制面不再对正文做任何遮蔽 —— 但字段本身是外部契约的一部分，
    /// 删掉会让客户端解析出错，所以保留并如实返回 false。
    private static func record(
        for clip: Clip,
        formatter: ISO8601DateFormatter,
        byteLimit: Int,
        token: APIToken
    ) -> APIRecord {
        let canSeeBody = clip.kind == .text
            && (token.allows(.searchText) || token.allows(.readFull))
        let bounded = APIRecord.bounded(
            canSeeBody ? clip.text : "",
            bytes: byteLimit
        )
        return APIRecord.make(
            for: clip,
            formatter: formatter,
            body: bounded.text,
            note: APIRecord.bounded(clip.note, bytes: APIRecord.Limits.noteBytes).text,
            redacted: false,
            truncated: bounded.truncated
        )
    }

    private func rateLimitAllows(token: APIToken) -> Bool {
        let now = Date()
        let window = now.addingTimeInterval(-60)
        var recent = (callsByToken[token.id] ?? []).filter { $0 > window }
        guard recent.count < Self.rateLimitPerMinute else {
            callsByToken[token.id] = recent
            return false
        }
        recent.append(now)
        callsByToken[token.id] = recent
        return true
    }

    private func finish(
        _ response: APIResponse,
        tokenLabel: String,
        peer: String,
        verb: String,
        query: String?
    ) -> APIResponse {
        audit(
            tokenLabel: tokenLabel,
            peer: peer,
            verb: verb,
            query: query,
            hits: response.count ?? response.results?.count,
            denied: response.ok ? nil : response.error?.code
        )
        return response
    }

    private func audit(
        tokenLabel: String,
        peer: String,
        verb: String,
        query: String?,
        hits: Int?,
        denied: String?
    ) {
        let trimmed = query.map { String($0.prefix(80)) }
        APIAuditLog.append(
            APIAuditLog.Entry(
                at: Date(),
                token: tokenLabel,
                peer: peer,
                verb: verb,
                query: (trimmed?.isEmpty == false) ? trimmed : nil,
                hits: hits,
                denied: denied
            ),
            rootDirectory: rootDirectory
        )
    }
}
