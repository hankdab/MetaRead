import Foundation

enum TVReaderServerError: LocalizedError {
    case invalidBaseURL(String)
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "阅读服务器地址无效"
        case .invalidResponse:
            return "阅读服务器返回了无法识别的数据"
        case .server(let message):
            return message.isEmpty ? "阅读服务器请求失败" : message
        }
    }
}

struct ReaderServerClient: Hashable {
    var baseURL: URL

    init(serverAddress: String) throws {
        let normalizedAddress = serverAddress.hasSuffix("/") ? serverAddress : serverAddress + "/"
        guard let url = URL(string: normalizedAddress) else {
            throw TVReaderServerError.invalidBaseURL(serverAddress)
        }
        self.baseURL = url
    }

    func fetchShelf() async throws -> [TVShelfBook] {
        var request = URLRequest(url: baseURL.appendingPathComponent("reader3/getShelfBookWithCacheInfo"))
        request.httpMethod = "GET"
        return try await perform(request, as: [TVShelfBook].self)
    }

    func fetchChapters(for book: TVShelfBook, refresh: Bool = false) async throws -> [TVChapter] {
        var request = URLRequest(url: baseURL.appendingPathComponent("reader3/getChapterList"))
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(TVChapterListRequest(url: book.bookUrl, refresh: refresh ? 1 : 0))
        return try await perform(request, as: [TVChapter].self)
            .filter { ($0.isVolume ?? false) == false }
            .sorted { $0.chapterIndex < $1.chapterIndex }
    }

    func fetchContent(for book: TVShelfBook, chapterIndex: Int) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("reader3/getBookContent"))
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(TVContentRequest(url: book.bookUrl, index: chapterIndex))
        return try await perform(request, as: String.self)
    }

    private func perform<Value: Decodable>(_ request: URLRequest, as type: Value.Type) async throws -> Value {
        var request = request
        request.timeoutInterval = 18
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("YuanYue-tvOS/0.1", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw TVReaderServerError.invalidResponse
        }

        let decoded = try JSONDecoder().decode(TVServerResponse<Value>.self, from: data)
        guard decoded.isSuccess else {
            throw TVReaderServerError.server(decoded.errorMsg ?? "")
        }
        return decoded.data
    }
}
