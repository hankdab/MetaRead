import SwiftUI
import CoreText

struct ReaderView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var book: Book
    @State private var chapterIndex: Int
    @State private var showCatalog = false
    @State private var showStylePanel = false
    @State private var loadingChapterIDs: Set<UUID> = []
    @State private var contentLoadError: String?
    #if os(macOS)
    @State private var catalogVisibility: NavigationSplitViewVisibility = .detailOnly
    #endif

    init(book: Book, initialChapterIndex: Int? = nil) {
        _book = State(initialValue: book)
        let requestedIndex = initialChapterIndex ?? book.progress.chapterIndex
        _chapterIndex = State(initialValue: min(requestedIndex, max(book.chapters.count - 1, 0)))
    }

    private var displayedBook: Book {
        store.books.first(where: { $0.id == book.id }) ?? book
    }

    private var chapter: Chapter? {
        let book = displayedBook
        guard book.chapters.indices.contains(chapterIndex) else { return nil }
        return book.chapters[chapterIndex]
    }

    var body: some View {
        #if os(iOS)
        NavigationStack {
            readerDetail
        }
        .sheet(isPresented: $showCatalog) {
            NavigationStack {
                catalogList
                    .navigationTitle("目录")
            }
        }
        .onChange(of: chapterIndex) { _, newValue in
            updateReadingProgress(newValue)
        }
        .sheet(isPresented: $showStylePanel, onDismiss: store.save) {
            ReaderStylePanel()
                .environmentObject(store)
        }
        #else
        NavigationSplitView(columnVisibility: $catalogVisibility) {
            catalogList
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            readerDetail
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: chapterIndex) { _, newValue in
            updateReadingProgress(newValue)
        }
        .sheet(isPresented: $showStylePanel, onDismiss: store.save) {
            ReaderStylePanel()
                .environmentObject(store)
        }
        #endif
    }

    private var catalogList: some View {
        let book = displayedBook
        return List(book.chapters) { chapter in
            Button {
                chapterIndex = chapter.index
                showCatalog = false
            } label: {
                Text(chapter.title)
                    .foregroundStyle(chapterIndex == chapter.index ? AppTheme.accent : AppTheme.ink)
            }
        }
        .navigationTitle("目录")
    }

    private var readerDetail: some View {
        let book = displayedBook
        return ZStack {
            Color(hex: store.readerTheme.backgroundHex)
                .ignoresSafeArea()

            if let chapter {
                ReaderChapterPage(
                    book: book,
                    chapter: chapter,
                    chapterIndex: chapterIndex,
                    readingPercentage: readingPercentage,
                    isLoadingContent: loadingChapterIDs.contains(chapter.id),
                    contentLoadError: contentLoadError,
                    retryAction: { Task { await loadVisibleChapterIfNeeded() } }
                )
                .environmentObject(store)
            } else {
                EmptyStateView(systemImage: "text.book.closed", title: "暂无章节", subtitle: "这本书还没有下载目录或正文。")
            }
        }
        .safeAreaInset(edge: .bottom) {
            ReaderBottomBar(
                readingPercentage: readingPercentage,
                canMoveBack: chapterIndex > 0,
                canMoveForward: chapterIndex < book.chapters.count - 1,
                catalogAction: {
                    #if os(macOS)
                    withAnimation {
                        catalogVisibility = catalogVisibility == .detailOnly ? .all : .detailOnly
                    }
                    #else
                    showCatalog = true
                    #endif
                },
                previousAction: { moveChapter(-1) },
                nextAction: { moveChapter(1) },
                scrubAction: { value in
                    let maxIndex = max(book.chapters.count - 1, 0)
                    guard maxIndex > 0 else { return }
                    let targetIndex = min(max(Int((value * Double(maxIndex)).rounded()), 0), maxIndex)
                    guard targetIndex != chapterIndex else { return }
                    chapterIndex = targetIndex
                },
                styleAction: { showStylePanel = true }
            )
            .environmentObject(store)
        }
        .navigationTitle("")
        .platformInlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    dismiss()
                } label: {
                    Label("关闭", systemImage: "xmark")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                HStack {
                    Button {
                        store.cacheFollowingChapters(for: book, limit: 50)
                    } label: {
                        Label("缓存后续", systemImage: "arrow.down.to.line.compact")
                    }
                    .disabled(!canCacheFollowingChapters)

                    Button {
                        showStylePanel = true
                    } label: {
                        Label("样式", systemImage: "textformat.size")
                    }
                }
            }
        }
        .task(id: chapter?.id) {
            await loadVisibleChapterIfNeeded()
        }
    }

    private func moveChapter(_ offset: Int) {
        let book = displayedBook
        let next = chapterIndex + offset
        guard book.chapters.indices.contains(next) else { return }
        chapterIndex = next
    }

    private func updateReadingProgress(_ newValue: Int) {
        let book = displayedBook
        let denominator = max(book.chapters.count - 1, 1)
        let percentage = Double(newValue) / Double(denominator)
        store.updateProgress(bookID: book.id, chapterIndex: newValue, percentage: percentage)
    }

    @MainActor
    private func loadVisibleChapterIfNeeded() async {
        let book = displayedBook
        guard book.chapters.indices.contains(chapterIndex) else { return }
        let chapter = book.chapters[chapterIndex]
        guard chapter.localText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              store.canLoadReaderServerContent(for: book) else {
            contentLoadError = nil
            return
        }

        loadingChapterIDs.insert(chapter.id)
        contentLoadError = nil
        let didLoad = await store.loadChapterContentIfNeeded(bookID: book.id, chapterIndex: chapterIndex)
        loadingChapterIDs.remove(chapter.id)
        if !didLoad {
            contentLoadError = store.activityMessage
        }
    }

    private var readingPercentage: Double {
        let book = displayedBook
        guard book.chapters.count > 1 else { return book.progress.percentage }
        return Double(chapterIndex) / Double(max(book.chapters.count - 1, 1))
    }

    private var canCacheFollowingChapters: Bool {
        let book = displayedBook
        guard book.format == .web,
              book.isReaderServerBacked == true || book.chapters.contains(where: { $0.url != nil }) else {
            return false
        }
        let startIndex = min(chapterIndex + 1, book.chapters.count)
        return book.chapters.dropFirst(startIndex).contains { !$0.isDownloaded }
    }
}

private struct ReaderChapterPage: View {
    @EnvironmentObject private var store: AppStore
    var book: Book
    var chapter: Chapter
    var chapterIndex: Int
    var readingPercentage: Double
    var isLoadingContent: Bool
    var contentLoadError: String?
    var retryAction: () -> Void
    private let topAnchorID = "reader-chapter-top"

    private var isEmpty: Bool {
        chapter.localText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: store.readerTheme.paragraphSpacing) {
                    Color.clear.frame(height: 0).id(topAnchorID)

                    ReaderChapterHeader(book: book, chapterIndex: chapterIndex)

                    Text(chapter.title)
                        .font(.system(size: 26, weight: .semibold, design: .serif))
                        .padding(.bottom, 16)

                    // Content states — mutually exclusive
                    if isLoadingContent && isEmpty {
                        ReaderChapterLoadingView(title: "正在读取正文…")
                    } else if isEmpty {
                        ReaderChapterEmptyState(
                            error: contentLoadError,
                            isReaderServerBacked: book.isReaderServerBacked == true,
                            retryAction: retryAction
                        )
                    } else {
                        ReaderBodyText(text: chapter.localText)
                            .environmentObject(store)
                    }

                    ReaderChapterFooter(book: book, readingPercentage: readingPercentage)
                        .environmentObject(store)
                }
                .foregroundStyle(Color(hex: store.readerTheme.foregroundHex))
                #if os(macOS)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 56)
                #else
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, 28)
                #endif
                .padding(.top, 34)
                .padding(.bottom, 132)
            }
            .onChange(of: chapterIndex) { _, _ in
                DispatchQueue.main.async { proxy.scrollTo(topAnchorID, anchor: .top) }
            }
        }
    }
}

private struct ReaderChapterLoadingView: View {
    var title: String

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(title)
                .font(.body.weight(.medium))
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 24)
    }
}

private struct ReaderChapterEmptyState: View {
    var error: String?
    var isReaderServerBacked: Bool
    var retryAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: error != nil ? "exclamationmark.triangle" : "arrow.down.circle")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary.opacity(0.6))
                .padding(.bottom, 4)

            if let error {
                Text("正文读取失败")
                    .font(.headline.weight(.medium))
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if isReaderServerBacked {
                    Text("在家里网络时可正常读取未缓存章节；离家时请提前缓存或使用 VPN。")
                        .font(.caption)
                        .foregroundStyle(.secondary.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
                Button(action: retryAction) {
                    Label("重新读取", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 6)
            } else {
                Text("章节尚未缓存")
                    .font(.headline.weight(.medium))
                Text("这一章还没有下载到本机。回到家里网络后可点击右上角下载按钮缓存后续章节。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 32)
    }
}

private struct ReaderChapterHeader: View {
    var book: Book
    var chapterIndex: Int

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                Text(book.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(book.author)
                    .font(.caption2)
                    .foregroundStyle(.secondary.opacity(0.8))
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            StatusBadge(title: "\(chapterIndex + 1)/\(max(book.chapters.count, 1))", color: .secondary)
        }
        .padding(.bottom, 16)
    }
}

private struct ReaderBottomBar: View {
    @EnvironmentObject private var store: AppStore
    var readingPercentage: Double
    var canMoveBack: Bool
    var canMoveForward: Bool
    var catalogAction: () -> Void
    var previousAction: () -> Void
    var nextAction: () -> Void
    var scrubAction: (Double) -> Void
    var styleAction: () -> Void
    @State private var scrubPercentage = 0.0
    @State private var isScrubbing = false

    private var displayedPercentage: Double {
        isScrubbing ? scrubPercentage : readingPercentage
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button(action: previousAction) {
                    Image(systemName: "chevron.left")
                        .frame(width: 32, height: 32)
                }
                .disabled(!canMoveBack)

                Slider(
                    value: Binding(
                        get: { displayedPercentage },
                        set: { scrubPercentage = $0 }
                    ),
                    in: 0...1,
                    onEditingChanged: { editing in
                        if editing {
                            scrubPercentage = readingPercentage
                            isScrubbing = true
                        } else {
                            isScrubbing = false
                            scrubAction(scrubPercentage)
                        }
                    }
                )
                    .tint(Color(hex: store.readerTheme.foregroundHex).opacity(0.72))

                Button(action: nextAction) {
                    Image(systemName: "chevron.right")
                        .frame(width: 32, height: 32)
                }
                .disabled(!canMoveForward)

                Text(displayedPercentage.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }

            HStack(spacing: 8) {
                readerToolButton(title: "目录", icon: "list.bullet", action: catalogAction)
                readerToolButton(title: "亮度", icon: "sun.max", action: {})
                readerToolButton(title: "Aa", icon: "textformat.size", action: styleAction)
                readerToolButton(title: "背景", icon: "circle.lefthalf.filled", action: styleAction)
                readerToolButton(title: "更多", icon: "ellipsis", action: styleAction)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(.ultraThinMaterial)
        .onAppear {
            scrubPercentage = readingPercentage
        }
        .onChange(of: readingPercentage) { _, newValue in
            if !isScrubbing {
                scrubPercentage = newValue
            }
        }
    }

    private func readerToolButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                Text(title)
                    .font(.caption2.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 46)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color(hex: store.readerTheme.foregroundHex).opacity(0.82))
        .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct ReaderChapterFooter: View {
    @EnvironmentObject private var store: AppStore
    var book: Book
    var readingPercentage: Double

    var body: some View {
        Divider()
            .padding(.top, 22)
        HStack {
            Text(book.title)
                .lineLimit(1)
            Spacer()
            Text(readingPercentage.formatted(.percent.precision(.fractionLength(0))))
                .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        ProgressView(value: readingPercentage)
            .tint(Color(hex: store.readerTheme.foregroundHex).opacity(0.75))
    }
}

struct ReaderBodyText: View {
    @EnvironmentObject private var store: AppStore
    var text: String

    var body: some View {
        ReaderTextColumn(text: text)
    }
}

private struct ReaderTextColumn: View {
    @EnvironmentObject private var store: AppStore
    var text: String

    var body: some View {
        let renderedParagraphs = paragraphs
        LazyVStack(alignment: .leading, spacing: store.readerTheme.paragraphSpacing) {
            ForEach(Array(renderedParagraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(indentedParagraph(paragraph))
                    .readerTextStyle(theme: store.readerTheme)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var paragraphs: [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func indentedParagraph(_ paragraph: String) -> String {
        let indent = max(0, store.readerTheme.effectiveFirstLineIndent)
        guard indent > 0 else { return paragraph }
        let fullWidthSpaces = Int(indent.rounded(.down))
        let hasHalfSpace = indent - Double(fullWidthSpaces) >= 0.5
        return String(repeating: "\u{3000}", count: fullWidthSpaces)
            + (hasHalfSpace ? " " : "")
            + paragraph
    }
}

private extension Text {
    func readerTextStyle(theme: ReaderTheme) -> some View {
        let fontWeight: Font.Weight = theme.isBold ? .semibold : (theme.fontDesign == .cute ? .medium : .regular)
        let tracking = theme.fontDesign == .cute ? max(theme.effectiveCharacterSpacing, 0.4) : theme.effectiveCharacterSpacing
        let resolvedFont: Font
        if let customName = theme.customFontName, !customName.isEmpty {
            resolvedFont = .custom(customName, size: theme.fontSize)
        } else {
            resolvedFont = .system(size: theme.fontSize, weight: fontWeight, design: theme.fontDesign.swiftUIDesign)
        }
        return font(resolvedFont)
            .tracking(tracking)
            .lineSpacing(theme.lineSpacing)
    }
}

struct ReaderStylePanel: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    private func fontDisplayName(_ postScriptName: String) -> String {
        CTFontCopyFullName(CTFontCreateWithName(postScriptName as CFString, 12, nil)) as String
    }

    private let themes: [(name: String, foreground: String, background: String)] = [
        ("纸页", "#2A2723", "#F5EFE3"),
        ("清晨", "#1F2A2E", "#EEF5F1"),
        ("夜读", "#D8D2C4", "#1B1D1F"),
        ("墨屏", "#111111", "#F7F7F7")
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("排版") {
                    NavigationLink {
                        FontPickerView()
                            .environmentObject(store)
                    } label: {
                        HStack {
                            Text("字体")
                            Spacer()
                            Text(store.readerTheme.customFontName.map { fontDisplayName($0) } ?? store.readerTheme.fontDesign.title)
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack {
                        Text("字号")
                        Slider(value: $store.readerTheme.fontSize, in: 14...32, step: 1)
                        Text(Int(store.readerTheme.fontSize).formatted())
                            .monospacedDigit()
                    }
                    HStack {
                        Text("行距")
                        Slider(value: $store.readerTheme.lineSpacing, in: 2...20, step: 1)
                        Text(Int(store.readerTheme.lineSpacing).formatted())
                            .monospacedDigit()
                    }
                    HStack {
                        Text("字距")
                        Slider(value: $store.readerTheme.effectiveCharacterSpacing, in: 0...4, step: 0.5)
                        Text(store.readerTheme.effectiveCharacterSpacing.formatted(.number.precision(.fractionLength(1))))
                            .monospacedDigit()
                    }
                    HStack {
                        Text("首行")
                        Slider(value: $store.readerTheme.effectiveFirstLineIndent, in: 0...4, step: 0.5)
                        Text("\(store.readerTheme.effectiveFirstLineIndent.formatted(.number.precision(.fractionLength(1))))字")
                            .monospacedDigit()
                    }
                    HStack {
                        Text("段距")
                        Slider(value: $store.readerTheme.paragraphSpacing, in: 4...28, step: 1)
                        Text(Int(store.readerTheme.paragraphSpacing).formatted())
                            .monospacedDigit()
                    }
                    Toggle("加粗正文", isOn: $store.readerTheme.isBold)
                    Button {
                        store.readerTheme.fontSize = ReaderTheme.classic.fontSize
                        store.readerTheme.lineSpacing = ReaderTheme.classic.lineSpacing
                        store.readerTheme.paragraphSpacing = ReaderTheme.classic.paragraphSpacing
                        store.readerTheme.effectiveCharacterSpacing = ReaderTheme.classic.effectiveCharacterSpacing
                        store.readerTheme.effectiveFirstLineIndent = ReaderTheme.classic.effectiveFirstLineIndent
                        store.readerTheme.fontDesign = ReaderTheme.classic.fontDesign
                        store.readerTheme.isBold = ReaderTheme.classic.isBold
                    } label: {
                        Label("恢复默认排版", systemImage: "arrow.counterclockwise")
                    }
                }

                Section("主题") {
                    HStack(spacing: 12) {
                        ForEach(themes, id: \.name) { theme in
                            Button {
                                store.readerTheme.name = theme.name
                                store.readerTheme.foregroundHex = theme.foreground
                                store.readerTheme.backgroundHex = theme.background
                            } label: {
                                VStack(spacing: 8) {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color(hex: theme.background))
                                        .overlay {
                                            Text("Aa")
                                                .font(.headline)
                                                .foregroundStyle(Color(hex: theme.foreground))
                                        }
                                        .frame(width: 58, height: 44)
                                    Text(theme.name)
                                        .font(.caption)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .navigationTitle("阅读样式")
            .toolbar {
                Button("完成") {
                    store.save()
                    dismiss()
                }
            }
            #if os(macOS)
            .frame(width: 460, height: 430)
            #endif
        }
    }
}
