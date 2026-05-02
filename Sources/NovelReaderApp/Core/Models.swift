import Foundation
import SwiftUI

enum ReadingStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case unread
    case reading
    case finished

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unread: "未读"
        case .reading: "在读"
        case .finished: "已读"
        }
    }
}

enum BookFormat: String, Codable, CaseIterable, Sendable {
    case txt
    case epub
    case web
}

struct Book: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var title: String
    var author: String
    var summary: String
    var coverSymbol: String
    var coverImageURL: URL?
    var format: BookFormat
    var sourceName: String
    var localURL: URL?
    var remoteBookURL: URL?
    /// The original, unmodified bookUrl string from the reader server.
    /// `URL.absoluteString` percent-encodes characters like `{`, `}`, `"` which
    /// breaks books whose URL contains embedded JSON (e.g. 阅读助手 source).
    var remoteBookURLString: String?
    var isReaderServerBacked: Bool?
    var status: ReadingStatus
    var progress: ReadingProgress
    var chapters: [Chapter]
    var addedAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        author: String,
        summary: String,
        coverSymbol: String,
        coverImageURL: URL? = nil,
        format: BookFormat,
        sourceName: String,
        localURL: URL?,
        remoteBookURL: URL? = nil,
        remoteBookURLString: String? = nil,
        isReaderServerBacked: Bool = false,
        status: ReadingStatus,
        progress: ReadingProgress,
        chapters: [Chapter],
        addedAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.summary = summary
        self.coverSymbol = coverSymbol
        self.coverImageURL = coverImageURL
        self.format = format
        self.sourceName = sourceName
        self.localURL = localURL
        self.remoteBookURL = remoteBookURL
        self.remoteBookURLString = remoteBookURLString ?? remoteBookURL?.absoluteString
        self.isReaderServerBacked = isReaderServerBacked
        self.status = status
        self.progress = progress
        self.chapters = chapters
        self.addedAt = addedAt
        self.updatedAt = updatedAt
    }
}

struct Chapter: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var index: Int
    var remoteIndex: Int?
    var title: String
    var url: URL?
    var localText: String
    var isDownloaded: Bool

    init(id: UUID = UUID(), index: Int, remoteIndex: Int? = nil, title: String, url: URL?, localText: String, isDownloaded: Bool) {
        self.id = id
        self.index = index
        self.remoteIndex = remoteIndex
        self.title = title
        self.url = url
        self.localText = localText
        self.isDownloaded = isDownloaded
    }
}

struct ReadingProgress: Codable, Hashable, Sendable {
    var chapterIndex: Int
    var scrollOffset: Double
    var percentage: Double
}

enum ReaderFontDesign: String, Codable, CaseIterable, Identifiable, Sendable {
    case serif
    case sans
    case rounded
    case cute
    case mono

    var id: String { rawValue }

    var title: String {
        switch self {
        case .serif: "宋体感"
        case .sans: "黑体"
        case .rounded: "圆体"
        case .cute: "可爱风"
        case .mono: "等宽"
        }
    }

    var swiftUIDesign: Font.Design {
        switch self {
        case .serif: .serif
        case .sans: .default
        case .rounded: .rounded
        case .cute: .rounded
        case .mono: .monospaced
        }
    }
}

struct ReaderTheme: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var fontSize: Double
    var lineSpacing: Double
    var paragraphSpacing: Double
    var characterSpacing: Double?
    var firstLineIndent: Double?
    var fontDesignRawValue: String?
    var customFontName: String?
    var isBold: Bool
    var foregroundHex: String
    var backgroundHex: String

    var effectiveCharacterSpacing: Double {
        get { characterSpacing ?? 0 }
        set { characterSpacing = newValue }
    }

    var effectiveFirstLineIndent: Double {
        get { firstLineIndent ?? 2 }
        set { firstLineIndent = newValue }
    }

    var fontDesign: ReaderFontDesign {
        get { ReaderFontDesign(rawValue: fontDesignRawValue ?? "") ?? .serif }
        set { fontDesignRawValue = newValue.rawValue }
    }

    static let classic = ReaderTheme(
        name: "纸页",
        fontSize: 19,
        lineSpacing: 8,
        paragraphSpacing: 12,
        characterSpacing: 0,
        firstLineIndent: 2,
        fontDesignRawValue: ReaderFontDesign.serif.rawValue,
        isBold: false,
        foregroundHex: "#2A2723",
        backgroundHex: "#F5EFE3"
    )
}

struct NASConnection: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var kind: NASKind
    var baseURL: URL
    var username: String
    var password: String
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        name: String,
        kind: NASKind,
        baseURL: URL,
        username: String,
        password: String,
        isEnabled: Bool
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.username = username
        self.password = password
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case kind
        case baseURL
        case username
        case password
        case isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(NASKind.self, forKey: .kind)
        baseURL = try container.decode(URL.self, forKey: .baseURL)
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        password = try container.decodeIfPresent(String.self, forKey: .password) ?? ""
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(username, forKey: .username)
        try container.encode(isEnabled, forKey: .isEnabled)
    }
}

enum NASKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case readerServer
    case webDAV
    case smb
    case sftp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .readerServer: "阅读服务器"
        case .webDAV: "WebDAV"
        case .smb: "SMB"
        case .sftp: "SFTP"
        }
    }
}

struct NASItem: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var url: URL
    var isDirectory: Bool
    var size: Int64?
    var modifiedAt: Date?
}

struct NASDiscoveryResult: Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var kind: NASKind
    var host: String
    var port: Int

    var url: URL? {
        switch kind {
        case .readerServer:
            return URL(string: "http://\(host):\(port)/")
        case .webDAV:
            return URL(string: "http://\(host):\(port)/")
        case .smb:
            return URL(string: "smb://\(host):\(port)/")
        case .sftp:
            return URL(string: "sftp://\(host):\(port)/")
        }
    }
}

struct BookSource: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var baseURL: URL
    var isEnabled: Bool
    var rule: SourceRule
}

struct SourceRule: Codable, Hashable, Sendable {
    var searchPath: String
    var resultListSelector: String
    var titleSelector: String
    var authorSelector: String
    var bookURLSelector: String
    var tocListSelector: String
    var chapterTitleSelector: String
    var chapterURLSelector: String
    var contentSelector: String
    var replacements: [ReplacementRule]
}

struct ReplacementRule: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var pattern: String
    var replacement: String
    var isRegex: Bool
    var isEnabled: Bool
}

struct SearchResult: Identifiable, Hashable, Sendable {
    var id = UUID()
    var title: String
    var author: String
    var sourceName: String
    var bookURL: URL
    var summary: String
}

struct SourceSearchBatch: Sendable {
    var results: [SearchResult]
    var completedSources: Int
    var totalSources: Int
}

struct LibrarySearchHit: Identifiable, Hashable, Sendable {
    var id = UUID()
    var bookID: UUID
    var bookTitle: String
    var chapterTitle: String
    var snippet: String
}

enum DownloadState: String, Codable, CaseIterable, Sendable {
    case queued
    case running
    case paused
    case failed
    case finished

    var title: String {
        switch self {
        case .queued: "排队中"
        case .running: "下载中"
        case .paused: "已暂停"
        case .failed: "失败"
        case .finished: "已完成"
        }
    }
}

struct DownloadTaskItem: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var bookID: UUID
    var title: String
    var sourceName: String
    var chapterIndex: Int?
    var kind: DownloadKind
    var remoteURL: URL?
    var localURL: URL?
    var progress: Double
    var state: DownloadState
    var message: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        bookID: UUID,
        title: String,
        sourceName: String,
        chapterIndex: Int? = nil,
        kind: DownloadKind = .book,
        remoteURL: URL? = nil,
        localURL: URL? = nil,
        progress: Double,
        state: DownloadState,
        message: String,
        createdAt: Date
    ) {
        self.id = id
        self.bookID = bookID
        self.title = title
        self.sourceName = sourceName
        self.chapterIndex = chapterIndex
        self.kind = kind
        self.remoteURL = remoteURL
        self.localURL = localURL
        self.progress = progress
        self.state = state
        self.message = message
        self.createdAt = createdAt
    }
}

enum DownloadKind: String, Codable, Hashable, Sendable {
    case book
    case chapter
    case file
}
