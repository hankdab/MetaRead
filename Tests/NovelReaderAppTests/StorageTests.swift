import XCTest
@testable import NovelReaderApp

final class StorageTests: XCTestCase {
    func testNASConnectionEncodingOmitsPassword() throws {
        let connection = NASConnection(
            name: "家里 NAS",
            kind: .webDAV,
            baseURL: URL(string: "https://nas.local/books/")!,
            username: "reader",
            password: "secret",
            isEnabled: true
        )

        let data = try JSONEncoder.appEncoder.encode(connection)
        let json = String(decoding: data, as: UTF8.self)
        let decoded = try JSONDecoder.appDecoder.decode(NASConnection.self, from: data)

        XCTAssertFalse(json.contains("secret"))
        XCTAssertEqual(decoded.username, "reader")
        XCTAssertEqual(decoded.password, "")
    }

    func testJSONStorageSearchFindsChapterContent() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "library-\(UUID().uuidString).json")
        let storage = JSONLibraryStorage(fileURL: url)
        let book = Book(
            title: "测试书",
            author: "作者",
            summary: "",
            coverSymbol: "book",
            format: .txt,
            sourceName: "测试",
            localURL: nil,
            status: .unread,
            progress: ReadingProgress(chapterIndex: 0, scrollOffset: 0, percentage: 0),
            chapters: [
                Chapter(index: 0, title: "第一章", url: nil, localText: "这里有一个关键字", isDownloaded: true)
            ],
            addedAt: .now,
            updatedAt: .now
        )

        try storage.save(
            LibrarySnapshot(
                books: [book],
                sources: [],
                nasConnections: [],
                downloads: [],
                readerTheme: .classic
            )
        )

        let hits = try storage.search(keyword: "关键字")

        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].bookTitle, "测试书")
    }

    func testSQLiteStoragePersistsSnapshotAndFTSSearch() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "library-\(UUID().uuidString).sqlite")
        let storage = SQLiteLibraryStorage(fileURL: url)
        let book = Book(
            title: "SQLite 书",
            author: "作者",
            summary: "",
            coverSymbol: "book",
            format: .txt,
            sourceName: "测试",
            localURL: nil,
            status: .unread,
            progress: ReadingProgress(chapterIndex: 0, scrollOffset: 0, percentage: 0),
            chapters: [
                Chapter(index: 0, title: "第一章", url: nil, localText: "这里有一段可以 searchtoken 搜索的内容", isDownloaded: true)
            ],
            addedAt: .now,
            updatedAt: .now
        )

        try storage.save(
            LibrarySnapshot(
                books: [book],
                sources: [],
                nasConnections: [],
                downloads: [],
                readerTheme: .classic
            )
        )

        let loaded = try storage.load()
        let hits = try storage.search(keyword: "searchtoken")

        XCTAssertEqual(loaded.books.first?.title, "SQLite 书")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.chapterTitle, "第一章")
    }

    func testSQLiteStorageFallsBackForChineseSearch() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "library-\(UUID().uuidString).sqlite")
        let storage = SQLiteLibraryStorage(fileURL: url)
        let book = Book(
            title: "中文书",
            author: "作者",
            summary: "",
            coverSymbol: "book",
            format: .txt,
            sourceName: "测试",
            localURL: nil,
            status: .unread,
            progress: ReadingProgress(chapterIndex: 0, scrollOffset: 0, percentage: 0),
            chapters: [
                Chapter(index: 0, title: "第一章", url: nil, localText: "这里有一段可以全文搜索的内容", isDownloaded: true)
            ],
            addedAt: .now,
            updatedAt: .now
        )

        try storage.save(
            LibrarySnapshot(
                books: [book],
                sources: [],
                nasConnections: [],
                downloads: [],
                readerTheme: .classic
            )
        )

        let hits = try storage.search(keyword: "全文")

        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.bookTitle, "中文书")
    }
}
