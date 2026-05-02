import Foundation

enum BuiltInBookSources {
    static let all: [BookSource] = [
        gutenbergAll,
        gutenbergChinese,
        gutenbergEnglish,
        kuwoNovel
    ]

    private static let gutenbergRule = SourceRule(
        searchPath: "/books/?search={{keyword}}",
        resultListSelector: "$.results[*]",
        titleSelector: "$.title",
        authorSelector: "$.authors[0].name || $.translators[0].name",
        bookURLSelector: "$.formats['text/plain; charset=utf-8'] || $.formats['text/plain; charset=us-ascii']",
        tocListSelector: "$directText",
        chapterTitleSelector: "@text",
        chapterURLSelector: "@href",
        contentSelector: "@text",
        replacements: []
    )

    private static let gutenbergAll = BookSource(
        name: "古登堡公版书库",
        baseURL: URL(string: "https://gutendex.com")!,
        isEnabled: true,
        rule: gutenbergRule
    )

    private static let gutenbergChinese = BookSource(
        name: "古登堡中文公版",
        baseURL: URL(string: "https://gutendex.com")!,
        isEnabled: true,
        rule: SourceRule(
            searchPath: "/books/?languages=zh&search={{keyword}}",
            resultListSelector: gutenbergRule.resultListSelector,
            titleSelector: gutenbergRule.titleSelector,
            authorSelector: gutenbergRule.authorSelector,
            bookURLSelector: gutenbergRule.bookURLSelector,
            tocListSelector: gutenbergRule.tocListSelector,
            chapterTitleSelector: gutenbergRule.chapterTitleSelector,
            chapterURLSelector: gutenbergRule.chapterURLSelector,
            contentSelector: gutenbergRule.contentSelector,
            replacements: []
        )
    )

    private static let gutenbergEnglish = BookSource(
        name: "古登堡英文公版",
        baseURL: URL(string: "https://gutendex.com")!,
        isEnabled: true,
        rule: SourceRule(
            searchPath: "/books/?languages=en&search={{keyword}}",
            resultListSelector: gutenbergRule.resultListSelector,
            titleSelector: gutenbergRule.titleSelector,
            authorSelector: gutenbergRule.authorSelector,
            bookURLSelector: gutenbergRule.bookURLSelector,
            tocListSelector: gutenbergRule.tocListSelector,
            chapterTitleSelector: gutenbergRule.chapterTitleSelector,
            chapterURLSelector: gutenbergRule.chapterURLSelector,
            contentSelector: gutenbergRule.contentSelector,
            replacements: []
        )
    )

    private static let kuwoNovel = BookSource(
        name: "酷我小说",
        baseURL: URL(string: "http://appi.kuwo.cn")!,
        isEnabled: true,
        rule: SourceRule(
            searchPath: "/novels/api/book/search?keyword={{keyword}}&pi={{page}}&ps=30",
            resultListSelector: "$.data",
            titleSelector: "$.title",
            authorSelector: "$.author_name",
            bookURLSelector: "/novels/api/book/{{$.book_id}}/chapters?paging=0",
            tocListSelector: "$.data",
            chapterTitleSelector: "$.chapter_title##正文卷.|正文.|VIP卷.|默认卷.|卷_|VIP章节.|免费章节.|章节目录.|最新章节.|[\\(（【].*?[求更票谢乐发订合补加架字修Kk].*?[】）\\)]",
            chapterURLSelector: "/novels/api/book/{{$.book_id}}/chapters/{{$.chapter_id}}",
            contentSelector: "$.data.content",
            replacements: []
        )
    )
}

struct BookSourcePack: Identifiable, Hashable, Sendable {
    var id: String { url.absoluteString }
    var name: String
    var url: URL
    var detail: String
}

enum RemoteBookSourcePacks {
    static let all: [BookSourcePack] = [
        BookSourcePack(
            name: "XIU2/Yuedu",
            url: URL(string: "https://raw.githubusercontent.com/XIU2/Yuedu/master/shuyuan")!,
            detail: "GitHub · 26 个"
        ),
        BookSourcePack(
            name: "AOAOSTAR · XIU2精品",
            url: URL(string: "https://legado.aoaostar.com/sources/71e56d4f.json")!,
            detail: "Reader 推荐 · 26 个"
        ),
        BookSourcePack(
            name: "AOAOSTAR · 破冰",
            url: URL(string: "https://legado.aoaostar.com/sources/4dc410d1.json")!,
            detail: "Reader 推荐 · 128 个"
        ),
        BookSourcePack(
            name: "AOAOSTAR · 关耳女频",
            url: URL(string: "https://legado.aoaostar.com/sources/e3e5d620.json")!,
            detail: "Reader 推荐 · 86 个"
        ),
        BookSourcePack(
            name: "AOAOSTAR · 全量书源",
            url: URL(string: "https://legado.aoaostar.com/sources/b778fe6b.json")!,
            detail: "Reader 推荐 · 3911 个"
        )
    ]
}
