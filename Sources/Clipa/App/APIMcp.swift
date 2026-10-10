import Foundation

/// MCP stdio 薄壳：把 Model Context Protocol 的 `tools/call` 翻译成对 CLI 管道的调用。
///
/// **它不碰数据库、不认识令牌、不判任何策略** —— 令牌解析、作用域、私密硬排除、
/// 审计、限流全部发生在应用进程里（CLI 的 `invoke` → socket → `APIControlService`）。
/// 这里只是把 JSON-RPC 的参数拼成 `clipa` 的参数。M1「只读导出」的教训：
/// 凡是第二条绕过授权与审计的通道，最后都得删 —— 所以薄壳刻意薄到没有资格藏东西。
///
/// 传输：MCP stdio 是**按行分隔的 JSON-RPC**。读一行、回一行、`fflush`（stdout
/// 接管道时是块缓冲，不冲刷客户端就永远等不到回包）。
///
/// 接入（Claude Code / Cursor 等）：
///
///     { "mcpServers": { "clipa": { "command": "/Applications/Clipa.app/Contents/Helpers/clipa-mcp" } } }
///
/// 令牌与 CLI 同源：`CLIPA_TOKEN` 或 `~/.config/clipa/token`。
enum APIMcp {
    /// 客户端没带版本时用的兜底。带了就用双方都认识的最新版。
    private static let defaultProtocolVersion = "2024-11-05"
    private static let knownProtocolVersions = [
        "2024-11-05", "2025-03-26", "2025-06-18",
    ]

    /// 读一行 stdin，**上限 64KB**（P2 修复 2026-10-03）。MCP 请求是 JSON 行，
    /// 恶意/失控的宿主喂一条超长行时不再把内存吃光——超限部分丢弃，截断后的
    /// 残行由 JSON 解码报错回给对方。EOF 且无内容返回 nil。
    private static func readCappedLine(maxBytes: Int = 64 * 1024) -> String? {
        var data = Data()
        var byte: UInt8 = 0
        while true {
            let count = read(0, &byte, 1)
            if count <= 0 {
                return data.isEmpty
                    ? nil
                    : String(decoding: data, as: UTF8.self)
            }
            if byte == 0x0A { break }
            if data.count < maxBytes { data.append(byte) }
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func run() -> Int32 {
        while true {
            guard let line = readCappedLine() else {
                return 0
            }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let data = trimmed.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data))
                      as? [String: Any] else {
                write(error: -32700, message: "Parse error", id: NSNull())
                continue
            }
            let id = object["id"] ?? NSNull()
            guard let method = object["method"] as? String else {
                write(error: -32600, message: "Invalid Request", id: id)
                continue
            }
            // 通知没有 id：按协议不回包。
            guard object["id"] != nil else { continue }
            switch method {
            case "initialize":
                let requested = (object["params"] as? [String: Any])?[
                    "protocolVersion"
                ] as? String
                let version = requested.flatMap {
                    knownProtocolVersions.contains($0) ? $0 : nil
                } ?? defaultProtocolVersion
                write(result: [
                    "protocolVersion": version,
                    "capabilities": ["tools": [String: Any]()],
                    "serverInfo": [
                        "name": "clipa",
                        "version": APIContract.appVersion,
                    ],
                ], id: id)
            case "tools/list":
                write(result: ["tools": tools], id: id)
            case "tools/call":
                handleCall(object, id: id)
            case "ping":
                write(result: [String: Any](), id: id)
            default:
                write(
                    error: -32601,
                    message: "Method not found: \(method)",
                    id: id
                )
            }
        }
    }

    // MARK: - tools/call

    private static func handleCall(_ object: [String: Any], id: Any) {
        guard let params = object["params"] as? [String: Any],
              let name = params["name"] as? String else {
            write(error: -32602, message: "缺少 params.name", id: id)
            return
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        guard let argv = argv(for: name, arguments: arguments) else {
            write(result: [
                "content": [[
                    "type": "text",
                    "text": "未知工具或参数不合法：\(name)",
                ]],
                "isError": true,
            ], id: id)
            return
        }
        guard let outcome = APIClientCLI.invoke(arguments: argv) else {
            write(result: [
                "content": [["type": "text", "text": "参数不合法"]],
                "isError": true,
            ], id: id)
            return
        }
        write(result: [
            "content": [[
                "type": "text",
                "text": APIClientCLI.jsonString(for: outcome.response),
            ]],
            "isError": outcome.exitCode != 0,
        ], id: id)
    }

    /// 工具名 → CLI 参数。六个工具与六个动词一一对应；MCP 是给程序用的，
    /// 一律 `--json`，并且 `--no-launch`（应用没在跑就该立刻失败让 Agent
    /// 转告用户，而不是替用户悄悄拉起应用再等五秒）。
    private static func argv(
        for name: String,
        arguments: [String: Any]
    ) -> [String]? {
        func string(_ key: String) -> String? {
            (arguments[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        func int(_ key: String) -> Int? {
            // P2 修复（2026-10-03）：数字参数的类型容错——有的客户端把
            // limit/offset 发成 "10"（字符串）或 10.0，旧实现静默丢弃，
            // Agent 以为自己设了限制、实际用了默认值。
            switch arguments[key] {
            case let value as Int: return value
            case let value as Double: return Int(value)
            case let value as String: return Int(value)
            default: return nil
            }
        }

        let base: [String]
        switch name {
        case "clipa_status":
            base = ["status"]
        case "search_clips":
            var argv = ["search"]
            if let query = string("query") { argv.append(query) }
            if let limit = int("limit") { argv += ["--limit", String(limit)] }
            if let offset = int("offset") {
                argv += ["--offset", String(offset)]
            }
            base = argv
        case "get_clip":
            guard let id = string("id") else { return nil }
            base = ["get", id]
        case "copy_clip":
            guard let id = string("id") else { return nil }
            base = ["copy", id]
        case "put_clip":
            guard let text = string("text") else { return nil }
            var argv = ["put", "--text", text]
            if let label = string("label") { argv += ["--label", label] }
            base = argv
        case "add_note":
            guard let id = string("id"), let text = string("text") else {
                return nil
            }
            base = ["note", id, "--text", text]
        case "delete_clip":
            guard let id = string("id") else { return nil }
            base = ["delete", id]
        default:
            return nil
        }
        return base + ["--json", "--no-launch"]
    }

    // MARK: - 工具清单

    private static let tools: [[String: Any]] = [
        [
            "name": "clipa_status",
            "description": "查看 Clipa 本地接口状态：应用版本、当前工作区、令牌作用域、历史条数",
            "inputSchema": [
                "type": "object",
                "properties": [String: Any](),
            ],
        ],
        [
            "name": "search_clips",
            "description": "检索剪贴板历史（排序与 Clipa 面板一致）。返回元信息与正文片段；"
                + "私密条目在任何查询下都不可见。用 offset 翻页（看响应里的 next_offset 与 total）。",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "关键词；缺省或空串 = 最近的记录",
                    ],
                    "limit": [
                        "type": "integer",
                        "description": "每页条数（默认 10，上限 50）",
                    ],
                    "offset": [
                        "type": "integer",
                        "description": "跳过前 N 条，用于翻页",
                    ],
                ],
            ],
        ],
        [
            "name": "get_clip",
            "description": "读取一条的完整正文。id 可以只写 search 结果里的前几位（唯一即可）。",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "完整 id 或唯一前缀"],
                ],
                "required": ["id"],
            ],
        ],
        [
            "name": "copy_clip",
            "description": "把一条放进系统剪贴板（等价于用户在面板里按了回车），用户在目标应用 ⌘V 粘贴。",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "完整 id 或唯一前缀"],
                ],
                "required": ["id"],
            ],
        ],
        [
            "name": "put_clip",
            "description": "把一段文本写进剪贴板历史。走与手动复制完全相同的闸："
                + "疑似敏感、机密标记、暂停记录状态下都会被拒绝。",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "text": ["type": "string", "description": "要写入的内容"],
                    "label": [
                        "type": "string",
                        "description": "来源标签，缺省用令牌名",
                    ],
                ],
                "required": ["text"],
            ],
        ],
        [
            "name": "add_note",
            "description": "给一条历史写备注（备注参与检索，之后 search 能按它命中）。",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "完整 id 或唯一前缀"],
                    "text": ["type": "string", "description": "备注内容"],
                ],
                "required": ["id", "text"],
            ],
        ],
        [
            "name": "delete_clip",
            "description": "从历史中删除一条，**不可恢复**。令牌必须带 delete 作用域"
                + "（默认不授予）；私密条目对任何工具都不可见也不可删。",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "完整 id 或唯一前缀"],
                ],
                "required": ["id"],
            ],
        ],
    ]

    // MARK: - 输出

    private static func write(result: [String: Any], id: Any) {
        write([
            "jsonrpc": "2.0",
            "id": id,
            "result": result,
        ])
    }

    private static func write(error code: Int, message: String, id: Any) {
        write([
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": code, "message": message],
        ])
    }

    private static func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object
        ), let line = String(data: data, encoding: .utf8) else { return }
        fputs(line + "\n", stdout)
        // stdout 接管道时是块缓冲：不冲刷，客户端就永远等不到这一行。
        fflush(stdout)
    }

    // MARK: - 客户端接入配置生成（新建令牌弹窗的一键复制）

    /// Cursor：`~/.cursor/mcp.json` 的可合并片段（JSON）。内嵌令牌——
    /// 粘贴进客户端配置后无需再配 CLIPA_TOKEN。
    static func cursorConfig(token: String, helperPath: String) -> String {
        let payload: [String: Any] = [
            "mcpServers": [
                "clipa": [
                    "command": helperPath,
                    "env": ["CLIPA_TOKEN": token],
                ]
            ]
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        ), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    /// Codex：`~/.codex/config.toml` 的可合并片段（TOML）。
    static func codexConfig(token: String, helperPath: String) -> String {
        """
        [mcp_servers.clipa]
        command = "\(helperPath)"
        env = { CLIPA_TOKEN = "\(token)" }
        """
    }
}
