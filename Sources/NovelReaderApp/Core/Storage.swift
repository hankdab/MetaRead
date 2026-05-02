import Foundation
import SQLite3

protocol LibraryStorage {
    func load() throws -> LibrarySnapshot
    func save(_ snapshot: LibrarySnapshot) throws
    func search(keyword: String) throws -> [LibrarySearchHit]
}

struct LibrarySnapshot: Codable, Sendable {
    var books: [Book]
    var sources: [BookSource]
    var nasConnections: [NASConnection]
    var downloads: [DownloadTaskItem]
    var readerTheme: ReaderTheme
}

struct JSONLibraryStorage: LibraryStorage {
    private let customFileURL: URL?

    init(fileURL: URL? = nil) {
        customFileURL = fileURL
    }

    private var fileURL: URL {
        if let customFileURL {
            return customFileURL
        }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appending(path: "NovelReaderApp", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "library.json")
    }

    func load() throws -> LibrarySnapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return LibrarySnapshot(books: [], sources: [], nasConnections: [], downloads: [], readerTheme: .classic)
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder.appDecoder.decode(LibrarySnapshot.self, from: data)
    }

    func save(_ snapshot: LibrarySnapshot) throws {
        let data = try JSONEncoder.appEncoder.encode(snapshot)
        try data.write(to: fileURL, options: [.atomic])
    }

    func search(keyword: String) throws -> [LibrarySearchHit] {
        let snapshot = try load()
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return snapshot.books.flatMap { book in
            book.chapters.compactMap { chapter in
                guard chapter.localText.localizedCaseInsensitiveContains(trimmed) else { return nil }
                return LibrarySearchHit(bookID: book.id, bookTitle: book.title, chapterTitle: chapter.title, snippet: chapter.localText.snippet(around: trimmed))
            }
        }
    }
}

enum StorageError: LocalizedError {
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case .sqlite(let message): message
        }
    }
}

final class SQLiteLibraryStorage: LibraryStorage {
    private var db: OpaquePointer?

    init(fileURL: URL? = nil) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appending(path: "NovelReaderApp", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = fileURL ?? directory.appending(path: "library.sqlite")
        if sqlite3_open(url.path, &db) != SQLITE_OK {
            assertionFailure(lastError)
        }
        try? migrate()
    }

    deinit {
        sqlite3_close(db)
    }

    func load() throws -> LibrarySnapshot {
        let sql = "SELECT value FROM app_storage WHERE key = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StorageError.sqlite(lastError)
        }
        defer { sqlite3_finalize(statement) }

        bind("snapshot", to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return LibrarySnapshot(books: [], sources: [], nasConnections: [], downloads: [], readerTheme: .classic)
        }

        guard let bytes = sqlite3_column_blob(statement, 0) else {
            return LibrarySnapshot(books: [], sources: [], nasConnections: [], downloads: [], readerTheme: .classic)
        }
        let count = Int(sqlite3_column_bytes(statement, 0))
        let data = Data(bytes: bytes, count: count)
        return try JSONDecoder.appDecoder.decode(LibrarySnapshot.self, from: data)
    }

    func save(_ snapshot: LibrarySnapshot) throws {
        let data = try JSONEncoder.appEncoder.encode(snapshot)
        let searchIndexSignature = snapshot.books.searchIndexSignature
        let previousSearchIndexSignature = stringValue(for: "books_search_index_signature")
        let hasSearchIndex = searchIndexRowCount() > 0

        try upsert(key: "snapshot", data: data)

        guard previousSearchIndexSignature != searchIndexSignature else {
            return
        }

        if previousSearchIndexSignature == nil, hasSearchIndex {
            try upsert(key: "books_search_index_signature", data: Data(searchIndexSignature.utf8))
            return
        }

        try rebuildSearchIndex(snapshot)
        try upsert(key: "books_search_index_signature", data: Data(searchIndexSignature.utf8))
    }

    private func upsert(key: String, data: Data) throws {
        let sql = """
        INSERT INTO app_storage (key, value, updated_at)
        VALUES (?, ?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StorageError.sqlite(lastError)
        }
        defer { sqlite3_finalize(statement) }

        bind(key, to: statement, at: 1)
        data.withUnsafeBytes { buffer in
            _ = sqlite3_bind_blob(statement, 2, buffer.baseAddress, Int32(data.count), transientDestructor)
        }
        sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StorageError.sqlite(lastError)
        }
    }

    func search(keyword: String) throws -> [LibrarySearchHit] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let sql = """
        SELECT book_id, book_title, chapter_title, snippet(chapter_fts, 3, '', '', '...', 18)
        FROM chapter_fts
        WHERE chapter_fts MATCH ?
        LIMIT 50
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        bind(trimmed, to: statement, at: 1)
        var hits: [LibrarySearchHit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let bookIDText = columnText(statement, 0)
            hits.append(
                LibrarySearchHit(
                    bookID: UUID(uuidString: bookIDText) ?? UUID(),
                    bookTitle: columnText(statement, 1),
                    chapterTitle: columnText(statement, 2),
                    snippet: columnText(statement, 3)
                )
            )
        }
        return hits.isEmpty ? try fallbackSearch(keyword: trimmed) : hits
    }

    private func migrate() throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS app_storage (
            key TEXT PRIMARY KEY NOT NULL,
            value BLOB NOT NULL,
            updated_at REAL NOT NULL
        )
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw StorageError.sqlite(lastError)
        }
        let ftsSQL = """
        CREATE VIRTUAL TABLE IF NOT EXISTS chapter_fts USING fts5(
            book_id UNINDEXED,
            book_title,
            chapter_title,
            content
        )
        """
        _ = sqlite3_exec(db, ftsSQL, nil, nil, nil)
    }

    private func rebuildSearchIndex(_ snapshot: LibrarySnapshot) throws {
        guard sqlite3_exec(db, "DELETE FROM chapter_fts", nil, nil, nil) == SQLITE_OK else {
            return
        }
        let sql = "INSERT INTO chapter_fts (book_id, book_title, chapter_title, content) VALUES (?, ?, ?, ?)"
        for book in snapshot.books {
            for chapter in book.chapters where !chapter.localText.isEmpty {
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { continue }
                bind(book.id.uuidString, to: statement, at: 1)
                bind(book.title, to: statement, at: 2)
                bind(chapter.title, to: statement, at: 3)
                bind(chapter.localText, to: statement, at: 4)
                sqlite3_step(statement)
                sqlite3_finalize(statement)
            }
        }
    }

    private func stringValue(for key: String) -> String? {
        let sql = "SELECT value FROM app_storage WHERE key = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        bind(key, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let bytes = sqlite3_column_blob(statement, 0) else {
            return nil
        }
        let count = Int(sqlite3_column_bytes(statement, 0))
        let data = Data(bytes: bytes, count: count)
        return String(data: data, encoding: .utf8)
    }

    private func searchIndexRowCount() -> Int {
        let sql = "SELECT COUNT(*) FROM chapter_fts"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return 0
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return 0
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    private var lastError: String {
        guard let db else { return "SQLite 未初始化" }
        return String(cString: sqlite3_errmsg(db))
    }

    private var transientDestructor: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    private func bind(_ text: String, to statement: OpaquePointer?, at index: Int32) {
        sqlite3_bind_text(statement, index, text, -1, transientDestructor)
    }

    private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let cString = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: cString)
    }

    private func fallbackSearch(keyword: String) throws -> [LibrarySearchHit] {
        let snapshot = try load()
        return snapshot.books.flatMap { book in
            book.chapters.compactMap { chapter in
                guard chapter.localText.localizedCaseInsensitiveContains(keyword) else { return nil }
                return LibrarySearchHit(
                    bookID: book.id,
                    bookTitle: book.title,
                    chapterTitle: chapter.title,
                    snippet: chapter.localText.snippet(around: keyword)
                )
            }
        }
    }
}

private extension String {
    func snippet(around keyword: String) -> String {
        guard let range = range(of: keyword, options: .caseInsensitive) else {
            return String(prefix(80))
        }
        let lower = index(range.lowerBound, offsetBy: -30, limitedBy: startIndex) ?? startIndex
        let upper = index(range.upperBound, offsetBy: 50, limitedBy: endIndex) ?? endIndex
        return String(self[lower..<upper]).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}

private extension Array where Element == Book {
    var searchIndexSignature: String {
        map { book in
            let chapterSignature = book.chapters.map { chapter in
                "\(chapter.id.uuidString):\(chapter.title):\(chapter.localText.count)"
            }.joined(separator: ",")
            return "\(book.id.uuidString):\(book.title):\(book.author):\(chapterSignature)"
        }.joined(separator: "|")
    }
}

extension JSONEncoder {
    static var appEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var appDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
