import Foundation
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

enum AppServiceError: LocalizedError {
    case unsupportedProtocol(String)
    case invalidResponse
    case unauthorized
    case forbidden
    case unsupportedFileType(String)
    case serverError(String)   // Reader Server 返回 isSuccess:false 并带 errorMsg

    var errorDescription: String? {
        switch self {
        case .unsupportedProtocol(let name): "暂未启用 \(name) 协议"
        case .invalidResponse: "服务器响应格式无法解析"
        case .unauthorized: "账号或密码不正确"
        case .forbidden: "权限不足，请检查账号可访问的目录"
        case .unsupportedFileType(let name): "暂不支持 \(name)"
        case .serverError(let msg): msg.isEmpty ? "服务器返回错误" : msg
        }
    }
}

struct LibraryCache {
    var rootURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appending(path: "NovelReaderApp/Cache", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func localURL(for remoteURL: URL) -> URL {
        let safeName = remoteURL.lastPathComponent.isEmpty ? UUID().uuidString : remoteURL.lastPathComponent
        return rootURL.appending(path: safeName)
    }

    func copyLocalFile(_ url: URL) throws -> URL {
        let destination = localURL(for: url)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }
}

struct BookSourceEngine: Sendable {
    func search(keyword: String, in sources: [BookSource], maxSources: Int? = nil) async throws -> [SearchResult] {
        var allResults: [SearchResult] = []
        for await batch in searchBatches(keyword: keyword, in: sources, maxSources: maxSources) {
            allResults.append(contentsOf: batch.results)
            if allResults.count >= 80 {
                break
            }
        }
        return Array(allResults.prefix(80))
    }

    func searchBatches(keyword: String, in sources: [BookSource], maxSources: Int? = nil, concurrentLimit: Int = 8) -> AsyncStream<SourceSearchBatch> {
        let candidates = maxSources.map { Array(sources.prefix($0)) } ?? sources
        return AsyncStream { continuation in
            guard !candidates.isEmpty else {
                continuation.finish()
                return
            }

            let task = Task {
                await withTaskGroup(of: [SearchResult].self) { group in
                    let limit = min(max(concurrentLimit, 1), candidates.count)
                    var nextIndex = 0

                    for _ in 0..<limit {
                        let source = candidates[nextIndex]
                        nextIndex += 1
                        group.addTask {
                            guard !Task.isCancelled else { return [] }
                            return (try? await searchLive(keyword: keyword, source: source, timeout: 5)) ?? []
                        }
                    }

                    var completedSources = 0
                    for await results in group {
                        guard !Task.isCancelled else {
                            group.cancelAll()
                            break
                        }
                        completedSources += 1
                        continuation.yield(
                            SourceSearchBatch(
                                results: results,
                                completedSources: completedSources,
                                totalSources: candidates.count
                            )
                        )
                        if nextIndex < candidates.count {
                            let source = candidates[nextIndex]
                            nextIndex += 1
                            group.addTask {
                                guard !Task.isCancelled else { return [] }
                                return (try? await searchLive(keyword: keyword, source: source, timeout: 5)) ?? []
                            }
                        }
                    }
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func downloadBook(from result: SearchResult, source: BookSource, maxChapters: Int = 120) async throws -> Book {
        if source.rule.tocListSelector == "$directText" {
            return try await downloadDirectTextBook(from: result, source: source)
        }

        let chapters = try await fetchLiveChapters(bookURL: result.bookURL, source: source, maxChapters: maxChapters)
        guard !chapters.isEmpty else {
            throw AppServiceError.invalidResponse
        }

        return Book(
            title: result.title,
            author: result.author,
            summary: result.summary,
            coverSymbol: "globe.asia.australia.fill",
            format: .web,
            sourceName: result.sourceName,
            localURL: nil,
            remoteBookURL: result.bookURL,
            status: .unread,
            progress: ReadingProgress(chapterIndex: 0, scrollOffset: 0, percentage: 0),
            chapters: chapters,
            addedAt: .now,
            updatedAt: .now
        )
    }

    func fetchTableOfContents(from result: SearchResult, source: BookSource, maxChapters: Int = 300) async throws -> [Chapter] {
        if source.rule.tocListSelector == "$directText" {
            let text = try await fetchText(from: result.bookURL)
            return PlainTextBookParser()
                .parse(title: result.title, author: result.author, text: cleanDirectText(text))
                .chapters
        }

        let chapters = try await fetchChapterLinks(bookURL: result.bookURL, source: source, maxChapters: maxChapters)
        return chapters.enumerated().map { index, link in
            Chapter(index: index, title: link.title, url: link.url, localText: "", isDownloaded: false)
        }
    }

    func parseChapterContent(data: Data, source: BookSource) throws -> String {
        let html = TextDecoder().decode(data) ?? String(decoding: data, as: UTF8.self)
        let extractor = SimpleHTMLExtractor()
        let cleaner = ContentCleaner()
        let rawContent = extractor.value(source.rule.contentSelector, in: html)
        let content = cleaner.clean(rawContent, replacements: source.rule.replacements)
        return content.isEmpty ? "正文为空，请检查书源正文规则。" : content
    }

    private func downloadDirectTextBook(from result: SearchResult, source: BookSource) async throws -> Book {
        let text = try await fetchText(from: result.bookURL)
        var book = PlainTextBookParser().parse(
            title: result.title,
            author: result.author,
            text: cleanDirectText(text)
        )
        book.summary = result.summary
        book.coverSymbol = "text.book.closed.fill"
        book.sourceName = source.name
        book.format = .txt
        book.remoteBookURL = result.bookURL
        book.remoteBookURLString = result.bookURL.absoluteString
        return book
    }

    private func searchLive(keyword: String, source: BookSource, timeout: TimeInterval = 8) async throws -> [SearchResult] {
        let expression = RuleTemplate.render(source.rule.searchPath, keyword: keyword, page: 1)
        var request = try RuleRequestBuilder.request(from: expression, baseURL: source.baseURL)
        request.timeoutInterval = timeout
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AppServiceError.invalidResponse
        }

        let html = TextDecoder().decode(data) ?? String(decoding: data, as: UTF8.self)
        let extractor = SimpleHTMLExtractor()
        let nodes = extractor.nodes(matching: source.rule.resultListSelector, in: html)

        return nodes.compactMap { node in
            let title = extractor.value(source.rule.titleSelector, in: node)
            guard !title.isEmpty else { return nil }
            let author = extractor.value(source.rule.authorSelector, in: node)
            let href = extractor.value(source.rule.bookURLSelector, in: node)
            guard !href.isEmpty,
                  let bookURL = URL(string: href, relativeTo: source.baseURL)?.absoluteURL else {
                return nil
            }
            return SearchResult(
                title: title,
                author: author.isEmpty ? "未知作者" : author,
                sourceName: source.name,
                bookURL: bookURL,
                summary: "来自 \(source.name)"
            )
        }
    }

    private func fetchLiveChapters(bookURL: URL, source: BookSource, maxChapters: Int) async throws -> [Chapter] {
        let tocHTML = try await fetchText(from: bookURL)
        let cleaner = ContentCleaner()
        let extractor = SimpleHTMLExtractor()
        let chapterLinks = parseChapterLinks(tocHTML: tocHTML, bookURL: bookURL, source: source, maxChapters: maxChapters)

        var chapters: [Chapter] = []
        for (index, link) in chapterLinks.enumerated() {
            let chapterHTML = try await fetchText(from: link.url)
            let rawContent = extractor.value(source.rule.contentSelector, in: chapterHTML)
            let content = cleaner.clean(rawContent, replacements: source.rule.replacements)
            chapters.append(
                Chapter(
                    index: index,
                    title: link.title,
                    url: link.url,
                    localText: content.isEmpty ? "正文为空，请检查书源正文规则。" : content,
                    isDownloaded: true
                )
            )
        }

        return chapters
    }

    private func fetchChapterLinks(bookURL: URL, source: BookSource, maxChapters: Int) async throws -> [(title: String, url: URL)] {
        let tocHTML = try await fetchText(from: bookURL)
        return parseChapterLinks(tocHTML: tocHTML, bookURL: bookURL, source: source, maxChapters: maxChapters)
    }

    private func parseChapterLinks(tocHTML: String, bookURL: URL, source: BookSource, maxChapters: Int) -> [(title: String, url: URL)] {
        let extractor = SimpleHTMLExtractor()
        let tocNodes = extractor.nodes(matching: source.rule.tocListSelector, in: tocHTML)

        var chapterLinks: [(title: String, url: URL)] = []
        for node in tocNodes.prefix(maxChapters) {
            let title = extractor.value(source.rule.chapterTitleSelector, in: node)
            var href = extractor.value(source.rule.chapterURLSelector, in: node)
            href = href.replacingOccurrences(of: "{{bookURL}}", with: bookURL.absoluteString)
            if let bookID = bookID(from: bookURL) {
                href = href.replacingOccurrences(of: "{{bookID}}", with: bookID)
            }
            guard !title.isEmpty, let chapterURL = URL(string: href, relativeTo: bookURL)?.absoluteURL else {
                continue
            }
            chapterLinks.append((title, chapterURL))
        }
        return chapterLinks
    }

    private func fetchText(from url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 AppleWebKit NovelReaderApp", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AppServiceError.invalidResponse
        }
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        if let gb = String(data: data, encoding: .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))) {
            return gb
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func previewResults(keyword: String, source: BookSource) -> [SearchResult] {
        [
            SearchResult(
                title: "\(keyword) · 正文全集",
                author: "网络作者",
                sourceName: source.name,
                bookURL: source.baseURL.appending(path: "book/\(keyword)"),
                summary: "来自 \(source.name) 的预览搜索结果。真实站点可通过书源规则解析搜索页、目录页与正文页。"
            ),
            SearchResult(
                title: "\(keyword) 外传",
                author: "佚名",
                sourceName: source.name,
                bookURL: source.baseURL.appending(path: "side/\(keyword)"),
                summary: "规则引擎支持基础 CSS selector 与 @text/@href 提取，后续可扩展 XPath、JSONPath 与 JS。"
            )
        ]
    }

    private func previewChapters() -> [Chapter] {
        [
            Chapter(index: 0, title: "第一章 雨夜归家", url: nil, localText: SampleText.chapterOne, isDownloaded: true),
            Chapter(index: 1, title: "第二章 阁楼里的书", url: nil, localText: SampleText.chapterTwo, isDownloaded: true),
            Chapter(index: 2, title: "第三章 远处的灯", url: nil, localText: SampleText.chapterThree, isDownloaded: true)
        ]
    }

    private func cleanDirectText(_ text: String) -> String {
        var cleaned = text
        if let startRange = cleaned.range(of: #"\*\*\* START OF (THE|THIS) PROJECT GUTENBERG EBOOK[\s\S]*?\*\*\*"#, options: [.regularExpression, .caseInsensitive]) {
            cleaned = String(cleaned[startRange.upperBound...])
        }
        if let endRange = cleaned.range(of: #"\*\*\* END OF (THE|THIS) PROJECT GUTENBERG EBOOK[\s\S]*$"#, options: [.regularExpression, .caseInsensitive]) {
            cleaned = String(cleaned[..<endRange.lowerBound])
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func bookID(from url: URL) -> String? {
        let path = url.path
        guard let range = path.range(of: #"/book/([^/]+)"#, options: .regularExpression) else {
            return nil
        }
        return String(path[range])
            .split(separator: "/")
            .last
            .map(String.init)
    }
}

struct SimpleHTMLExtractor {
    func nodes(matching selector: String, in html: String) -> [String] {
        let selector = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        if selector.contains("||") {
            for option in selector.components(separatedBy: "||") {
                let nodes = self.nodes(matching: option.trimmingCharacters(in: .whitespacesAndNewlines), in: html)
                if !nodes.isEmpty {
                    return nodes
                }
            }
            return []
        }
        if selector.contains("&&") {
            return selector.components(separatedBy: "&&")
                .flatMap { self.nodes(matching: $0.trimmingCharacters(in: .whitespacesAndNewlines), in: html) }
        }
        if selector.hasPrefix("<js>") {
            return JSRuleEvaluator.evaluate(selector, input: html).map { [$0] } ?? []
        }
        if selector.hasPrefix("$") {
            return JSONRuleExtractor.nodes(selector, in: html)
        }
        if selector.hasPrefix("/") {
            return XPathLiteExtractor.nodes(selector, in: html)
        }
        if selector.hasPrefix("@") {
            return legacyChainNodes(selector, in: html)
        }
        if isLegacySelector(selector) {
            return legacyChainNodes(selector, in: html)
        }
        if selector.contains(" ") {
            let parts = selector.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            return parts.reduce([html]) { fragments, part in
                fragments.flatMap { nodes(matching: part, in: $0) }
            }
        }

        let cleanSelector = selector.selectorKey
        guard !cleanSelector.isEmpty else { return [] }

        if selector.hasPrefix(".") {
            return html.matches(for: #"<([a-zA-Z0-9]+)[^>]*class=["'][^"']*\#(cleanSelector)[^"']*["'][^>]*>[\s\S]*?</\1>"#)
        }
        if selector.hasPrefix("#") {
            return html.matches(for: #"<([a-zA-Z0-9]+)[^>]*id=["']\#(cleanSelector)["'][^>]*>[\s\S]*?</\1>"#)
        }
        return html.matches(for: #"<\#(cleanSelector)[^>]*>[\s\S]*?</\#(cleanSelector)>"#)
    }

    func value(_ expression: String, in html: String) -> String {
        if expression.contains("||") {
            for option in expression.components(separatedBy: "||") {
                let value = self.value(option.trimmingCharacters(in: .whitespacesAndNewlines), in: html)
                if !value.isEmpty {
                    return value
                }
            }
            return ""
        }

        if expression.contains("##") {
            let parts = expression.components(separatedBy: "##")
            var value = self.value(parts[0].trimmingCharacters(in: .whitespacesAndNewlines), in: html)
            var index = 1
            while index < parts.count {
                let pattern = parts[index]
                let replacement = index + 1 < parts.count ? parts[index + 1] : ""
                if !pattern.isEmpty {
                    value = value.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
                }
                index += 2
            }
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if expression.contains("{{") {
            return renderTemplate(expression, in: html)
        }

        if isLiteralURLExpression(expression) {
            return expression
        }

        if expression.hasPrefix("<js>") {
            return JSRuleEvaluator.evaluate(expression, input: html) ?? ""
        }
        if expression.hasPrefix("$") {
            return JSONRuleExtractor.value(expression, in: html)
        }
        if expression.hasPrefix("/") {
            return XPathLiteExtractor.value(expression, in: html)
        }
        if expression.hasPrefix("@") && expression != "@text" && expression != "@href" {
            return legacyChainValue(expression, in: html)
        }
        if isLegacySelector(expression) {
            return legacyChainValue(expression.contains("@") ? expression : expression + "@text", in: html)
        }
        let parts = expression.split(separator: "@", maxSplits: 1).map(String.init)
        let selector = parts.first ?? expression
        let attribute = parts.count > 1 ? parts[1] : "text"
        let node = selector.isEmpty ? html : nodes(matching: selector, in: html).first ?? html

        if attribute == "text" {
            return stripTags(node)
        }
        if attribute == "html" {
            return stripTags(node)
        }
        return attributeValue(attribute, in: node)
    }

    private func attributeValue(_ name: String, in html: String) -> String {
        let pattern = #"\#(name)=["']([^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: html) else {
            return ""
        }
        return String(html[range]).htmlDecoded
    }

    private func stripTags(_ html: String) -> String {
        html
            .replacingOccurrences(of: #"<script[\s\S]*?</script>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"<style[\s\S]*?</style>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .htmlDecoded
    }

    private func renderTemplate(_ expression: String, in html: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\{\{\s*([^{}]+?)\s*\}\}"#) else {
            return expression
        }
        var rendered = expression
        let matches = regex.matches(in: expression, range: NSRange(expression.startIndex..., in: expression))
        for match in matches.reversed() {
            guard match.numberOfRanges > 1,
                  let wholeRange = Range(match.range(at: 0), in: rendered),
                  let tokenRange = Range(match.range(at: 1), in: expression) else {
                continue
            }
            let token = String(expression[tokenRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value: String
            if token.hasPrefix("$") {
                value = JSONRuleExtractor.value(token, in: html)
            } else if token.hasPrefix("@") || isLegacySelector(token) {
                value = self.value(token, in: html)
            } else {
                value = "{{\(token)}}"
            }
            rendered.replaceSubrange(wholeRange, with: value)
        }
        return rendered.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isLiteralURLExpression(_ expression: String) -> Bool {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") || trimmed.hasPrefix("data:") {
            return true
        }
        return trimmed.hasPrefix("/")
            && !trimmed.hasPrefix("//")
            && !trimmed.contains("[@")
            && !trimmed.contains("/@")
            && !trimmed.contains("/text()")
    }

    private func isLegacySelector(_ selector: String) -> Bool {
        selector.hasPrefix("class.")
            || selector.hasPrefix("id.")
            || selector.hasPrefix("tag.")
            || selector.hasPrefix("text.")
            || selector.hasPrefix("children")
    }

    private func legacyChainNodes(_ expression: String, in html: String) -> [String] {
        let parts = expression.split(separator: "@").map(String.init).filter { !$0.isEmpty }
        guard let first = parts.first else { return [html] }
        return legacySelect(first, in: html)
    }

    private func legacyChainValue(_ expression: String, in html: String) -> String {
        let parts = expression.split(separator: "@").map(String.init).filter { !$0.isEmpty }
        guard !parts.isEmpty else { return stripTags(html) }
        var fragments = [html]
        for part in parts.dropLast() {
            fragments = fragments.flatMap { legacySelect(part, in: $0) }
        }
        guard let node = fragments.first else { return "" }
        let last = parts.last ?? "text"
        if last == "text" {
            return stripTags(node)
        }
        if last == "html" || last == "textNodes" || last == "ownText" {
            return stripTags(node)
        }
        let attribute = attributeValue(last, in: node)
        if !attribute.isEmpty {
            return attribute
        }
        return legacySelect(last, in: node).first.map(stripTags) ?? ""
    }

    private func legacySelect(_ token: String, in html: String) -> [String] {
        let pieces = token.split(separator: ".").map(String.init)
        guard let head = pieces.first, !head.isEmpty else { return [] }

        let matches: [String]
        let indexToken: String?
        if head == "class", pieces.count >= 2 {
            matches = html.matches(for: #"<([a-zA-Z0-9]+)[^>]*class=["'][^"']*\#(pieces[1])[^"']*["'][^>]*>[\s\S]*?</\1>"#)
            indexToken = pieces.count > 2 ? pieces[2] : nil
        } else if head == "id", pieces.count >= 2 {
            matches = html.matches(for: #"<([a-zA-Z0-9]+)[^>]*id=["']\#(pieces[1])["'][^>]*>[\s\S]*?</\1>"#)
            indexToken = pieces.count > 2 ? pieces[2] : nil
        } else if head == "tag", pieces.count >= 2 {
            matches = html.matches(for: #"<\#(pieces[1])\b[^>]*>[\s\S]*?</\#(pieces[1])>"#)
            indexToken = pieces.count > 2 ? pieces[2] : nil
        } else if head == "text" || head == "textNodes" || head == "ownText" {
            matches = [stripTags(html)]
            indexToken = nil
        } else if head.hasPrefix("children") {
            matches = childNodes(in: html)
            indexToken = captureIndex(from: head)
        } else {
            matches = html.matches(for: #"<\#(head)\b[^>]*>[\s\S]*?</\#(head)>"#)
            indexToken = pieces.count > 1 ? pieces[1] : nil
        }

        return applyIndex(indexToken, to: matches)
    }

    private func childNodes(in html: String) -> [String] {
        let inner = html
            .replacingOccurrences(of: #"^<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"</[^>]+>$"#, with: "", options: .regularExpression)
        return inner.matches(for: #"<([a-zA-Z0-9]+)\b[^>]*>[\s\S]*?</\1>"#)
    }

    private func applyIndex(_ rawIndex: String?, to matches: [String]) -> [String] {
        guard let rawIndex, !rawIndex.isEmpty else { return matches }
        let cleaned = rawIndex
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
        guard let first = cleaned.split(separator: ":", maxSplits: 1).first else { return matches }
        let value = String(first).replacingOccurrences(of: "!", with: "")
        guard let index = Int(value) else { return matches }
        let resolved = index < 0 ? matches.count + index : index
        guard matches.indices.contains(resolved) else { return [] }
        return [matches[resolved]]
    }

    private func captureIndex(from token: String) -> String? {
        guard let range = token.range(of: #"\[([^\]]+)\]"#, options: .regularExpression) else {
            return nil
        }
        return String(token[range])
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
    }
}

enum JSRuleEvaluator {
    static func evaluate(_ expression: String, input: String) -> String? {
        let script = expression
            .replacingOccurrences(of: "<js>", with: "")
            .replacingOccurrences(of: "</js>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty else { return input }

        #if canImport(JavaScriptCore)
        let context = JSContext()
        context?.setObject(input, forKeyedSubscript: "result" as NSString)
        context?.setObject(input, forKeyedSubscript: "src" as NSString)
        context?.setObject(input, forKeyedSubscript: "html" as NSString)
        let wrapped = """
        (function() {
            \(script)
        })()
        """
        return context?.evaluateScript(wrapped)?.toString()
        #else
        return nil
        #endif
    }
}

enum RuleTemplate {
    static func render(_ template: String, keyword: String, page: Int = 1) -> String {
        let encodedKeyword = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? keyword
        return renderPageExpressions(in: template, page: page)
            .replacingOccurrences(of: "{{keyword}}", with: encodedKeyword)
            .replacingOccurrences(of: "{{key}}", with: encodedKeyword)
            .replacingOccurrences(of: "{{searchKey}}", with: encodedKeyword)
            .replacingOccurrences(of: "{{keywordRaw}}", with: keyword)
            .replacingOccurrences(of: "{{keyRaw}}", with: keyword)
            .replacingOccurrences(of: "{{page}}", with: "\(page)")
    }

    private static func renderPageExpressions(in template: String, page: Int) -> String {
        var rendered = template
        rendered = replaceMatches(
            pattern: #"\{\{\s*\(?\s*page\s*-\s*1\s*\)?\s*\*\s*(\d+)\s*\}\}"#,
            in: rendered
        ) { multiplier in
            "\(max(0, page - 1) * multiplier)"
        }
        rendered = replaceMatches(
            pattern: #"\{\{\s*page\s*-\s*(\d+)\s*\}\}"#,
            in: rendered
        ) { decrement in
            "\(max(0, page - decrement))"
        }
        return rendered
    }

    private static func replaceMatches(pattern: String, in text: String, transform: (Int) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard match.numberOfRanges > 1,
                  let fullRange = Range(match.range(at: 0), in: result),
                  let valueRange = Range(match.range(at: 1), in: text),
                  let value = Int(text[valueRange]) else {
                continue
            }
            result.replaceSubrange(fullRange, with: transform(value))
        }
        return result
    }
}

private extension CharacterSet {
    static let urlQueryValueAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}

enum RuleRequestBuilder {
    static func request(from expression: String, baseURL: URL) throws -> URLRequest {
        let expression = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expression.hasPrefix("@js:"),
              !expression.hasPrefix("<js>") else {
            throw AppServiceError.invalidResponse
        }

        let parts = expression.split(separator: ",", maxSplits: 1).map(String.init)
        let path = parts.first ?? expression
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw AppServiceError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 AppleWebKit NovelReaderApp", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 8

        guard parts.count > 1,
              let rawOptions = parseOptions(parts[1]) else {
            return request
        }

        let charset = rawOptions["charset"] as? String ?? "utf-8"
        request.httpMethod = (rawOptions["method"] as? String)?.uppercased() ?? "GET"
        if let body = rawOptions["body"] as? String {
            request.httpBody = body.data(using: .utf8)
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/x-www-form-urlencoded; charset=\(charset)", forHTTPHeaderField: "Content-Type")
            }
        }
        for (key, value) in headerMap(from: rawOptions["header"]) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        for (key, value) in headerMap(from: rawOptions["headers"]) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    private static func parseOptions(_ raw: String) -> [String: Any]? {
        if let data = raw.data(using: .utf8),
           let options = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return options
        }
        let normalized = raw.replacingOccurrences(of: "'", with: "\"")
        if let data = normalized.data(using: .utf8),
           let options = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return options
        }
        return nil
    }

    private static func headerMap(from value: Any?) -> [String: String] {
        if let headers = value as? [String: String] {
            return headers
        }
        if let headers = value as? [String: Any] {
            return headers.reduce(into: [:]) { result, pair in
                result[pair.key] = String(describing: pair.value)
            }
        }
        if let raw = value as? String,
           let data = raw.data(using: .utf8),
           let headers = try? JSONDecoder().decode([String: String].self, from: data) {
            return headers
        }
        return [:]
    }
}

enum JSONRuleExtractor {
    static func nodes(_ expression: String, in text: String) -> [String] {
        guard let root = jsonObject(from: text) else { return [] }
        return values(expression, root: root)
            .flatMap { value -> [Any] in
                if let array = value as? [Any] {
                    return array
                }
                return [value]
            }
            .compactMap(stringify)
    }

    static func value(_ expression: String, in text: String) -> String {
        nodes(expression, in: text).first ?? ""
    }

    private static func values(_ expression: String, root: Any) -> [Any] {
        let tokens = tokenize(expression)
        return tokens.reduce([root]) { current, token in
            current.flatMap { apply(token, to: $0) }
        }
    }

    private static func apply(_ token: String, to value: Any) -> [Any] {
        if token.hasPrefix("..") {
            let key = String(token.dropFirst(2))
            return flatten(value).flatMap { item in
                if key.isEmpty { return [item] }
                if let dict = item as? [String: Any], let child = dict[key] {
                    return [child]
                }
                return []
            }
        }
        if token == "*" {
            if let array = value as? [Any] { return array }
            if let dict = value as? [String: Any] { return Array(dict.values) }
            return []
        }
        if token.hasPrefix("?") {
            return filter(token, value: value)
        }
        if let index = Int(token), let array = value as? [Any], array.indices.contains(index) {
            return [array[index]]
        }
        if let dict = value as? [String: Any], let child = dict[token] {
            return [child]
        }
        return []
    }

    private static func flatten(_ value: Any) -> [Any] {
        var result = [value]
        if let array = value as? [Any] {
            result.append(contentsOf: array.flatMap(flatten))
            return result
        }
        if let dict = value as? [String: Any] {
            result.append(contentsOf: dict.values.flatMap(flatten))
            return result
        }
        return result
    }

    private static func filter(_ token: String, value: Any) -> [Any] {
        let raw = String(token.dropFirst())
        let pieces = raw.split(separator: "=", maxSplits: 1).map(String.init)
        guard pieces.count == 2 else { return [] }
        let field = pieces[0]
        let expected = pieces[1]
        let candidates: [Any]
        if let array = value as? [Any] {
            candidates = array
        } else if let dict = value as? [String: Any] {
            candidates = Array(dict.values)
        } else {
            candidates = []
        }
        return candidates.filter { item in
            guard let dict = item as? [String: Any], let child = dict[field] else {
                return false
            }
            return stringify(child) == expected
        }
    }

    private static func tokenize(_ expression: String) -> [String] {
        var cleaned = expression
            .replacingOccurrences(of: "$..", with: "__recursive__")
            .replacingOccurrences(of: "$.", with: "")
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: "[*]", with: ".*")
            .replacingOccurrences(of: ".[*]", with: ".*")
        cleaned = cleaned.replacingOccurrences(
            of: #"\[\?\(@\.([A-Za-z0-9_\-]+)\s*==\s*['"]([^'"]+)['"]\)\]"#,
            with: ".?$1=$2",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(of: #"\[['"]?([^'"\]]+)['"]?\]"#, with: ".$1", options: .regularExpression)
        return cleaned
            .split(separator: ".")
            .map { String($0).replacingOccurrences(of: "__recursive__", with: "..") }
            .filter { !$0.isEmpty }
    }

    private static func jsonObject(from text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func stringify(_ value: Any) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return nil
    }
}

enum XPathLiteExtractor {
    static func nodes(_ expression: String, in html: String) -> [String] {
        let query = terminalTrimmed(expression)
        if let id = capture(query, pattern: #"^//\*\[@id=['"]([^'"]+)['"]\]$"#) {
            return html.matches(for: #"<([a-zA-Z0-9]+)[^>]*id=["']\#(id)["'][^>]*>[\s\S]*?</\1>"#)
        }
        if let className = capture(query, pattern: #"^//\*\[contains\(@class,\s*['"]([^'"]+)['"]\)\]$"#) {
            return html.matches(for: #"<([a-zA-Z0-9]+)[^>]*class=["'][^"']*\#(className)[^"']*["'][^>]*>[\s\S]*?</\1>"#)
        }
        if let (tag, attr, value) = tagPredicate(query) {
            return html.matches(for: #"<\#(tag)[^>]*\#(attr)=["']\#(value)["'][^>]*>[\s\S]*?</\#(tag)>"#)
        }
        if let tag = capture(query, pattern: #"^//([a-zA-Z0-9]+)$"#) ?? capture(query, pattern: #"^/+/([a-zA-Z0-9]+)$"#) {
            return html.matches(for: #"<\#(tag)\b[^>]*>[\s\S]*?</\#(tag)>"#)
        }
        return []
    }

    static func value(_ expression: String, in html: String) -> String {
        if expression.hasSuffix("/text()") {
            return stripTags(nodes(String(expression.dropLast("/text()".count)), in: html).first ?? "")
        }
        if let attribute = trailingAttribute(in: expression) {
            let selector = String(expression.dropLast(attribute.count + 2))
            return attributeValue(attribute, in: nodes(selector, in: html).first ?? "")
        }
        return stripTags(nodes(expression, in: html).first ?? "")
    }

    private static func terminalTrimmed(_ expression: String) -> String {
        if expression.hasSuffix("/text()") {
            return String(expression.dropLast("/text()".count))
        }
        if let attribute = trailingAttribute(in: expression) {
            return String(expression.dropLast(attribute.count + 2))
        }
        return expression
    }

    private static func tagPredicate(_ expression: String) -> (String, String, String)? {
        guard let regex = try? NSRegularExpression(pattern: #"^//([a-zA-Z0-9]+)\[@([A-Za-z0-9_\-]+)=['"]([^'"]+)['"]\]$"#),
              let match = regex.firstMatch(in: expression, range: NSRange(expression.startIndex..., in: expression)),
              match.numberOfRanges == 4,
              let tagRange = Range(match.range(at: 1), in: expression),
              let attrRange = Range(match.range(at: 2), in: expression),
              let valueRange = Range(match.range(at: 3), in: expression) else {
            return nil
        }
        return (String(expression[tagRange]), String(expression[attrRange]), String(expression[valueRange]))
    }

    private static func trailingAttribute(in expression: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"/@([A-Za-z0-9_\-]+)$"#),
              let match = regex.firstMatch(in: expression, range: NSRange(expression.startIndex..., in: expression)),
              match.numberOfRanges == 2,
              let range = Range(match.range(at: 1), in: expression) else {
            return nil
        }
        return String(expression[range])
    }

    private static func capture(_ text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    private static func attributeValue(_ name: String, in html: String) -> String {
        let pattern = #"\#(name)=["']([^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: html) else {
            return ""
        }
        return String(html[range]).htmlDecoded
    }

    private static func stripTags(_ html: String) -> String {
        html
            .replacingOccurrences(of: #"<script[\s\S]*?</script>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"<style[\s\S]*?</style>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .htmlDecoded
    }
}

struct WebDAVClient {
    func listDirectory(connection: NASConnection, path: URL) async throws -> [NASItem] {
        guard connection.kind == .webDAV else {
            throw AppServiceError.unsupportedProtocol(connection.kind.title)
        }

        let request = Self.authorizedRequest(url: path, connection: connection, method: "PROPFIND") { request in
            request.setValue("1", forHTTPHeaderField: "Depth")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response)

        return WebDAVResponseParser(baseURL: path).parse(data: data)
    }

    func makeDirectory(connection: NASConnection, parentURL: URL, name: String) async throws {
        guard connection.kind == .webDAV else {
            throw AppServiceError.unsupportedProtocol(connection.kind.title)
        }
        let folderName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folderName.isEmpty,
              let encoded = folderName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: encoded + "/", relativeTo: parentURL)?.absoluteURL else {
            throw AppServiceError.invalidResponse
        }
        let request = Self.authorizedRequest(url: url, connection: connection, method: "MKCOL")
        let (_, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response)
    }

    func deleteItem(connection: NASConnection, item: NASItem) async throws {
        guard connection.kind == .webDAV else {
            throw AppServiceError.unsupportedProtocol(connection.kind.title)
        }
        let request = Self.authorizedRequest(url: item.url, connection: connection, method: "DELETE")
        let (_, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response)
    }

    func downloadFile(connection: NASConnection, item: NASItem, cache: LibraryCache) async throws -> URL {
        guard connection.kind == .webDAV else {
            throw AppServiceError.unsupportedProtocol(connection.kind.title)
        }

        if item.url.scheme == "https" || item.url.scheme == "http" {
            let request = Self.authorizedRequest(url: item.url, connection: connection, method: "GET")
            let (temporaryURL, response) = try await URLSession.shared.download(for: request)
            try Self.validate(response)
            let destination = cache.localURL(for: item.url)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            return destination
        }

        if item.url.isFileURL {
            let destination = cache.localURL(for: item.url)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: item.url, to: destination)
            return destination
        }

        throw AppServiceError.invalidResponse
    }

    static func authorizedRequest(
        url: URL,
        connection: NASConnection,
        method: String,
        configure: ((inout URLRequest) -> Void)? = nil
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("NovelReaderApp WebDAV", forHTTPHeaderField: "User-Agent")
        if !connection.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let token = "\(connection.username):\(connection.password)"
                .data(using: .utf8)?
                .base64EncodedString() ?? ""
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        configure?(&request)
        return request
    }

    static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AppServiceError.invalidResponse
        }
        switch http.statusCode {
        case 200..<300:
            return
        case 401:
            throw AppServiceError.unauthorized
        case 403:
            throw AppServiceError.forbidden
        default:
            throw AppServiceError.invalidResponse
        }
    }
}

final class WebDAVResponseParser: NSObject, XMLParserDelegate {
    private let baseURL: URL
    private var items: [NASItem] = []
    private var currentElement = ""
    private var currentText = ""
    private var href = ""
    private var size: Int64?
    private var modifiedAt: Date?
    private var isCollection = false

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    func parse(data: Data) -> [NASItem] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return items.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = normalized(elementName)
        currentText = ""
        if currentElement == "response" {
            href = ""
            size = nil
            modifiedAt = nil
            isCollection = false
        }
        if currentElement == "collection" {
            isCollection = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let element = normalized(elementName)
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch element {
        case "href":
            href = text
        case "getcontentlength":
            size = Int64(text)
        case "getlastmodified":
            modifiedAt = HTTPDateParser.date(from: text)
        case "response":
            appendCurrentItem()
        default:
            break
        }
        currentText = ""
    }

    private func appendCurrentItem() {
        guard let decoded = href.removingPercentEncoding,
              let url = URL(string: decoded, relativeTo: baseURL)?.absoluteURL,
              url.normalizedPath != baseURL.normalizedPath else {
            return
        }
        let trimmed = decoded.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let fallbackName = trimmed.split(separator: "/").last.map(String.init) ?? decoded
        let name = url.lastPathComponent.isEmpty ? fallbackName : url.lastPathComponent
        items.append(
            NASItem(
                name: name,
                url: url,
                isDirectory: isCollection || decoded.hasSuffix("/"),
                size: size,
                modifiedAt: modifiedAt
            )
        )
    }

    private func normalized(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }
}

enum HTTPDateParser {
    static func date(from text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }
}

private extension URL {
    var normalizedPath: String {
        standardizedFileURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

struct NASPreviewFactory {
    static func previewItems(baseURL: URL) -> [NASItem] {
        [
            NASItem(name: "玄幻", url: baseURL.appending(path: "玄幻", directoryHint: .isDirectory), isDirectory: true, size: nil, modifiedAt: .now),
            NASItem(name: "科幻", url: baseURL.appending(path: "科幻", directoryHint: .isDirectory), isDirectory: true, size: nil, modifiedAt: .now),
            NASItem(name: "雾港旧事.txt", url: baseURL.appending(path: "雾港旧事.txt"), isDirectory: false, size: 824_100, modifiedAt: .now),
            NASItem(name: "星环纪元.epub", url: baseURL.appending(path: "星环纪元.epub"), isDirectory: false, size: 2_512_000, modifiedAt: .now)
        ]
    }
}

final class BonjourNASBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private var browsers: [NetServiceBrowser] = []
    private var services: [NetService] = []
    private var results: [NASDiscoveryResult] = []
    private var onUpdate: (([NASDiscoveryResult]) -> Void)?

    func start(onUpdate: @escaping ([NASDiscoveryResult]) -> Void) {
        stop()
        self.onUpdate = onUpdate
        let serviceTypes = ["_webdav._tcp.", "_http._tcp.", "_smb._tcp.", "_ssh._tcp."]
        browsers = serviceTypes.map { type in
            let browser = NetServiceBrowser()
            browser.delegate = self
            browser.searchForServices(ofType: type, inDomain: "local.")
            return browser
        }
    }

    func stop() {
        browsers.forEach { $0.stop() }
        services.forEach { $0.stop() }
        browsers.removeAll()
        services.removeAll()
        results.removeAll()
        onUpdate?(results)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        services.append(service)
        service.resolve(withTimeout: 3)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeAll { $0 == service }
        results.removeAll { $0.name == service.name }
        onUpdate?(results)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let kind = kind(for: sender.type) else { return }
        let host = sender.hostName?.trimmingCharacters(in: CharacterSet(charactersIn: ".")) ?? sender.name
        let result = NASDiscoveryResult(name: sender.name, kind: kind, host: host, port: sender.port)
        if !results.contains(where: { $0.name == result.name && $0.kind == result.kind && $0.host == result.host }) {
            results.append(result)
        }
        onUpdate?(results.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
    }

    private func kind(for type: String) -> NASKind? {
        if type.contains("_webdav") { return .webDAV }
        if type.contains("_http") { return .readerServer }
        if type.contains("_smb") { return .smb }
        if type.contains("_ssh") { return .sftp }
        return nil
    }
}

extension String {
    var selectorKey: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "#", with: "")
    }

    var htmlDecoded: String {
        replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }

    func matches(for pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(startIndex..., in: self)
        return regex.matches(in: self, range: range).compactMap { match in
            guard let range = Range(match.range, in: self) else { return nil }
            return String(self[range])
        }
    }
}
