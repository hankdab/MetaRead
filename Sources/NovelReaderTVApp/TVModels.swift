import Foundation

struct TVServerResponse<Value: Decodable>: Decodable {
    let isSuccess: Bool
    let errorMsg: String?
    let data: Value
}

struct TVShelfBook: Decodable, Identifiable, Hashable {
    let bookUrl: String
    let tocUrl: String?
    let originName: String?
    let name: String
    let author: String?
    let coverUrl: String?
    let intro: String?
    let kind: String?
    let latestChapterTitle: String?
    let durChapterTitle: String?
    let durChapterIndex: Int?
    let totalChapterNum: Int?
    let wordCount: String?

    var id: String { bookUrl }

    var displayAuthor: String {
        let value = author?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "佚名" : value
    }

    var progressTitle: String {
        if let durChapterTitle, !durChapterTitle.isEmpty {
            return durChapterTitle
        }
        return latestChapterTitle ?? "未开始"
    }

    func resolvedCoverURL(baseURL: URL) -> URL? {
        guard let coverUrl, !coverUrl.isEmpty else { return nil }
        if let direct = URL(string: coverUrl), direct.scheme != nil {
            return direct
        }
        return URL(string: coverUrl, relativeTo: baseURL)?.absoluteURL
    }
}

struct TVChapter: Decodable, Identifiable, Hashable {
    let url: String?
    let title: String
    let isVolume: Bool?
    let baseUrl: String?
    let bookUrl: String?
    let index: Int?
    let tag: String?

    var id: Int { index ?? title.hashValue }
    var chapterIndex: Int { index ?? 0 }
}

struct TVContentRequest: Encodable {
    let url: String
    let index: Int
}

struct TVChapterListRequest: Encodable {
    let url: String
    let refresh: Int
}
