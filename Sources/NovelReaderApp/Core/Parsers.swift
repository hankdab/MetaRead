import Compression
import Foundation

struct TextDecoder {
    func decode(_ data: Data) -> String? {
        let encodings: [String.Encoding] = [
            .utf8,
            .unicode,
            .utf16,
            .utf16LittleEndian,
            .utf16BigEndian,
            .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))),
            .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_2312_80.rawValue)))
        ]

        for encoding in encodings {
            if let text = String(data: data, encoding: encoding), !text.isEmpty {
                return text
            }
        }
        return nil
    }
}

struct PlainTextBookParser {
    func parse(title: String, author: String, text: String) -> Book {
        let chapters = splitChapters(text)
        return Book(
            title: title,
            author: author,
            summary: "从本地或 NAS 导入的 TXT 小说。",
            coverSymbol: "doc.text.fill",
            format: .txt,
            sourceName: "导入",
            localURL: nil,
            status: .unread,
            progress: ReadingProgress(chapterIndex: 0, scrollOffset: 0, percentage: 0),
            chapters: chapters,
            addedAt: .now,
            updatedAt: .now
        )
    }

    private func splitChapters(_ text: String) -> [Chapter] {
        let lines = text.components(separatedBy: .newlines)
        var chapters: [Chapter] = []
        var currentTitle = "正文"
        var buffer: [String] = []
        var index = 0
        let pattern = #"^\s*(第[一二三四五六七八九十百千万零〇\d]+[章节卷回].*|Chapter\s+\d+.*)$"#

        for line in lines {
            if line.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                if !buffer.isEmpty {
                    chapters.append(Chapter(index: index, title: currentTitle, url: nil, localText: buffer.joined(separator: "\n"), isDownloaded: true))
                    index += 1
                    buffer.removeAll()
                }
                currentTitle = line.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                buffer.append(line)
            }
        }

        if !buffer.isEmpty {
            chapters.append(Chapter(index: index, title: currentTitle, url: nil, localText: buffer.joined(separator: "\n"), isDownloaded: true))
        }

        if chapters.isEmpty {
            return [Chapter(index: 0, title: "正文", url: nil, localText: text, isDownloaded: true)]
        }
        return chapters
    }
}

struct EPUBBookParser {
    func parse(url: URL, author: String, sourceName: String) throws -> Book {
        let archive = try ZIPArchive(url: url)
        let container = try archive.textFile(named: "META-INF/container.xml")
        guard let opfPath = container.firstXMLAttribute(tag: "rootfile", attribute: "full-path") else {
            throw AppServiceError.invalidResponse
        }
        let opf = try archive.textFile(named: opfPath)
        let basePath = URL(fileURLWithPath: opfPath).deletingLastPathComponent().relativePath
        let title = opf.firstXMLText(tag: "dc:title")
            ?? opf.firstXMLText(tag: "title")
            ?? url.deletingPathExtension().lastPathComponent
        let creator = opf.firstXMLText(tag: "dc:creator") ?? author
        let manifest = EPUBManifest.parse(opf)
        let spineIDs = opf.xmlAttributeValues(tag: "itemref", attribute: "idref")
        let navTitles = EPUBNavigationTitles.parse(opf: opf, manifest: manifest, archive: archive, basePath: basePath)
        let coverPath = EPUBCoverDetector.coverPath(opf: opf, manifest: manifest, basePath: basePath)
        let coverImageURL = coverPath.flatMap { try? EPUBCoverCache().storeCover(from: archive, path: $0, bookURL: url) }
        let hasCover = coverImageURL != nil || coverPath != nil

        let chapters = spineIDs.enumerated().compactMap { index, idref -> Chapter? in
            guard let item = manifest[idref] else { return nil }
            let path = EPUBPathResolver.resolve(item.href, relativeTo: basePath)
            guard let html = try? archive.textFile(named: path) else { return nil }
            let chapterTitle = navTitles[item.href] ?? navTitles[path] ?? html.firstHTMLTitle ?? item.title ?? "第 \(index + 1) 章"
            let text = html.readableHTMLText
            return Chapter(index: index, title: chapterTitle, url: nil, localText: text, isDownloaded: true)
        }

        guard !chapters.isEmpty else {
            throw AppServiceError.invalidResponse
        }

        return Book(
            title: title.htmlDecoded,
            author: creator.htmlDecoded,
            summary: hasCover ? "从 EPUB 文件解析导入，已检测到封面资源。" : "从 EPUB 文件解析导入。",
            coverSymbol: hasCover ? "photo.on.rectangle.angled.fill" : "text.book.closed.fill",
            coverImageURL: coverImageURL,
            format: .epub,
            sourceName: sourceName,
            localURL: url,
            status: .unread,
            progress: ReadingProgress(chapterIndex: 0, scrollOffset: 0, percentage: 0),
            chapters: chapters,
            addedAt: .now,
            updatedAt: .now
        )
    }

    func parsePlaceholder(title: String, author: String, sourceName: String, localURL: URL) -> Book {
        Book(
            title: title,
            author: author,
            summary: "EPUB 文件已保存到本地缓存，待接入 EPUB 解包与 OPF/NCX 解析。",
            coverSymbol: "text.book.closed.fill",
            format: .epub,
            sourceName: sourceName,
            localURL: localURL,
            status: .unread,
            progress: ReadingProgress(chapterIndex: 0, scrollOffset: 0, percentage: 0),
            chapters: [
                Chapter(
                    index: 0,
                    title: "EPUB 已缓存",
                    url: nil,
                    localText: """
                    这个 EPUB 文件已经保存到本地缓存。

                    下一步接入 EPUB 解包后，会读取 container.xml、OPF spine、NCX/nav 目录，并把真实章节写入书架。
                    """,
                    isDownloaded: true
                )
            ],
            addedAt: .now,
            updatedAt: .now
        )
    }
}

private struct EPUBManifestItem {
    var id: String
    var href: String
    var mediaType: String
    var title: String?
}

private enum EPUBManifest {
    static func parse(_ opf: String) -> [String: EPUBManifestItem] {
        let itemPattern = #"<item\b[^>]*>"#
        var items: [String: EPUBManifestItem] = [:]
        for rawItem in opf.matches(for: itemPattern) {
            guard let id = rawItem.xmlAttribute("id"),
                  let href = rawItem.xmlAttribute("href") else {
                continue
            }
            let mediaType = rawItem.xmlAttribute("media-type") ?? ""
            let title = rawItem.xmlAttribute("properties")
            items[id] = EPUBManifestItem(id: id, href: href, mediaType: mediaType, title: title)
        }
        return items
    }
}

private enum EPUBNavigationTitles {
    static func parse(opf: String, manifest: [String: EPUBManifestItem], archive: ZIPArchive, basePath: String) -> [String: String] {
        if let navItem = manifest.values.first(where: { $0.title?.contains("nav") == true || $0.href.lowercased().contains("nav.") }),
           let nav = try? archive.textFile(named: EPUBPathResolver.resolve(navItem.href, relativeTo: basePath)) {
            let titles = parseNavHTML(nav)
            if !titles.isEmpty { return titles }
        }

        if let ncxItem = manifest.values.first(where: { $0.mediaType.contains("ncx") || $0.href.lowercased().hasSuffix(".ncx") }),
           let ncx = try? archive.textFile(named: EPUBPathResolver.resolve(ncxItem.href, relativeTo: basePath)) {
            return parseNCX(ncx)
        }

        return [:]
    }

    private static func parseNavHTML(_ html: String) -> [String: String] {
        let linkPattern = #"<a\b[^>]*href=["']([^"']+)["'][^>]*>([\s\S]*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: linkPattern, options: [.caseInsensitive]) else { return [:] }
        let range = NSRange(html.startIndex..., in: html)
        var titles: [String: String] = [:]
        for match in regex.matches(in: html, range: range) where match.numberOfRanges > 2 {
            guard let hrefRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html) else {
                continue
            }
            let href = String(html[hrefRange]).withoutFragment
            let title = String(html[titleRange]).strippingTags.trimmingCharacters(in: .whitespacesAndNewlines).htmlDecoded
            if !href.isEmpty && !title.isEmpty {
                titles[href] = title
            }
        }
        return titles
    }

    private static func parseNCX(_ ncx: String) -> [String: String] {
        let pointPattern = #"<navPoint\b[\s\S]*?</navPoint>"#
        var titles: [String: String] = [:]
        for point in ncx.matches(for: pointPattern) {
            guard let src = point.firstXMLAttribute(tag: "content", attribute: "src")?.withoutFragment,
                  let text = point.firstXMLText(tag: "text")?.htmlDecoded,
                  !text.isEmpty else {
                continue
            }
            titles[src] = text
        }
        return titles
    }
}

private enum EPUBCoverDetector {
    static func coverPath(opf: String, manifest: [String: EPUBManifestItem], basePath: String) -> String? {
        if let coverID = opf.firstXMLAttribute(tag: "meta", attribute: "content"),
           let item = manifest[coverID],
           item.mediaType.hasPrefix("image/") {
            return EPUBPathResolver.resolve(item.href, relativeTo: basePath)
        }
        let item = manifest.values.first { item in
            item.mediaType.hasPrefix("image/")
                && (item.title?.contains("cover-image") == true || item.href.lowercased().contains("cover"))
        }
        return item.map { EPUBPathResolver.resolve($0.href, relativeTo: basePath) }
    }
}

private struct EPUBCoverCache {
    var directory: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appending(path: "NovelReaderApp/Covers", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func storeCover(from archive: ZIPArchive, path: String, bookURL: URL) throws -> URL {
        let data = try archive.dataFile(named: path)
        let ext = URL(fileURLWithPath: path).pathExtension.isEmpty ? "jpg" : URL(fileURLWithPath: path).pathExtension
        let safeBase = bookURL.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: #"[^A-Za-z0-9_-]+"#, with: "-", options: .regularExpression)
        let destination = directory.appending(path: "\(safeBase)-\(UUID().uuidString).\(ext)")
        try data.write(to: destination, options: [.atomic])
        return destination
    }
}

private enum EPUBPathResolver {
    static func resolve(_ href: String, relativeTo basePath: String) -> String {
        guard !basePath.isEmpty && basePath != "." else { return href }
        return URL(fileURLWithPath: basePath).appending(path: href).standardized.relativePath
    }
}

struct ZIPArchive {
    private let data: Data
    private let entries: [String: ZIPEntry]

    init(url: URL) throws {
        data = try Data(contentsOf: url)
        entries = try ZIPArchive.readEntries(from: data)
    }

    func textFile(named name: String) throws -> String {
        let fileData = try dataFile(named: name)
        guard let text = TextDecoder().decode(fileData) else {
            throw AppServiceError.invalidResponse
        }
        return text
    }

    func dataFile(named name: String) throws -> Data {
        let normalizedName = name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let entry = entries[normalizedName] else {
            throw AppServiceError.invalidResponse
        }
        return try entry.extract(from: data)
    }

    private static func readEntries(from data: Data) throws -> [String: ZIPEntry] {
        guard let eocdOffset = data.lastRange(of: Data([0x50, 0x4b, 0x05, 0x06]))?.lowerBound else {
            throw AppServiceError.invalidResponse
        }
        let centralDirectorySize = Int(data.uint32LE(at: eocdOffset + 12))
        let centralDirectoryOffset = Int(data.uint32LE(at: eocdOffset + 16))
        let centralDirectoryEnd = min(centralDirectoryOffset + centralDirectorySize, data.count)
        var offset = centralDirectoryOffset
        var entries: [String: ZIPEntry] = [:]

        while offset + 46 <= centralDirectoryEnd && data.uint32LE(at: offset) == 0x02014b50 {
            let method = Int(data.uint16LE(at: offset + 10))
            let compressedSize = Int(data.uint32LE(at: offset + 20))
            let uncompressedSize = Int(data.uint32LE(at: offset + 24))
            let nameLength = Int(data.uint16LE(at: offset + 28))
            let extraLength = Int(data.uint16LE(at: offset + 30))
            let commentLength = Int(data.uint16LE(at: offset + 32))
            let localHeaderOffset = Int(data.uint32LE(at: offset + 42))
            let nameStart = offset + 46
            let nameEnd = nameStart + nameLength
            guard nameEnd <= data.count else { break }
            let name = String(decoding: data[nameStart..<nameEnd], as: UTF8.self)
            entries[name] = ZIPEntry(
                name: name,
                method: method,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localHeaderOffset
            )
            offset = nameEnd + extraLength + commentLength
        }

        return entries
    }
}

private struct ZIPEntry {
    var name: String
    var method: Int
    var compressedSize: Int
    var uncompressedSize: Int
    var localHeaderOffset: Int

    func extract(from archive: Data) throws -> Data {
        let local = localHeaderOffset
        guard archive.uint32LE(at: local) == 0x04034b50 else {
            throw AppServiceError.invalidResponse
        }
        let nameLength = Int(archive.uint16LE(at: local + 26))
        let extraLength = Int(archive.uint16LE(at: local + 28))
        let dataStart = local + 30 + nameLength + extraLength
        let dataEnd = dataStart + compressedSize
        guard dataEnd <= archive.count else {
            throw AppServiceError.invalidResponse
        }
        let compressed = Data(archive[dataStart..<dataEnd])
        switch method {
        case 0:
            return compressed
        case 8:
            return try inflate(compressed)
        default:
            throw AppServiceError.unsupportedFileType("ZIP compression method \(method)")
        }
    }

    private func inflate(_ compressed: Data) throws -> Data {
        let outputCapacity = max(uncompressedSize, 1)
        var output = Data(count: outputCapacity)
        let decodedCount = output.withUnsafeMutableBytes { outputBuffer in
            compressed.withUnsafeBytes { inputBuffer in
                compression_decode_buffer(
                    outputBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    outputCapacity,
                    inputBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    compressed.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard decodedCount > 0 else {
            throw AppServiceError.invalidResponse
        }
        output.removeSubrange(decodedCount..<output.count)
        return output
    }
}

private extension Data {
    func uint16LE(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return self[offset..<offset + 2].enumerated().reduce(UInt16(0)) { result, pair in
            result | (UInt16(pair.element) << UInt16(pair.offset * 8))
        }
    }

    func uint32LE(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return self[offset..<offset + 4].enumerated().reduce(UInt32(0)) { result, pair in
            result | (UInt32(pair.element) << UInt32(pair.offset * 8))
        }
    }
}

private extension String {
    func firstXMLText(tag: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: tag)
        let pattern = #"<\#(escaped)\b[^>]*>([\s\S]*?)</\#(escaped)>"#
        return firstCapture(pattern: pattern)?.strippingTags.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func firstXMLAttribute(tag: String, attribute: String) -> String? {
        matches(for: #"<\#(tag)\b[^>]*>"#).first?.xmlAttribute(attribute)
    }

    func xmlAttributeValues(tag: String, attribute: String) -> [String] {
        matches(for: #"<\#(tag)\b[^>]*>"#).compactMap { $0.xmlAttribute(attribute) }
    }

    func xmlAttribute(_ name: String) -> String? {
        firstCapture(pattern: #"\#(name)=["']([^"']+)["']"#)?.htmlDecoded
    }

    var firstHTMLTitle: String? {
        firstXMLText(tag: "title")
            ?? firstXMLText(tag: "h1")
            ?? firstXMLText(tag: "h2")
    }

    var readableHTMLText: String {
        strippingTags
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .htmlDecoded
    }

    var withoutFragment: String {
        components(separatedBy: "#").first ?? self
    }

    var strippingTags: String {
        replacingOccurrences(of: #"<script[\s\S]*?</script>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"<style[\s\S]*?</style>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"</p>"#, with: "\n\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
    }

    func firstCapture(pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(startIndex..., in: self)
        guard let match = regex.firstMatch(in: self, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: self) else {
            return nil
        }
        return String(self[captureRange])
    }
}

struct ContentCleaner {
    func clean(_ text: String, replacements: [ReplacementRule]) -> String {
        replacements.filter(\.isEnabled).reduce(text) { partial, rule in
            if rule.isRegex {
                return partial.replacingOccurrences(of: rule.pattern, with: rule.replacement, options: .regularExpression)
            }
            return partial.replacingOccurrences(of: rule.pattern, with: rule.replacement)
        }
    }
}
