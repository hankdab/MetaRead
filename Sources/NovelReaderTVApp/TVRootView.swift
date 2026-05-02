import SwiftUI

private enum TVPalette {
    static let background = Color(red: 0.055, green: 0.052, blue: 0.046)
    static let panel = Color(red: 0.13, green: 0.12, blue: 0.105)
    static let panel2 = Color(red: 0.19, green: 0.17, blue: 0.14)
    static let ink = Color(red: 0.96, green: 0.93, blue: 0.86)
    static let muted = Color(red: 0.72, green: 0.67, blue: 0.58)
    static let accent = Color(red: 0.88, green: 0.64, blue: 0.29)
    static let danger = Color(red: 0.96, green: 0.33, blue: 0.28)
}

@MainActor
final class TVShelfViewModel: ObservableObject {
    @Published var books: [TVShelfBook] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var serverAddress: String {
        didSet {
            UserDefaults.standard.set(serverAddress, forKey: Self.serverAddressKey)
        }
    }

    private static let serverAddressKey = "tv.reader.server.address"
    private static let defaultServerAddress = "http://192.168.31.205:4396/"

    init() {
        serverAddress = UserDefaults.standard.string(forKey: Self.serverAddressKey) ?? Self.defaultServerAddress
    }

    var client: ReaderServerClient {
        get throws { try ReaderServerClient(serverAddress: serverAddress) }
    }

    func loadShelf() async {
        isLoading = true
        errorMessage = nil
        do {
            books = try await client.fetchShelf()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

struct TVRootView: View {
    @StateObject private var viewModel = TVShelfViewModel()
    @State private var isShowingServerSettings = false

    var body: some View {
        NavigationStack {
            ZStack {
                TVPalette.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 40) {
                        hero

                        HStack(spacing: 20) {
                            Button {
                                Task { await viewModel.loadShelf() }
                            } label: {
                                Label("刷新书架", systemImage: "arrow.clockwise")
                            }

                            Button {
                                isShowingServerSettings = true
                            } label: {
                                Label("服务器", systemImage: "server.rack")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(TVPalette.accent)

                        if viewModel.isLoading {
                            loadingState
                        } else if let errorMessage = viewModel.errorMessage {
                            TVErrorState(message: errorMessage) {
                                Task { await viewModel.loadShelf() }
                            }
                        } else if viewModel.books.isEmpty {
                            TVEmptyState()
                        } else {
                            shelfGrid
                        }
                    }
                    .padding(.horizontal, 72)
                    .padding(.vertical, 56)
                }
            }
            .navigationTitle("")
            .sheet(isPresented: $isShowingServerSettings) {
                TVServerSettingsView(serverAddress: $viewModel.serverAddress) {
                    Task { await viewModel.loadShelf() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            if viewModel.books.isEmpty {
                await viewModel.loadShelf()
            }
        }
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 44) {
            Image("Image2")
                .resizable()
                .scaledToFill()
                .frame(width: 300, height: 390)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(.white.opacity(0.16), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.42), radius: 30, y: 22)

            VStack(alignment: .leading, spacing: 18) {
                Text("元阅")
                    .font(.system(size: 66, weight: .semibold, design: .serif))
                    .foregroundStyle(TVPalette.ink)

                Text("连接家中阅读服务器，拿起遥控器就能继续读。")
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(TVPalette.muted)
                    .lineLimit(2)

                Text(viewModel.serverAddress)
                    .font(.system(size: 22, weight: .medium, design: .monospaced))
                    .foregroundStyle(TVPalette.accent)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
    }

    private var loadingState: some View {
        VStack(alignment: .leading, spacing: 18) {
            ProgressView(value: 0.64)
                .progressViewStyle(.linear)
                .tint(TVPalette.accent)
                .frame(maxWidth: 680)
            Text("正在同步书架")
                .font(.title2.weight(.medium))
                .foregroundStyle(TVPalette.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 40)
    }

    private var shelfGrid: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("书架")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(TVPalette.ink)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 240, maximum: 260), spacing: 30)],
                alignment: .leading,
                spacing: 36
            ) {
                ForEach(viewModel.books) { book in
                    NavigationLink {
                        TVBookDetailView(book: book, client: try? viewModel.client)
                    } label: {
                        TVBookCard(book: book, baseURL: (try? viewModel.client.baseURL) ?? URL(string: "http://192.168.31.205:4396/")!)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct TVBookCard: View {
    let book: TVShelfBook
    let baseURL: URL
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            cover
                .frame(width: 220, height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isFocused ? TVPalette.accent : .white.opacity(0.13), lineWidth: isFocused ? 4 : 1)
                )
                .shadow(color: .black.opacity(isFocused ? 0.48 : 0.26), radius: isFocused ? 24 : 14, y: isFocused ? 18 : 10)

            VStack(alignment: .leading, spacing: 7) {
                Text(book.name)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(TVPalette.ink)
                    .lineLimit(2)
                Text(book.displayAuthor)
                    .font(.system(size: 19))
                    .foregroundStyle(TVPalette.muted)
                    .lineLimit(1)
                Text(book.progressTitle)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(TVPalette.accent)
                    .lineLimit(1)
            }
            .frame(width: 220, alignment: .leading)
        }
        .scaleEffect(isFocused ? 1.065 : 1)
        .animation(.easeOut(duration: 0.16), value: isFocused)
    }

    @ViewBuilder
    private var cover: some View {
        if let url = book.resolvedCoverURL(baseURL: baseURL) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    TVCoverPlaceholder(title: book.name)
                        .overlay { ProgressView().tint(TVPalette.accent) }
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                case .failure:
                    TVCoverPlaceholder(title: book.name)
                @unknown default:
                    TVCoverPlaceholder(title: book.name)
                }
            }
        } else {
            TVCoverPlaceholder(title: book.name)
        }
    }
}

private struct TVCoverPlaceholder: View {
    let title: String

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [TVPalette.panel2, TVPalette.panel],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Text(title)
                .font(.system(size: 28, weight: .semibold, design: .serif))
                .foregroundStyle(TVPalette.ink)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(22)
        }
    }
}

private struct TVErrorState: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(TVPalette.danger)
            Button("重试", action: retry)
                .buttonStyle(.borderedProminent)
                .tint(TVPalette.accent)
        }
        .padding(34)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TVPalette.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct TVEmptyState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("书架是空的")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(TVPalette.ink)
            Text("先在阅读服务器里把书加入书架，再回到这里刷新。")
                .font(.system(size: 24))
                .foregroundStyle(TVPalette.muted)
        }
        .padding(34)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TVPalette.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct TVServerSettingsView: View {
    @Binding var serverAddress: String
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("阅读服务器") {
                    TextField("http://192.168.31.205:4396/", text: $serverAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle("服务器")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        onSave()
                        dismiss()
                    }
                }
            }
        }
    }
}

@MainActor
final class TVBookDetailViewModel: ObservableObject {
    @Published var chapters: [TVChapter] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    let book: TVShelfBook
    let client: ReaderServerClient?

    init(book: TVShelfBook, client: ReaderServerClient?) {
        self.book = book
        self.client = client
    }

    func loadChapters() async {
        guard let client else {
            errorMessage = "阅读服务器地址无效"
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            chapters = try await client.fetchChapters(for: book)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

struct TVBookDetailView: View {
    @StateObject private var viewModel: TVBookDetailViewModel

    init(book: TVShelfBook, client: ReaderServerClient?) {
        _viewModel = StateObject(wrappedValue: TVBookDetailViewModel(book: book, client: client))
    }

    var body: some View {
        ZStack {
            TVPalette.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 38) {
                    detailHeader
                    chapterArea
                }
                .padding(.horizontal, 72)
                .padding(.vertical, 56)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            if viewModel.chapters.isEmpty {
                await viewModel.loadChapters()
            }
        }
    }

    private var detailHeader: some View {
        HStack(alignment: .top, spacing: 44) {
            TVBookCard(book: viewModel.book, baseURL: viewModel.client?.baseURL ?? URL(string: "http://192.168.31.205:4396/")!)

            VStack(alignment: .leading, spacing: 18) {
                Text(viewModel.book.name)
                    .font(.system(size: 54, weight: .semibold, design: .serif))
                    .foregroundStyle(TVPalette.ink)
                    .lineLimit(2)

                HStack(spacing: 16) {
                    Text(viewModel.book.displayAuthor)
                    if let wordCount = viewModel.book.wordCount {
                        Text(wordCount)
                    }
                    if let total = viewModel.book.totalChapterNum {
                        Text("\(total) 章")
                    }
                }
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(TVPalette.accent)

                Text(viewModel.book.intro ?? "暂无简介")
                    .font(.system(size: 24))
                    .foregroundStyle(TVPalette.muted)
                    .lineSpacing(8)
                    .lineLimit(6)

                if let client = viewModel.client, !viewModel.chapters.isEmpty {
                    NavigationLink {
                        TVReaderView(
                            book: viewModel.book,
                            chapters: viewModel.chapters,
                            initialIndex: viewModel.book.durChapterIndex ?? 0,
                            client: client
                        )
                    } label: {
                        Label("继续阅读", systemImage: "book.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(TVPalette.accent)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var chapterArea: some View {
        if viewModel.isLoading {
            ProgressView("正在加载目录")
                .progressViewStyle(.circular)
                .tint(TVPalette.accent)
                .font(.title2)
        } else if let errorMessage = viewModel.errorMessage {
            TVErrorState(message: errorMessage) {
                Task { await viewModel.loadChapters() }
            }
        } else {
            VStack(alignment: .leading, spacing: 22) {
                Text("章节")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(TVPalette.ink)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 360, maximum: 430), spacing: 22)],
                    alignment: .leading,
                    spacing: 18
                ) {
                    ForEach(viewModel.chapters.prefix(180)) { chapter in
                        if let client = viewModel.client {
                            NavigationLink {
                                TVReaderView(
                                    book: viewModel.book,
                                    chapters: viewModel.chapters,
                                    initialIndex: chapter.chapterIndex,
                                    client: client
                                )
                            } label: {
                                Text(chapter.title)
                                    .font(.system(size: 22, weight: .medium))
                                    .foregroundStyle(TVPalette.ink)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 22)
                                    .frame(height: 70)
                                    .background(TVPalette.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if viewModel.chapters.count > 180 {
                    Text("已显示前 180 章，更多章节可在 iPhone / Mac 端继续阅读。")
                        .font(.system(size: 22))
                        .foregroundStyle(TVPalette.muted)
                }
            }
        }
    }
}

@MainActor
final class TVReaderViewModel: ObservableObject {
    @Published var content = ""
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var currentIndex: Int

    let book: TVShelfBook
    let chapters: [TVChapter]
    let client: ReaderServerClient

    init(book: TVShelfBook, chapters: [TVChapter], initialIndex: Int, client: ReaderServerClient) {
        self.book = book
        self.chapters = chapters
        self.client = client
        self.currentIndex = chapters.first(where: { $0.chapterIndex == initialIndex })?.chapterIndex ?? chapters.first?.chapterIndex ?? 0
    }

    var currentChapter: TVChapter? {
        chapters.first { $0.chapterIndex == currentIndex }
    }

    var canGoPrevious: Bool {
        guard let position = chapters.firstIndex(where: { $0.chapterIndex == currentIndex }) else { return false }
        return position > 0
    }

    var canGoNext: Bool {
        guard let position = chapters.firstIndex(where: { $0.chapterIndex == currentIndex }) else { return false }
        return position < chapters.count - 1
    }

    func loadCurrentChapter() async {
        isLoading = true
        errorMessage = nil
        do {
            content = try await client.fetchContent(for: book, chapterIndex: currentIndex)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func goPrevious() {
        guard let position = chapters.firstIndex(where: { $0.chapterIndex == currentIndex }),
              position > 0 else { return }
        currentIndex = chapters[position - 1].chapterIndex
    }

    func goNext() {
        guard let position = chapters.firstIndex(where: { $0.chapterIndex == currentIndex }),
              position < chapters.count - 1 else { return }
        currentIndex = chapters[position + 1].chapterIndex
    }
}

struct TVReaderView: View {
    @StateObject private var viewModel: TVReaderViewModel

    init(book: TVShelfBook, chapters: [TVChapter], initialIndex: Int, client: ReaderServerClient) {
        _viewModel = StateObject(
            wrappedValue: TVReaderViewModel(book: book, chapters: chapters, initialIndex: initialIndex, client: client)
        )
    }

    var body: some View {
        ZStack {
            TVPalette.background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 22) {
                header

                ScrollViewReader { proxy in
                    ScrollView {
                        Color.clear
                            .frame(height: 1)
                            .id("top")

                        Group {
                            if viewModel.isLoading {
                                ProgressView("正在加载正文")
                                    .tint(TVPalette.accent)
                                    .font(.title2)
                                    .frame(maxWidth: .infinity, minHeight: 420)
                            } else if let errorMessage = viewModel.errorMessage {
                                TVErrorState(message: errorMessage) {
                                    Task { await viewModel.loadCurrentChapter() }
                                }
                            } else {
                                Text(viewModel.content)
                                    .font(.system(size: 34, weight: .regular, design: .serif))
                                    .foregroundStyle(TVPalette.ink)
                                    .lineSpacing(18)
                                    .frame(maxWidth: 1180, alignment: .leading)
                                    .padding(.bottom, 80)
                            }
                        }
                    }
                    .onChange(of: viewModel.currentIndex) { _, _ in
                        Task {
                            await viewModel.loadCurrentChapter()
                            withAnimation(.easeOut(duration: 0.18)) {
                                proxy.scrollTo("top", anchor: .top)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 52)
        }
        .preferredColorScheme(.dark)
        .task {
            if viewModel.content.isEmpty {
                await viewModel.loadCurrentChapter()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text(viewModel.book.name)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(TVPalette.accent)
                Text(viewModel.currentChapter?.title ?? "正文")
                    .font(.system(size: 44, weight: .semibold, design: .serif))
                    .foregroundStyle(TVPalette.ink)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                viewModel.goPrevious()
            } label: {
                Label("上一章", systemImage: "chevron.left")
            }
            .disabled(!viewModel.canGoPrevious)

            Button {
                viewModel.goNext()
            } label: {
                Label("下一章", systemImage: "chevron.right")
            }
            .disabled(!viewModel.canGoNext)
        }
        .buttonStyle(.bordered)
        .tint(TVPalette.accent)
    }
}
