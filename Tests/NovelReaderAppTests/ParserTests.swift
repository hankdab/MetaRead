import XCTest
@testable import NovelReaderApp

final class ParserTests: XCTestCase {
    func testPlainTextParserSplitsChineseChapters() {
        let text = """
        第一章 起
        正文一
        第二章 承
        正文二
        """

        let book = PlainTextBookParser().parse(title: "测试", author: "作者", text: text)

        XCTAssertEqual(book.chapters.count, 2)
        XCTAssertEqual(book.chapters[0].title, "第一章 起")
        XCTAssertTrue(book.chapters[1].localText.contains("正文二"))
    }

    func testContentCleanerSupportsPlainAndRegexRules() {
        let rules = [
            ReplacementRule(pattern: "广告", replacement: "", isRegex: false, isEnabled: true),
            ReplacementRule(pattern: #"第\d+页"#, replacement: "", isRegex: true, isEnabled: true)
        ]

        let text = ContentCleaner().clean("正文广告第12页结束", replacements: rules)

        XCTAssertEqual(text, "正文结束")
    }

    func testHTMLExtractorReadsClassTextAndHref() {
        let html = #"<div class="result"><a class="title" href="/book/1">书名</a><span class="author">作者</span></div>"#
        let extractor = SimpleHTMLExtractor()
        let node = extractor.nodes(matching: ".result", in: html).first ?? ""

        XCTAssertEqual(extractor.value(".title@text", in: node), "书名")
        XCTAssertEqual(extractor.value(".title@href", in: node), "/book/1")
        XCTAssertEqual(extractor.value(".author@text", in: node), "作者")
    }

    func testHTMLExtractorReadsLegadoChainSelector() {
        let html = #"<tr><td><a href="/book/1">书名</a><a title="作者标题">作者</a></td></tr>"#
        let extractor = SimpleHTMLExtractor()

        XCTAssertEqual(extractor.value("@a.0@text", in: html), "书名")
        XCTAssertEqual(extractor.value("@a.0@href", in: html), "/book/1")
        XCTAssertEqual(extractor.value("@a.1@title", in: html), "作者标题")
    }

    func testJSONRuleExtractorReadsBasicJSONPath() {
        let json = #"{"data":{"list":[{"title":"书名","author":"作者"},{"title":"第二本","author":"佚名"}]}}"#

        XCTAssertEqual(JSONRuleExtractor.nodes("$.data.list[*]", in: json).count, 2)
        XCTAssertEqual(JSONRuleExtractor.value("$.data.list[0].title", in: json), "书名")
    }

    func testJSONRuleExtractorReadsRecursiveBracketAndFilterRules() {
        let json = #"{"data":{"list":[{"title":"书名","author":"作者"},{"title":"第二本","author":"佚名"}]},"meta":{"title":"站点标题"}}"#

        XCTAssertEqual(JSONRuleExtractor.value("$['data']['list'][1]['title']", in: json), "第二本")
        XCTAssertEqual(JSONRuleExtractor.value("$.data.list[?(@.author=='作者')].title", in: json), "书名")
        XCTAssertEqual(JSONRuleExtractor.nodes("$..title", in: json).count, 3)
    }

    func testXPathLiteExtractorReadsTextAndAttributes() {
        let html = #"<div class="result"><a id="book-link" href="/book/1">书名</a><p class="intro main">简介</p></div>"#
        let extractor = SimpleHTMLExtractor()

        XCTAssertEqual(extractor.nodes(matching: "//*[contains(@class,'result')]", in: html).count, 1)
        XCTAssertEqual(extractor.value("//*[@id='book-link']/text()", in: html), "书名")
        XCTAssertEqual(extractor.value("//a[@id='book-link']/@href", in: html), "/book/1")
        XCTAssertEqual(extractor.value("//*[contains(@class,'intro')]/text()", in: html), "简介")
    }

    func testJSRuleEvaluatorReadsInputHTML() {
        let html = #"<div id="content">正文</div>"#
        let extractor = SimpleHTMLExtractor()

        XCTAssertEqual(extractor.value("<js>return result.replace(/<[^>]+>/g, '');</js>", in: html), "正文")
    }

    func testRuleTemplateRendersSearchVariables() {
        let expression = RuleTemplate.render("/search?q={{keyword}}&raw={{keywordRaw}}&page={{page}},{" + #""method":"POST","body":"key={{key}}"}"#, keyword: "三 体", page: 3)
        let encodedKeyword = "三 体".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "三 体"

        XCTAssertTrue(expression.contains("q=\(encodedKeyword)"))
        XCTAssertTrue(expression.contains("raw=三 体"))
        XCTAssertTrue(expression.contains("page=3"))
        XCTAssertTrue(expression.contains("body\":\"key=\(encodedKeyword)"))
    }

    func testRuleRequestBuilderParsesPostOptions() throws {
        let expression = #"/search,{"method":"POST","body":"key={{keyword}}","headers":"{\"X-Test\":\"1\"}","charset":"gbk"}"#

        let request = try RuleRequestBuilder.request(from: expression, baseURL: URL(string: "https://example.com")!)

        XCTAssertEqual(request.url?.absoluteString, "https://example.com/search")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(String(data: request.httpBody ?? Data(), encoding: .utf8), "key={{keyword}}")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Test"), "1")
    }

    func testRuleRequestBuilderParsesHeaderObject() throws {
        let expression = #"/search,{"headers":{"X-Test":"1","X-Page":2}}"#

        let request = try RuleRequestBuilder.request(from: expression, baseURL: URL(string: "https://example.com")!)

        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Test"), "1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Page"), "2")
    }

    func testBookSourceEngineParsesChapterContentWithCleaner() throws {
        let source = BookSource(
            name: "测试源",
            baseURL: URL(string: "https://example.com")!,
            isEnabled: true,
            rule: SourceRule(
                searchPath: "/search?q={{keyword}}",
                resultListSelector: ".result",
                titleSelector: ".title@text",
                authorSelector: ".author@text",
                bookURLSelector: ".title@href",
                tocListSelector: ".chapter-list a",
                chapterTitleSelector: "@text",
                chapterURLSelector: "@href",
                contentSelector: "#content@html",
                replacements: [
                    ReplacementRule(pattern: "广告", replacement: "", isRegex: false, isEnabled: true)
                ]
            )
        )
        let html = #"<html><body><article id="content"><p>正文广告内容</p></article></body></html>"#

        let text = try BookSourceEngine().parseChapterContent(data: Data(html.utf8), source: source)

        XCTAssertEqual(text, "正文内容")
    }

    func testEPUBPlaceholderKeepsLocalURLAndReadableChapter() {
        let url = URL(fileURLWithPath: "/tmp/book.epub")

        let book = EPUBBookParser().parsePlaceholder(title: "书", author: "作者", sourceName: "本地", localURL: url)

        XCTAssertEqual(book.format, .epub)
        XCTAssertEqual(book.localURL, url)
        XCTAssertEqual(book.chapters.count, 1)
        XCTAssertTrue(book.chapters[0].localText.contains("container.xml"))
    }

    func testEPUBParserReadsMinimalStoredArchive() throws {
        let epubURL = try makeMinimalEPUB()

        let book = try EPUBBookParser().parse(url: epubURL, author: "未知", sourceName: "测试")

        XCTAssertEqual(book.title, "测试 EPUB")
        XCTAssertEqual(book.author, "作者")
        XCTAssertEqual(book.chapters.count, 1)
        XCTAssertEqual(book.chapters[0].title, "目录里的第一章")
        XCTAssertTrue(book.chapters[0].localText.contains("正文内容"))
        XCTAssertTrue(book.summary.contains("封面"))
        XCTAssertNotNil(book.coverImageURL)
    }

    func testWebDAVParserReadsDirectoryFileSizeAndDate() {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/books/</D:href>
            <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat>
          </D:response>
          <D:response>
            <D:href>/books/dir/</D:href>
            <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat>
          </D:response>
          <D:response>
            <D:href>/books/a%20book.txt</D:href>
            <D:propstat><D:prop><D:getcontentlength>42</D:getcontentlength><D:getlastmodified>Wed, 29 Apr 2026 10:00:00 GMT</D:getlastmodified></D:prop></D:propstat>
          </D:response>
        </D:multistatus>
        """

        let items = WebDAVResponseParser(baseURL: URL(string: "https://nas.local/books/")!).parse(data: Data(xml.utf8))

        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items[0].isDirectory)
        XCTAssertEqual(items[0].name, "dir")
        XCTAssertEqual(items[1].name, "a book.txt")
        XCTAssertEqual(items[1].size, 42)
        XCTAssertNotNil(items[1].modifiedAt)
    }

    func testWebDAVRequestAddsBasicAuthAndDepthHeader() throws {
        let connection = NASConnection(
            name: "家里 NAS",
            kind: .webDAV,
            baseURL: URL(string: "https://nas.local/books/")!,
            username: "reader",
            password: "secret",
            isEnabled: true
        )

        let request = WebDAVClient.authorizedRequest(url: connection.baseURL, connection: connection, method: "PROPFIND") { request in
            request.setValue("1", forHTTPHeaderField: "Depth")
        }

        let token = Data("reader:secret".utf8).base64EncodedString()
        XCTAssertEqual(request.httpMethod, "PROPFIND")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic \(token)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Depth"), "1")
    }

    func testWebDAVValidateMapsAuthFailures() throws {
        let url = URL(string: "https://nas.local/books/")!
        let unauthorized = HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)!
        let forbidden = HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)!

        XCTAssertThrowsError(try WebDAVClient.validate(unauthorized)) { error in
            XCTAssertEqual(error.localizedDescription, AppServiceError.unauthorized.localizedDescription)
        }
        XCTAssertThrowsError(try WebDAVClient.validate(forbidden)) { error in
            XCTAssertEqual(error.localizedDescription, AppServiceError.forbidden.localizedDescription)
        }
    }

    func testExtractorUsesFirstNonEmptyFallbackRule() throws {
        let json = #"{"title":"紅樓夢","formats":{"text/plain; charset=utf-8":"https://example.com/book.txt"}}"#
        let extractor = SimpleHTMLExtractor()

        XCTAssertEqual(extractor.value("$.missing || $.title", in: json), "紅樓夢")
        XCTAssertEqual(
            extractor.value("$.formats['text/plain'] || $.formats['text/plain; charset=utf-8']", in: json),
            "https://example.com/book.txt"
        )
    }

    func testExtractorRendersJSONTemplatesAndRegexFilters() throws {
        let json = #"{"book_id":"42","chapter_id":"9","chapter_title":"正文 第一章","result":{"content":"正文内容"}}"#
        let extractor = SimpleHTMLExtractor()

        XCTAssertEqual(extractor.value("/novels/api/book/{{$.book_id}}/chapters/{{$.chapter_id}}", in: json), "/novels/api/book/42/chapters/9")
        XCTAssertEqual(extractor.value("$.chapter_title##正文\\s*", in: json), "第一章")
        XCTAssertEqual(extractor.value("{{$.result.content}}", in: json), "正文内容")
        XCTAssertEqual(extractor.value("/static/path", in: json), "/static/path")
    }

    func testJSONRuleExtractorExpandsArrayTerminalNodes() throws {
        let json = #"{"data":[{"title":"第一本"},{"title":"第二本"}]}"#

        XCTAssertEqual(JSONRuleExtractor.nodes("$.data", in: json).count, 2)
    }

    func testLegadoStyleClassAndTagSelectors() throws {
        let html = #"<li class="item"><h3><a href="/book/1">书名</a></h3><label>作者</label></li>"#
        let extractor = SimpleHTMLExtractor()
        let node = extractor.nodes(matching: "class.item", in: html).first ?? ""

        XCTAssertEqual(extractor.value("tag.h3.0@tag.a.0@text", in: node), "书名")
        XCTAssertEqual(extractor.value("tag.h3.0@tag.a.0@href", in: node), "/book/1")
        XCTAssertEqual(extractor.value("tag.label.0@text", in: node), "作者")
    }

    func testBuiltInSourcesIncludeUsablePublicDomainPresets() throws {
        let names = BuiltInBookSources.all.map(\.name)

        XCTAssertTrue(names.contains("古登堡公版书库"))
        XCTAssertTrue(names.contains("古登堡中文公版"))
        XCTAssertTrue(names.contains("古登堡英文公版"))
        XCTAssertTrue(BuiltInBookSources.all.filter { $0.name.hasPrefix("古登堡") }.allSatisfy { $0.rule.tocListSelector == "$directText" })
        XCTAssertTrue(names.contains("酷我小说"))
    }

    func testRemoteBookSourcePacksIncludeReaderAndXIU2Sources() throws {
        let urls = RemoteBookSourcePacks.all.map(\.url.absoluteString)

        XCTAssertTrue(urls.contains("https://raw.githubusercontent.com/XIU2/Yuedu/master/shuyuan"))
        XCTAssertTrue(urls.contains("https://legado.aoaostar.com/sources/71e56d4f.json"))
    }

    func testLegadoAdapterExtractsStaticSearchURLFromJSRules() throws {
        let json = """
        [{
          "bookSourceName": "番茄小说2",
          "bookSourceUrl": "https://fqapi.example.com",
          "searchUrl": "@js:function getUrl(key) { return `https://api.example.com/detail?book_id={{key}}`; return `https://api.example.com/search/page/v/?passback={{(page-1)*50}}&query={{key}}$`; }",
          "ruleSearch": {
            "bookList": "$.data[*]",
            "name": "$.book_name",
            "author": "$.author",
            "bookUrl": "https://api.example.com/book/{{$.book_id}}"
          }
        }]
        """

        let source = try XCTUnwrap(LegadoSourceAdapter.decodeSources(from: Data(json.utf8)).first)

        XCTAssertEqual(source.rule.searchPath, "https://api.example.com/search/page/v/?passback={{(page-1)*50}}&query={{keyword}}")
        XCTAssertEqual(
            RuleTemplate.render(source.rule.searchPath, keyword: "剑来", page: 3),
            "https://api.example.com/search/page/v/?passback=100&query=%E5%89%91%E6%9D%A5"
        )
    }

    func testLegadoAdapterExtractsBaseURLRelativeSearchURLFromJSRules() throws {
        let json = """
        {
          "bookSourceName": "起点中文",
          "bookSourceUrl": "https://www.qidian.com",
          "searchUrl": "@js:url=baseUrl+\\"/so/{{key}}.html,{'method':'GET'}\\";result=url;",
          "ruleSearch": {
            "bookList": "class.res-book-item",
            "name": "class.book-info-title.0@tag.a.0@text",
            "author": "class.author@class.name.0@text",
            "bookUrl": "tag.a.0@href"
          }
        }
        """

        let source = try XCTUnwrap(LegadoSourceAdapter.decodeSources(from: Data(json.utf8)).first)

        XCTAssertEqual(source.rule.searchPath, "/so/{{keyword}}.html,{'method':'GET'}")
    }

    private func makeMinimalEPUB() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "epub-\(UUID().uuidString)", directoryHint: .isDirectory)
        let metaInf = root.appending(path: "META-INF", directoryHint: .isDirectory)
        let ops = root.appending(path: "OPS", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: metaInf, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ops, withIntermediateDirectories: true)
        try "application/epub+zip".write(to: root.appending(path: "mimetype"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """.write(to: metaInf.appending(path: "container.xml"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns:dc="http://purl.org/dc/elements/1.1/">
          <metadata><dc:title>测试 EPUB</dc:title><dc:creator>作者</dc:creator></metadata>
          <metadata><meta name="cover" content="cover"/></metadata>
          <manifest>
            <item id="c1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="cover" href="cover.jpg" media-type="image/jpeg" properties="cover-image"/>
          </manifest>
          <spine><itemref idref="c1"/></spine>
        </package>
        """.write(to: ops.appending(path: "content.opf"), atomically: true, encoding: .utf8)
        try """
        <html><body><nav epub:type="toc"><ol><li><a href="chapter1.xhtml">目录里的第一章</a></li></ol></nav></body></html>
        """.write(to: ops.appending(path: "nav.xhtml"), atomically: true, encoding: .utf8)
        try Data([0xff, 0xd8, 0xff, 0xd9]).write(to: ops.appending(path: "cover.jpg"))
        try """
        <html><head><title>第一章</title></head><body><h1>第一章</h1><p>正文内容</p></body></html>
        """.write(to: ops.appending(path: "chapter1.xhtml"), atomically: true, encoding: .utf8)

        let epubURL = FileManager.default.temporaryDirectory.appending(path: "minimal-\(UUID().uuidString).epub")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = root
        process.arguments = ["-0", "-q", "-r", epubURL.path, "."]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return epubURL
    }
}
