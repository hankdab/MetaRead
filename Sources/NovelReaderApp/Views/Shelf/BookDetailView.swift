import SwiftUI

struct BookDetailView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var showReader = false
    @State private var showDeleteConfirmation = false
    @State private var readerInitialChapter: Int?
    var book: Book

    private var displayedBook: Book {
        store.books.first(where: { $0.id == book.id }) ?? book
    }

    private var currentChapterTitle: String {
        let book = displayedBook
        guard book.chapters.indices.contains(book.progress.chapterIndex) else {
            return "未开始"
        }
        return book.chapters[book.progress.chapterIndex].title
    }

    var body: some View {
        let book = displayedBook
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    BookDetailHeader(book: book)

                    HStack(spacing: 12) {
                        StatTile(title: "章节", value: book.chapters.count.formatted(), systemImage: "list.bullet", tint: .blue)
                        StatTile(title: "进度", value: book.progress.percentage.formatted(.percent.precision(.fractionLength(0))), systemImage: "chart.line.uptrend.xyaxis", tint: .green)
                        StatTile(title: "来源", value: book.sourceName, systemImage: "tray.fill", tint: .indigo)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        SectionTitle(title: "当前阅读", subtitle: currentChapterTitle)
                        ProgressView(value: book.progress.percentage)
                        HStack {
                            Button {
                                readerInitialChapter = nil
                                showReader = true
                            } label: {
                                Label(book.status == .unread ? "开始阅读" : "继续阅读", systemImage: "book.fill")
                            }
                            .buttonStyle(.borderedProminent)

                            if let localURL = book.localURL {
                                Text(localURL.lastPathComponent)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(14)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))

                    CacheManagementPanel(book: book)
                        .environmentObject(store)

                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle(title: "目录", subtitle: "\(book.chapters.count) 章")
                        ForEach(book.chapters.prefix(12)) { chapter in
                            Button {
                                readerInitialChapter = chapter.index
                                showReader = true
                            } label: {
                                HStack {
                                    Text(chapter.title)
                                        .lineLimit(1)
                                    Spacer()
                                    if chapter.isDownloaded {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .font(.callout)
                            .padding(.vertical, 6)
                            Divider()
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 920, alignment: .leading)
            }
            .navigationTitle("书籍详情")
            .toolbar {
                ToolbarItemGroup {
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label("删除", systemImage: "trash")
                    }

                    Button {
                        dismiss()
                    } label: {
                        Label("关闭", systemImage: "xmark")
                    }
                }
            }
            .confirmationDialog("删除这本书？", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    store.deleteBook(book)
                    dismiss()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("这会从书架移除该书和相关下载任务。")
            }
            #if os(macOS)
            .sheet(isPresented: $showReader) {
                ReaderView(book: book, initialChapterIndex: readerInitialChapter)
                    .environmentObject(store)
                    .frame(minWidth: 800, idealWidth: 1100, minHeight: 650, idealHeight: 850)
            }
            #else
            .fullScreenCover(isPresented: $showReader) {
                ReaderView(book: book, initialChapterIndex: readerInitialChapter)
                    .environmentObject(store)
            }
            #endif
        }
    }
}

struct CacheManagementPanel: View {
    @EnvironmentObject private var store: AppStore
    @State private var showClearCacheConfirmation = false
    var book: Book

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "缓存", subtitle: cacheSubtitle)
            HStack(spacing: 10) {
                StatusBadge(title: book.localURL == nil ? "无本地文件" : "本地已缓存", color: book.localURL == nil ? .secondary : .green)
                StatusBadge(title: downloadedChapterText, color: .blue)
                if followingCacheableCount > 0 {
                    StatusBadge(title: "待缓存 \(followingCacheableCount) 章", color: .orange)
                }
                Spacer()
                if book.localURL != nil {
                    Button(role: .destructive) {
                        showClearCacheConfirmation = true
                    } label: {
                        Label("清除", systemImage: "trash")
                    }
                } else if book.format == .web {
                    Label("可从书源重新下载", systemImage: "arrow.down.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if shouldShowChapterCacheActions {
                Divider()
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        chapterCacheButtons
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        chapterCacheButtons
                    }
                }
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .confirmationDialog("清除缓存？", isPresented: $showClearCacheConfirmation, titleVisibility: .visible) {
            Button("清除缓存", role: .destructive) {
                store.clearLocalCache(for: book)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会移除本地缓存文件，书架记录会保留。")
        }
    }

    private var cacheSubtitle: String {
        if let size = store.cacheSize(for: book) {
            return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        }
        if book.format == .web, !book.chapters.isEmpty {
            return followingCacheableCount == 0 ? "后续章节已缓存" : "可缓存到本机离线阅读"
        }
        return "未找到本地文件"
    }

    private var downloadedChapterText: String {
        "\(book.chapters.filter(\.isDownloaded).count)/\(book.chapters.count) 章"
    }

    private var followingCacheableCount: Int {
        let startIndex = min(book.progress.chapterIndex + 1, book.chapters.count)
        return book.chapters.dropFirst(startIndex).filter { !$0.isDownloaded }.count
    }

    private var shouldShowChapterCacheActions: Bool {
        guard book.format == .web, !book.chapters.isEmpty else { return false }
        return book.isReaderServerBacked == true || book.chapters.contains { $0.url != nil }
    }

    @ViewBuilder
    private var chapterCacheButtons: some View {
        Button {
            store.cacheFollowingChapters(for: book, limit: 50)
        } label: {
            Label("缓存后续 50 章", systemImage: "arrow.down.to.line.compact")
        }
        .buttonStyle(.borderedProminent)
        .disabled(followingCacheableCount == 0)

        Button {
            store.cacheFollowingChapters(for: book, limit: nil)
        } label: {
            Label("缓存后续全部", systemImage: "tray.and.arrow.down.fill")
        }
        .buttonStyle(.bordered)
        .disabled(followingCacheableCount == 0)
    }
}

struct BookDetailHeader: View {
    var book: Book

    var body: some View {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone {
            VStack(alignment: .leading, spacing: 16) {
                BookCoverView(book: book)
                    .frame(width: 150)
                    .frame(maxWidth: .infinity)
                metadata
            }
        } else {
            horizontalHeader
        }
        #else
        horizontalHeader
        #endif
    }

    private var horizontalHeader: some View {
        HStack(alignment: .top, spacing: 18) {
            BookCoverView(book: book)
                .frame(width: 142)
            metadata
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                FormatBadge(format: book.format)
                StatusBadge(title: book.status.title, color: book.status.tint)
            }
            Text(book.title)
                .font(.largeTitle.weight(.semibold))
                .lineLimit(3)
                .minimumScaleFactor(0.72)
            Text(book.author)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(book.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(4)
        }
    }
}
