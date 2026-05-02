import SwiftUI
import UniformTypeIdentifiers

struct ShelfView: View {
    @EnvironmentObject private var store: AppStore
    @State private var statusFilter: ReadingStatus?
    @State private var searchText = ""
    @State private var isImporterPresented = false
    @State private var selectedBook: Book?

    private var filteredBooks: [Book] {
        store.books.filter { book in
            let matchesStatus = statusFilter == nil || book.status == statusFilter
            let matchesSearch = searchText.isEmpty
                || book.title.localizedCaseInsensitiveContains(searchText)
                || book.author.localizedCaseInsensitiveContains(searchText)
            return matchesStatus && matchesSearch
        }
    }

    private var filterOptions: [(ReadingStatus?, String)] {
        [(nil, "全部")] + ReadingStatus.allCases.map { (Optional($0), $0.title) }
    }

    var body: some View {
        NavigationStack {
            AppScreen {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // Header
                        HStack(alignment: .bottom) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("书架")
                                    .font(.system(size: 28, weight: .regular))
                                    .foregroundStyle(AppTheme.ink)
                                    .kerning(-0.3)
                                Text(store.books.isEmpty
                                     ? "导入文件或连接服务后开始"
                                     : "\(store.books.count) 本 · \(store.books.filter { $0.status == .reading }.count) 在读")
                                    .font(.subheadline)
                                    .foregroundStyle(AppTheme.mutedInk)
                            }
                            Spacer()
                            Button { isImporterPresented = true } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(AppTheme.mutedInk)
                                    .frame(width: 36, height: 36)
                                    .background(AppTheme.surface, in: Circle())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.top, 18)

                        // Filter
                        SegmentedPillBar(options: filterOptions, selection: $statusFilter)

                        // Search
                        PremiumSearchField(placeholder: "搜索书名或作者", text: $searchText)

                        // Full-text search hits
                        if !searchText.isEmpty && !store.librarySearchHits.isEmpty {
                            SearchHitSection(hits: Array(store.librarySearchHits.prefix(6)))
                        }

                        // Book list
                        if filteredBooks.isEmpty {
                            PremiumCard {
                                EmptyStateView(
                                    systemImage: "books.vertical",
                                    title: store.books.isEmpty ? "书架是空的" : "没有匹配书籍",
                                    subtitle: store.books.isEmpty
                                        ? "连接阅读服务或导入本地文件后，它会出现在这里。"
                                        : "换个关键词或筛选条件试试。"
                                )
                                .frame(minHeight: 340)
                            }
                        } else {
                            LazyVStack(spacing: 10) {
                                ForEach(filteredBooks) { book in
                                    ShelfBookCell(book: book) { selectedBook = book }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 32)
                }
            }
            .platformInlineNavigationTitle()
            .onChange(of: searchText) { _, v in store.searchLibrary(keyword: v) }
            .fileImporter(isPresented: $isImporterPresented,
                          allowedContentTypes: [.plainText, .epub],
                          allowsMultipleSelection: false) { handleImport($0) }
            .sheet(item: $selectedBook) { book in
                BookDetailView(book: book).environmentObject(store)
            }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        store.importLocalFile(url)
    }
}

// MARK: - Book cell

struct ShelfBookCell: View {
    var book: Book
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            PremiumCard {
                HStack(alignment: .top, spacing: 14) {
                    BookCoverView(book: book)
                        .frame(width: 62)

                    VStack(alignment: .leading, spacing: 0) {
                        Text(book.title)
                            .font(.headline.weight(.medium))
                            .foregroundStyle(AppTheme.ink)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(book.author)
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.mutedInk)
                            .lineLimit(1)
                            .padding(.top, 3)

                        Spacer(minLength: 8)

                        // Current chapter
                        if book.chapters.indices.contains(book.progress.chapterIndex) {
                            Text(book.chapters[book.progress.chapterIndex].title)
                                .font(.caption)
                                .foregroundStyle(AppTheme.ink.opacity(0.55))
                                .lineLimit(1)
                                .padding(.bottom, 8)
                        }

                        // Progress
                        HStack(spacing: 8) {
                            ProgressView(value: book.progress.percentage)
                                .tint(AppTheme.accent.opacity(0.7))
                                .frame(maxWidth: .infinity)
                                .scaleEffect(x: 1, y: 0.7, anchor: .center)

                            Text(book.progress.percentage
                                    .formatted(.percent.precision(.fractionLength(0))))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(AppTheme.mutedInk)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Search hits

private struct SearchHitSection: View {
    var hits: [LibrarySearchHit]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PremiumSectionLabel(title: "正文命中")
            PremiumCard {
                VStack(spacing: 0) {
                    ForEach(Array(hits.enumerated()), id: \.element.id) { idx, hit in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(hit.bookTitle)  ·  \(hit.chapterTitle)")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(AppTheme.ink)
                            Text(hit.snippet)
                                .font(.caption)
                                .foregroundStyle(AppTheme.mutedInk)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                        if idx < hits.count - 1 { RowDivider() }
                    }
                }
            }
        }
    }
}

// MARK: - Stats row (kept for use in other views)

struct ShelfStatsRow: View {
    var total: Int
    var reading: Int
    var downloaded: Int

    var body: some View {
        HStack(spacing: 10) {
            StatTile(title: "总藏书",  value: total.formatted(),      systemImage: "books.vertical.fill", tint: .brown)
            StatTile(title: "正在读",  value: reading.formatted(),    systemImage: "bookmark.fill",        tint: AppTheme.accent)
            StatTile(title: "已缓存",  value: downloaded.formatted(), systemImage: "externaldrive.fill",   tint: AppTheme.success)
        }
    }
}

// MARK: - UTType

private extension UTType {
    static var epub: UTType { UTType(filenameExtension: "epub") ?? .data }
}
