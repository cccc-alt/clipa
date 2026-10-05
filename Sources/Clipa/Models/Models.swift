import Foundation

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

    var tintHex: String {
        switch self {
        case .text: return "55636E"
        case .image: return "7B61FF"
        case .file: return "7C8798"
        }
    }

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

        case 1, 2: self = .text
        default: return nil
        }
    }
}

struct Clip: Identifiable, Hashable, Sendable {
    let dbID: Int64
    let id: UUID

    var kind: ClipKind
    var text: String
    var note: String

    var imageFormat: String?
    var fileURLs: [URL]

    var sourceApp: String?

    var sourceBundle: String?

    let createdAt: Date
    var lastCopiedAt: Date
    var updatedAt: Date

    var isPrivate: Bool
    var isHidden: Bool
    var smartTag: SmartTag

    var containsSensitive: Bool

    var smartTagIsManual: Bool

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

struct NewClip {
    var id = UUID()
    var kind: ClipKind
    var text: String
    var note: String = ""

    var imageData: Data?

    var imageFormat: String?
    var fileURLs: [URL] = []
    var sourceApp: String?

    var sourceBundle: String?
    var isPrivate = false
    var contentHash: String?

    var smartTag: SmartTag?

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

struct CaptureResult {
    var kind: ClipKind
    var text: String

    var imageData: Data?
    var tiffImageData: Data?

    var imageFileURL: URL?
    var fileURLs: [URL]

    var attributedText: String? = nil

    var rtfData: Data? = nil
    var htmlData: Data? = nil

    var urlText: String? = nil
}
