import Foundation

// MARK: - Clip kinds

enum ClipKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case text
    case image
    case file

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .text: return "文本"
        case .image: return "图片"
        case .file: return "文件"
        }
    }

    var symbolName: String {
        switch self {
        case .text: return "text.alignleft"
        case .image: return "photo"
        case .file: return "doc"
        }
    }

    /// 类型标签的**类型色**（毛玻璃风：冷色一侧的板岩、紫、蓝灰）。
    ///
    /// 这一项在黑白线稿那一版被 `strokeDash` 取代过（那时没有色相可用），
    /// 随后又换回来。这条链路说明的是一件事：**颜色始终是首选线索**，
    /// 只有拿掉色相时才退而求其次用线的形态。
    var tintHex: String {
        switch self {
        case .text: return "55636E"
        case .image: return "7B61FF"
        case .file: return "7C8798"
        }
    }

    /// Stable integer encoding used by the `clips.kind` column.
    ///
    /// Kept at its historical values so existing rows load without a rewrite.
    /// The retired `link` (1) and `code` (2) encodings are folded into `text`
    /// when decoding, and the v3 migration rewrites those rows in place.
    var databaseValue: Int {
        switch self {
        case .text: return 0
        case .image: return 3
        case .file: return 4
        }
    }

    init?(databaseValue: Int) {
        switch databaseValue {
        case 0: self = .text
        case 3: self = .image
        case 4: self = .file
        // Retired coarse kinds from the pre-v3 taxonomy: a link or a code
        // clip is now plain text.
        case 1, 2: self = .text
        default: return nil
        }
    }
}

// MARK: - Clip

/// Application-facing clipboard item.
///
/// `dbID` is the SQLite/FTS row identity (internal, stable within the store);
/// `id` is the UUID used by the UI and by future cross-device sync.
struct Clip: Identifiable, Hashable, Sendable {
    let dbID: Int64
    let id: UUID

    var kind: ClipKind
    var text: String
    var note: String

    /// UTI of the stored image bytes (e.g. `public.png`). The bytes live in
    /// the `clips.image_blob` column and are loaded on demand, so row reads
    /// never pull megabytes of image data into the list model.
    var imageFormat: String?
    var fileURLs: [URL]

    var sourceApp: String?
    /// 来源应用的 bundle identifier（2026-10-04 起捕获时落库）。与
    /// `sourceApp`（本地化显示名）相比：跨系统语言稳定、应用改名不受影响，
    /// 徽标图标解析优先走它（`urlForApplication(withBundleIdentifier:)`），
    /// 解析不到再回退名字索引。旧行此列为 NULL。
    var sourceBundle: String?

    let createdAt: Date
    var lastCopiedAt: Date
    var updatedAt: Date

    /// 私密：正文与备注以密文落盘（M3，密钥在本机钥匙串），显示层同时遮挡。
    /// 遮挡只是它的一半——落盘形态见 `StoreCrypto`，产品口径见 `PrivacyGate`。
    var isPrivate: Bool
    var isHidden: Bool
    var smartTag: SmartTag
    /// Precomputed expanded sensitive marker (body + note), read from DB.
    var containsSensitive: Bool
    /// True when `smartTag` was manually set by the user.
    var smartTagIsManual: Bool
    /// Classifier version that produced the stored auto classification.
    var classificationVersion: Int

    var contentHash: String?

    init(
        dbID: Int64,
        id: UUID,
        kind: ClipKind,
        text: String,
        note: String = "",
        imageFormat: String? = nil,
        fileURLs: [URL] = [],
        sourceApp: String? = nil,
        sourceBundle: String? = nil,
        createdAt: Date,
        lastCopiedAt: Date,
        updatedAt: Date,
        isPrivate: Bool = false,
        isHidden: Bool = false,
        smartTag: SmartTag = .text,
        contentHash: String? = nil,
        containsSensitive: Bool = false,
        smartTagIsManual: Bool = false,
        classificationVersion: Int = 0
    ) {
        self.dbID = dbID
        self.id = id
        self.kind = kind
        self.text = text
        self.note = note
        self.imageFormat = imageFormat
        self.fileURLs = fileURLs
        self.sourceApp = sourceApp
        self.sourceBundle = sourceBundle
        self.createdAt = createdAt
        self.lastCopiedAt = lastCopiedAt
        self.updatedAt = updatedAt
        self.isPrivate = isPrivate
        self.isHidden = isHidden
        self.smartTag = smartTag
        self.containsSensitive = containsSensitive
        self.smartTagIsManual = smartTagIsManual
        self.classificationVersion = classificationVersion
        self.contentHash = contentHash
    }

    var hasNote: Bool { !note.isEmpty }

    var displayText: String {
        if !text.isEmpty { return text }
        switch kind {
        case .image: return "图片（点击查看）"
        case .file:
            return fileURLs.map(\.lastPathComponent).joined(separator: ", ")
        default:
            return "（空内容）"
        }
    }

    var oneLineSnippet: String {
        let t = displayText.replacingOccurrences(of: "\n", with: " ")
        return t.count > 90 ? String(t.prefix(90)) + "…" : t
    }
}

/// Unsaved clipboard payload produced by the clipboard pipeline. `dbID` does
/// not exist yet; DatabaseManager assigns it inside the insert transaction.
struct NewClip {
    var id = UUID()
    var kind: ClipKind
    var text: String
    var note: String = ""
    /// Original image bytes, persisted into `clips.image_blob`. Clipa no
    /// longer re-encodes images, so this is the source payload as captured
    /// (only a pasted TIFF is converted to PNG before it reaches this point).
    var imageData: Data?
    /// UTI of `imageData` (`public.png`, `public.jpeg`, …).
    var imageFormat: String?
    var fileURLs: [URL] = []
    var sourceApp: String?
    /// 来源应用 bundle identifier（捕获端 attribution 已有，2026-10-04 起
    /// 一并落库——见 `Clip.sourceBundle`）。
    var sourceBundle: String?
    var isPrivate = false
    var contentHash: String?
    /// Precomputed classification produced by the capture pipeline. When nil,
    /// persistence falls back to classifying at insert time (tests/demos and
    /// other non-capture callers).
    var smartTag: SmartTag?
    /// Precomputed expanded sensitive marker. When nil, persistence detects
    /// it once at insert time.
    var containsSensitive: Bool?

    init(
        id: UUID = UUID(),
        kind: ClipKind,
        text: String,
        note: String = "",
        imageData: Data? = nil,
        imageFormat: String? = nil,
        fileURLs: [URL] = [],
        sourceApp: String? = nil,
        sourceBundle: String? = nil,
        isPrivate: Bool = false,
        contentHash: String? = nil,
        smartTag: SmartTag? = nil,
        containsSensitive: Bool? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.note = note
        self.imageData = imageData
        self.imageFormat = imageFormat
        self.fileURLs = fileURLs
        self.sourceApp = sourceApp
        self.sourceBundle = sourceBundle
        self.isPrivate = isPrivate
        self.contentHash = contentHash
        self.smartTag = smartTag
        self.containsSensitive = containsSensitive
    }
}

// MARK: - Capture result (used by monitor and self-test)

struct CaptureResult {
    var kind: ClipKind
    var text: String
    /// PNG payload. Pasteboard inspection keeps this representation; TIFF
    /// bytes are kept separately because PNG conversion is CPU-heavy and is
    /// deferred to the background capture queue.
    var imageData: Data?
    var tiffImageData: Data?
    /// Set when Finder/file manager copy exposes exactly one image file URL.
    /// The background queue reads the original bytes (no re-encode) so the
    /// source image becomes a Clipa-owned image clip, like a screenshot.
    var imageFileURL: URL?
    var fileURLs: [URL]
    /// Already-decoded string from an `NSAttributedString` pasteboard flavor.
    var attributedText: String? = nil
    /// Raw RTF/HTML bytes. Kept undecoded on purpose: `RichTextDecoder` runs on
    /// the capture queue (the HTML importer is slow) and sanitizes HTML first
    /// (it would otherwise fetch remote subresources).
    var rtfData: Data? = nil
    var htmlData: Data? = nil
    /// `public.url` string, used only when no text flavor carried anything.
    var urlText: String? = nil
}
