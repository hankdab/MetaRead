import XCTest
@testable import NovelReaderApp

final class LegadoAdapterTests: XCTestCase {
    func testConvertsSingleLegadoSource() throws {
        let json = """
        {
          "bookSourceName": "中华典藏",
          "bookSourceUrl": "https://www.zhonghuadiancang.com",
          "enabled": true,
          "searchUrl": "/e/search/index.php,{\\"method\\":\\"post\\",\\"body\\":\\"keyboard={{key}}\\"}",
          "ruleSearch": {
            "bookList": "@tbody@tr",
            "name": "@a.0@text",
            "author": "@a.1@text",
            "bookUrl": "@a.0@href"
          },
          "ruleToc": {
            "chapterList": "#booklist@li",
            "chapterName": "@a@text",
            "chapterUrl": "@a@href"
          },
          "ruleContent": {
            "content": "#content@p@text",
            "sourceRegex": "广告"
          }
        }
        """

        let sources = try LegadoSourceAdapter.decodeSources(from: Data(json.utf8))

        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources[0].name, "中华典藏")
        XCTAssertEqual(sources[0].baseURL.absoluteString, "https://www.zhonghuadiancang.com")
        XCTAssertEqual(sources[0].rule.searchPath, #"/e/search/index.php,{"method":"post","body":"keyboard={{keyword}}"}"#)
        XCTAssertEqual(sources[0].rule.tocListSelector, "#booklist@li")
        XCTAssertEqual(sources[0].rule.replacements.first?.pattern, "广告")
    }

    func testConvertsLegadoSourceArray() throws {
        let json = """
        [
          {
            "bookSourceName": "源一",
            "bookSourceUrl": "https://one.example",
            "ruleSearch": {"bookList": ".result", "name": ".title@text", "author": ".author@text", "bookUrl": ".title@href"},
            "ruleToc": {"chapterList": ".toc a", "chapterName": "@text", "chapterUrl": "@href"},
            "ruleContent": {"content": "#content@html"}
          },
          {
            "bookSourceName": "源二",
            "bookSourceUrl": "https://two.example",
            "enabled": false
          }
        ]
        """

        let sources = try LegadoSourceAdapter.decodeSources(from: Data(json.utf8))

        XCTAssertEqual(sources.map(\.name), ["源一", "源二"])
        XCTAssertTrue(sources[0].isEnabled)
        XCTAssertFalse(sources[1].isEnabled)
    }

    func testConvertsDirectTocURLForAPISource() throws {
        let json = """
        {
          "bookSourceName": "酷我小说",
          "bookSourceUrl": "http://appi.kuwo.cn##",
          "searchUrl": "/novels/api/book/search?keyword={{key}}&pi={{page}}&ps=30",
          "ruleSearch": {
            "bookList": "$.data",
            "name": "$.title",
            "author": "$.author_name",
            "bookUrl": "/novels/api/book/{{$.book_id}}"
          },
          "ruleBookInfo": {
            "tocUrl": "/novels/api/book/{{$.book_id}}/chapters?paging=0"
          },
          "ruleToc": {
            "chapterList": "$.data",
            "chapterName": "$.chapter_title",
            "chapterUrl": "/novels/api/book/{{$.book_id}}/chapters/{{$.chapter_id}}"
          },
          "ruleContent": {"content": "$.data.content"}
        }
        """

        let sources = try LegadoSourceAdapter.decodeSources(from: Data(json.utf8))

        XCTAssertEqual(sources[0].baseURL.absoluteString, "http://appi.kuwo.cn")
        XCTAssertEqual(sources[0].rule.bookURLSelector, "/novels/api/book/{{$.book_id}}/chapters?paging=0")
    }
}
