import AppKit
import Foundation

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

        var offset: Int?
    }
}

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

    var hint: String {
        switch self {
        case .notEnabled:
            return "本地接口未开启：Clipa 菜单 → 本地接口 → 开启控制面"
        case .notAuthorized:
            return "未授权：Clipa 菜单 → 本地接口 → 新建令牌…，把令牌放进 CLIPA_TOKEN"
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

enum APIContract {
    static let protocolVersion = 1

    static let rateLimitPerMinute = 60

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

@MainActor
final class APIControlService {
    static let protocolVersion = APIContract.protocolVersion
    static let rateLimitPerMinute = APIContract.rateLimitPerMinute

    private let store: ClipStore
    private let settings: SettingsStore
    private let rootDirectory: URL

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

        let visible = outcome.clips.filter { !$0.isPrivate && !$0.isHidden }
        let formatter = Self.formatter()

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

    private static func normalizedID(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

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

            return .failure(
                .badRequest,
                "id 前缀有歧义：\(matches) 条命中，多写几位"
            )
        }
        return .failure(.notFound, "找不到这条记录")
    }

    private static let snippetBytes = 64

    private static func formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone.current
        return formatter
    }

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
