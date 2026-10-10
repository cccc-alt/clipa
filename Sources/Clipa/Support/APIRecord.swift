import Foundation

/// 控制面（M2）对外的一条记录。字段名对外是契约（`snake_case`），见设计稿第 6 节。
///
/// 这里原本叫 `APIExport`，装的是 M1「只读导出」的快照生成器。M1 已于 2026-09-26 移除
/// —— 它是唯一一条**不需要令牌**的读取通道（盘上一个 `0600` 的明文 JSON，任何同 uid 的
/// 进程 `cat` 就能读，既不授权也不进审计），与"控制面成为唯一合法读数路径"直接冲突。
///
/// 留下的是控制面在用的部分：记录形状、大小上限、字节截断。名字跟着改成它现在做的事 ——
/// 留一个叫"导出"的类型却没有任何导出功能，下一个读代码的人会先被误导。
struct APIRecord: Codable, Equatable {
    let id: String
    let kind: String
    let createdAt: String
    let lastCopiedAt: String
    let sourceApp: String?
    let smartTag: String
    /// 命中内置敏感判定（面板上那个 🔐）。
    let sensitive: Bool
    /// 这条的正文**确实被 `redact.md` 改过**（不是"有规则存在"，是"这条被遮了"）。
    let redacted: Bool
    /// 正文因为超过单条上限被截断。
    let truncated: Bool
    /// 脱敏后的正文。图片/文件条目为空——**文件路径刻意不给出**：
    /// 那会把"别人的目录结构"递出去，还会让这个接口变成文件读取器的入口。
    let text: String
    let note: String
}

extension APIRecord {
    /// 单条上限。存在是为了让"每条请求的响应有上界"这件事写死在代码里，而不是靠调用方自律。
    enum Limits {
        static let bodyBytes = 4096
        static let noteBytes = 512
    }

    /// 一条记录的字段映射 —— 控制面只有这一处形状。
    ///
    /// 原先快照与控制面共用它，理由是"两条路给同一个字段写不同的名字，是'看起来有契约、
    /// 实际各说各话'的经典成因"。M1 走了，这条理由对剩下的这一条路同样成立。
    static func make(
        for clip: Clip,
        formatter: ISO8601DateFormatter,
        body: String,
        note: String,
        redacted: Bool,
        truncated: Bool
    ) -> APIRecord {
        APIRecord(
            id: clip.id.uuidString,
            kind: clip.kind.rawValue,
            createdAt: formatter.string(from: clip.createdAt),
            lastCopiedAt: formatter.string(from: clip.lastCopiedAt),
            sourceApp: clip.sourceApp,
            smartTag: clip.smartTag.rawValue,
            sensitive: clip.containsSensitive,
            redacted: redacted,
            truncated: truncated,
            text: body,
            note: note
        )
    }

    /// 按 **UTF-8 字节**截断（上限说的是字节，不是字符——一个 emoji 是 4 字节）。
    static func bounded(
        _ text: String,
        bytes: Int
    ) -> (text: String, truncated: Bool) {
        guard bytes >= 0 else { return ("", false) }
        guard bytes < Int.max, text.utf8.count > bytes else {
            return (text, false)
        }
        var result = ""
        var used = 0
        for character in text {
            let size = String(character).utf8.count
            if used + size > bytes { return (result, true) }
            result.append(character)
            used += size
        }
        return (result, false)
    }
}
