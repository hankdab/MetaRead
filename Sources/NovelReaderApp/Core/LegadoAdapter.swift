import Foundation

struct LegadoBookSource: Codable {
    var bookSourceName: String
    var bookSourceUrl: String
    var bookSourceType: Int?
    var enabled: Bool?
    var searchUrl: String?
    var ruleSearch: LegadoRuleSearch?
    var ruleBookInfo: LegadoRuleBookInfo?
    var ruleToc: LegadoRuleToc?
    var ruleContent: LegadoRuleContent?
}

struct LegadoRuleSearch: Codable {
    var bookList: String?
    var name: String?
    var author: String?
    var bookUrl: String?
    var intro: String?
}

struct LegadoRuleBookInfo: Codable {
    var name: String?
    var author: String?
    var intro: String?
    var tocUrl: String?
}

struct LegadoRuleToc: Codable {
    var chapterList: String?
    var chapterName: String?
    var chapterUrl: String?
}

struct LegadoRuleContent: Codable {
    var content: String?
    var title: String?
    var sourceRegex: String?
}

enum LegadoSourceAdapter {
    static func decodeSources(from data: Data) throws -> [BookSource] {
        let decoder = JSONDecoder.appDecoder
        if let array = try? decoder.decode([LegadoBookSource].self, from: data) {
            return array.compactMap(convert)
        }
        let source = try decoder.decode(LegadoBookSource.self, from: data)
        return [convert(source)].compactMap { $0 }
    }

    private static func convert(_ source: LegadoBookSource) -> BookSource? {
        let baseURLString = source.bookSourceUrl
            .components(separatedBy: "##")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? source.bookSourceUrl
        guard let baseURL = URL(string: baseURLString) else { return nil }
        let search = source.ruleSearch
        let toc = source.ruleToc
        let content = source.ruleContent
        let info = source.ruleBookInfo
        let bookURLSelector = preferredBookURLSelector(search?.bookUrl, tocURL: info?.tocUrl)

        return BookSource(
            name: source.bookSourceName,
            baseURL: baseURL,
            isEnabled: source.enabled ?? true,
            rule: SourceRule(
                searchPath: normalizeImportedSearchPath(source.searchUrl ?? ""),
                resultListSelector: normalizeSelector(search?.bookList ?? ".result"),
                titleSelector: normalizeSelector(search?.name ?? info?.name ?? ".title@text"),
                authorSelector: normalizeSelector(search?.author ?? info?.author ?? ".author@text"),
                bookURLSelector: normalizeSelector(bookURLSelector),
                tocListSelector: normalizeSelector(toc?.chapterList ?? ".chapter-list a"),
                chapterTitleSelector: normalizeSelector(toc?.chapterName ?? "@text"),
                chapterURLSelector: normalizeSelector(toc?.chapterUrl ?? "@href"),
                contentSelector: normalizeSelector(content?.content ?? "#content@html"),
                replacements: regexReplacements(from: content?.sourceRegex)
            )
        )
    }

    static func normalizeImportedSearchPath(_ value: String) -> String {
        let normalized = replaceKeywordTokens(in: value.trimmingCharacters(in: .whitespacesAndNewlines))
        if let extracted = extractStaticSearchPath(from: normalized) {
            return replaceKeywordTokens(in: extracted)
        }
        return normalized
    }

    private static func replaceKeywordTokens(in value: String) -> String {
        value
            .replacingOccurrences(of: "{{searchKey}}", with: "{{keyword}}")
            .replacingOccurrences(of: "{{key}}", with: "{{keyword}}")
            .replacingOccurrences(of: "{{ keyword }}", with: "{{keyword}}")
            .replacingOccurrences(of: "{{ key }}", with: "{{keyword}}")
            .replacingOccurrences(of: "{{ searchKey }}", with: "{{keyword}}")
            .replacingOccurrences(of: "{{keyword}}$", with: "{{keyword}}")
    }

    private static func extractStaticSearchPath(from value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<js>"), let end = trimmed.range(of: "</js>") {
            let script = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 4)..<end.lowerBound])
            let suffix = String(trimmed[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !suffix.isEmpty {
                return suffix
            }
            return firstRequestLikeLiteral(in: script)
        }

        if trimmed.hasPrefix("@js:") {
            let script = String(trimmed.dropFirst(4))
            if let baseRelative = firstCapture(#"baseUrl\s*\+\s*"([^"]+)""#, in: script) {
                return baseRelative
            }
            return firstRequestLikeLiteral(in: script)
        }

        return nil
    }

    private static func firstRequestLikeLiteral(in script: String) -> String? {
        let trimmedScript = script.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedScript.hasPrefix("/") || trimmedScript.hasPrefix("http://") || trimmedScript.hasPrefix("https://") {
            let terminators = [";result", "; result", "\n"]
            let end = terminators
                .compactMap { trimmedScript.range(of: $0)?.lowerBound }
                .min()
            if let end {
                return String(trimmedScript[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return trimmedScript
        }

        let patterns = [
            #"`([^`]*\{\{(?:keyword|searchKey|key)[^`]*)`"#,
            #""([^"]*\{\{(?:keyword|searchKey|key)[^"]*)""#,
            #"'([^']*\{\{(?:keyword|searchKey|key)[^']*)'"#
        ]
        let candidates = patterns.flatMap { captures($0, in: script) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { candidate in
                candidate.contains("{{")
                    && (candidate.contains("search") || candidate.contains("query") || candidate.contains("keyword") || candidate.contains("/so/") || candidate.hasPrefix("/") || candidate.hasPrefix("http"))
            }
        return candidates.first { candidate in
            let lower = candidate.lowercased()
            return lower.contains("search") || lower.contains("query=") || lower.contains("keyword=") || lower.contains("/so/")
        } ?? candidates.first { candidate in
            let lower = candidate.lowercased()
            return !lower.contains("detail") && !lower.contains("book_id")
        } ?? candidates.first
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        captures(pattern, in: text).first
    }

    private static func captures(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let captureRange = Range(match.range(at: 1), in: text) else {
                return nil
            }
            return String(text[captureRange])
        }
    }

    private static func preferredBookURLSelector(_ bookURL: String?, tocURL: String?) -> String {
        guard let tocURL,
              isDirectURLRule(tocURL) else {
            return bookURL ?? "@href"
        }
        return tocURL
    }

    private static func isDirectURLRule(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.hasPrefix("http://")
            || trimmed.hasPrefix("https://")
            || trimmed.hasPrefix("/")
    }

    private static func normalizeSelector(_ value: String) -> String {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized = normalized.replacingOccurrences(of: "@css:", with: "")
        normalized = normalized.replacingOccurrences(of: "@XPath:", with: "")
        normalized = normalized.replacingOccurrences(of: "@xpath:", with: "")

        if normalized == "text" || normalized == "@text" {
            return "@text"
        }
        if normalized == "href" || normalized == "@href" {
            return "@href"
        }

        if normalized.hasPrefix("$.") || normalized.hasPrefix("$[") || normalized.contains("<js>") {
            return normalized
        }

        return normalized
            .replacingOccurrences(of: "@textNodes", with: "@text")
            .replacingOccurrences(of: "@html", with: "@html")
    }

    private static func regexReplacements(from sourceRegex: String?) -> [ReplacementRule] {
        guard let sourceRegex,
              !sourceRegex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        return [
            ReplacementRule(pattern: sourceRegex, replacement: "", isRegex: true, isEnabled: true)
        ]
    }
}
