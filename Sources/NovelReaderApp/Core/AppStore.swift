import Foundation
import SwiftUI

private struct ReaderServerEnvelope<T: Decodable>: Decodable {
    var isSuccess: Bool
    var errorMsg: String?   // optional — server may omit it on success
    var data: T?            // optional — server sends null when isSuccess=false
}

private struct ReaderServerStatusEnvelope: Decodable {
    var isSuccess: Bool
    var errorMsg: String?
}

private struct ReaderServerShelfBook: Decodable {
    var bookUrl: String
    var tocUrl: String?
    var originName: String?
    var name: String
    var author: String?
    var coverUrl: String?
    var intro: String?
    var durChapterTitle: String?
    var durChapterIndex: Int?
}

private struct ReaderServerChapter: Decodable {
    var url: String?
    var title: String
    var index: Int?
}

@MainActor
final class AppStore: ObservableObject {
    @Published var books: [Book] = []
    @Published var sources: [BookSource] = []
    @Published var nasConnections: [NASConnection] = []
    @Published var downloads: [DownloadTaskItem] = []
    @Published var readerTheme: ReaderTheme = .classic
    @Published var selectedBook: Book?
    @Published var searchResults: [SearchResult] = []
    @Published var librarySearchHits: [LibrarySearchHit] = []
    @Published var nasItems: [NASItem] = []
    @Published var discoveredNASServices: [NASDiscoveryResult] = []
    @Published var activityMessage = ""
    @Published var isLibraryLoading = true
    @Published var isSourceSearching = false
    @Published var sourceSearchProgress = 0.0
    @Published var pendingReaderSyncBookIDs: Set<UUID> = []
    @Published var isReaderServerReachable = false
    @Published var isReaderServerSyncing = false
    @Published var lastReaderServerSyncAt: Date?
    @Published var showServerSetup = false

    /// True when no reader server has been configured yet.
    var needsServerSetup: Bool {
        !nasConnections.contains(where: { $0.kind == .readerServer })
    }

    private lazy var storage: LibraryStorage = SQLiteLibraryStorage()
    private let sourceEngine = BookSourceEngine()
    private let webDAVClient = WebDAVClient()
    private let cache = LibraryCache()
    private let bonjourBrowser = BonjourNASBrowser()
    private let backgroundDownloadService = BackgroundDownloadService()
    private let cloudSyncService = CloudSyncService.makeIfAvailable()
    private let credentialStore: NASCredentialStore = KeychainNASCredentialStore()
    private var downloadWorkers: [UUID: Task<Void, Never>] = [:]
    private var saveTask: Task<Void, Never>?
    private var saveDebounceDuration: Duration = .milliseconds(300)
    private var batchCacheSaveCounter = 0
    private var pendingCacheContinuation: (bookID: UUID, originalLimit: Int?)? = nil
    private var sourceSearchTask: Task<Void, Never>?
    private var activeSearchID: UUID?
    private let defaultReaderServerInstallKey = "NovelReaderApp.didInstallDefaultReaderServer.192.168.31.205.4396"
    private let pendingReaderSyncKey = "NovelReaderApp.pendingReaderSyncBookIDs"
    private let lastReaderSyncKey = "NovelReaderApp.lastReaderServerSyncAt"
    private let maxConcurrentDownloads = 3

    init() {
        activityMessage = "正在加载本地书库"
        Task {
            await loadAtStartup()
        }
    }

    func load() {
        do {
            let snapshot = try storage.load()
            applyLoadedSnapshot(snapshot)
        } catch {
            isLibraryLoading = false
            activityMessage = "读取本地书库失败：\(error.localizedDescription)"
        }
    }

    private func loadAtStartup() async {
        do {
            let snapshot = try await Task.detached(priority: .userInitiated) {
                try SQLiteLibraryStorage().load()
            }.value
            applyLoadedSnapshot(snapshot)
            // Fire-and-forget: don't block the UI for network sync
            Task { @MainActor [weak self] in
                await self?.recoverBackgroundDownloads()
            }
            Task { @MainActor [weak self] in
                await self?.syncLocalReadingStateWithReaderServerIfNeeded()
            }
        } catch {
            isLibraryLoading = false
            activityMessage = "读取本地书库失败：\(error.localizedDescription)"
        }
    }

    private func applyLoadedSnapshot(_ snapshot: LibrarySnapshot) {
        books = snapshot.books
        sources = snapshot.sources.map { source in
            var migrated = source
            migrated.rule.searchPath = LegadoSourceAdapter.normalizeImportedSearchPath(source.rule.searchPath)
            return migrated
        }
        nasConnections = restoreNASCredentials(snapshot.nasConnections)
        downloads = snapshot.downloads
        readerTheme = snapshot.readerTheme
        loadReaderSyncState()
        migrateDecodedNASPasswords(snapshot.nasConnections)
        replaceLegacySampleSourceIfNeeded()
        removeLegacySampleNASIfNeeded()
        // No longer installs a hardcoded default reader server;
        // user is guided to enter their own address on first launch.
        installBuiltInBookSourcesIfNeeded()
        if books.isEmpty && sources.isEmpty && nasConnections.isEmpty {
            bootstrapSampleData()
        }
        isLibraryLoading = false
        if needsServerSetup {
            showServerSetup = true
        }
        if activityMessage == "正在加载本地书库" {
            activityMessage = "准备就绪"
        }
    }

    func save() {
        scheduleSave(debounce: saveDebounceDuration)
    }

    /// Debounced save — coalesces rapid successive calls (e.g. during batch chapter caching).
    /// Each call cancels the previous pending save; the actual write only happens after
    /// `debounce` elapses with no new calls, preventing the JSON encoder from running
    /// hundreds of times when caching many chapters.
    private func scheduleSave(debounce: Duration) {
        persistNASCredentials(nasConnections)
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, let self else { return }
            let snapshot = LibrarySnapshot(
                books: self.books,
                sources: self.sources,
                nasConnections: self.nasConnections,
                downloads: self.downloads,
                readerTheme: self.readerTheme
            )
            do {
                try await Task.detached(priority: .utility) {
                    try autoreleasepool {
                        try SQLiteLibraryStorage().save(snapshot)
                    }
                }.value
            } catch {
                await MainActor.run {
                    self.activityMessage = "保存失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func saveImmediatelyForTestsAndExports() {
        let snapshot = LibrarySnapshot(
            books: books,
            sources: sources,
            nasConnections: nasConnections,
            downloads: downloads,
            readerTheme: readerTheme
        )
        do {
            persistNASCredentials(nasConnections)
            try storage.save(snapshot)
        } catch {
            activityMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    func bootstrapSampleData() {
        let chapters = [
            Chapter(index: 0, title: "第一章 雨夜归家", url: nil, localText: SampleText.chapterOne, isDownloaded: true),
            Chapter(index: 1, title: "第二章 阁楼里的书", url: nil, localText: SampleText.chapterTwo, isDownloaded: true),
            Chapter(index: 2, title: "第三章 远处的灯", url: nil, localText: SampleText.chapterThree, isDownloaded: true)
        ]
        books = [
            Book(
                title: "雾港旧事",
                author: "本地样书",
                summary: "用于验证书架、目录、阅读器和进度同步的示例小说。",
                coverSymbol: "book.closed.fill",
                format: .txt,
                sourceName: "本地",
                localURL: nil,
                status: .reading,
                progress: ReadingProgress(chapterIndex: 0, scrollOffset: 0, percentage: 0.12),
                chapters: chapters,
                addedAt: .now,
                updatedAt: .now
            )
        ]
        sources = BuiltInBookSources.all
        nasConnections = []
        downloads = [
            DownloadTaskItem(bookID: books[0].id, title: "雾港旧事", sourceName: "本地", progress: 1, state: .finished, message: "已缓存 3 章", createdAt: .now)
        ]
        save()
    }

    func importPlainText(title: String, author: String, text: String, sourceName: String) {
        let parsed = PlainTextBookParser().parse(title: title, author: author, text: text)
        books.insert(parsed, at: 0)
        selectedBook = parsed
        save()
    }

    func importLocalFile(_ url: URL) {
        do {
            let cachedURL = try cache.copyLocalFile(url)
            let lowercasedName = cachedURL.lastPathComponent.lowercased()
            if lowercasedName.hasSuffix(".txt") {
                let data = try Data(contentsOf: cachedURL)
                guard let text = TextDecoder().decode(data) else {
                    activityMessage = "无法识别 TXT 编码：\(cachedURL.lastPathComponent)"
                    return
                }
                var parsed = PlainTextBookParser().parse(title: cachedURL.deletingPathExtension().lastPathComponent, author: "本地文件", text: text)
                parsed.localURL = cachedURL
                books.insert(parsed, at: 0)
                selectedBook = parsed
                activityMessage = "已导入 TXT：\(parsed.title)"
            } else if lowercasedName.hasSuffix(".epub") {
                let book = (try? EPUBBookParser().parse(url: cachedURL, author: "本地文件", sourceName: "本地")) ?? EPUBBookParser().parsePlaceholder(
                    title: cachedURL.deletingPathExtension().lastPathComponent,
                    author: "本地文件",
                    sourceName: "本地",
                    localURL: cachedURL
                )
                books.insert(book, at: 0)
                selectedBook = book
                activityMessage = "已导入 EPUB：\(book.title)"
            } else {
                activityMessage = "暂不支持该文件：\(cachedURL.lastPathComponent)"
            }
            save()
        } catch {
            activityMessage = "导入失败：\(error.localizedDescription)"
        }
    }

    func updateProgress(bookID: UUID, chapterIndex: Int, percentage: Double) {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[index].progress.chapterIndex = chapterIndex
        books[index].progress.percentage = percentage
        books[index].status = percentage >= 0.99 ? .finished : .reading
        books[index].updatedAt = .now
        if selectedBook?.id == bookID {
            selectedBook = books[index]
        }
        markBookNeedsReaderSync(bookID)
        save()
    }

    func startSearch(keyword: String) {
        sourceSearchTask?.cancel()
        let searchID = UUID()
        activeSearchID = searchID
        sourceSearchTask = Task { [weak self] in
            await self?.runSearch(keyword: keyword, searchID: searchID)
        }
    }

    func cancelSourceSearch() {
        sourceSearchTask?.cancel()
        sourceSearchTask = nil
        activeSearchID = nil
        isSourceSearching = false
        sourceSearchProgress = 0
        activityMessage = searchResults.isEmpty ? "已停止搜索" : "已停止搜索，保留 \(searchResults.count) 条结果"
    }

    func search(keyword: String) async {
        let searchID = UUID()
        activeSearchID = searchID
        await runSearch(keyword: keyword, searchID: searchID)
    }

    private func runSearch(keyword: String, searchID: UUID) async {
        let trimmedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKeyword.isEmpty else {
            guard isCurrentSearch(searchID) else { return }
            searchResults = []
            isSourceSearching = false
            sourceSearchProgress = 0
            return
        }
        guard isCurrentSearch(searchID) else { return }
        searchResults = []
        sourceSearchProgress = 0
        let enabledSources = sources.filter(\.isEnabled)
        guard !enabledSources.isEmpty else {
            guard isCurrentSearch(searchID) else { return }
            activityMessage = "没有启用的书源"
            isSourceSearching = false
            sourceSearchProgress = 0
            return
        }

        isSourceSearching = true
        activityMessage = "正在搜索 \(enabledSources.count) 个启用书源"

        var seenKeys = Set<String>()
        let displayResultLimit = 160
        for await batch in sourceEngine.searchBatches(keyword: trimmedKeyword, in: enabledSources) {
            guard isCurrentSearch(searchID) else {
                return
            }
            sourceSearchProgress = batch.totalSources == 0 ? 0 : Double(batch.completedSources) / Double(batch.totalSources)
            let freshResults = batch.results.filter { result in
                let key = "\(result.sourceName)|\(result.title)|\(result.author)"
                guard !seenKeys.contains(key) else { return false }
                seenKeys.insert(key)
                return true
            }
            if !freshResults.isEmpty {
                withAnimation(.snappy(duration: 0.22)) {
                    searchResults.append(contentsOf: freshResults)
                    if searchResults.count > displayResultLimit {
                        searchResults = Array(searchResults.prefix(displayResultLimit))
                    }
                }
            }
            activityMessage = "已搜索 \(batch.completedSources)/\(batch.totalSources) 个书源，找到 \(searchResults.count) 条结果"
        }

        guard isCurrentSearch(searchID) else { return }
        isSourceSearching = false
        sourceSearchProgress = 1
        activityMessage = "已搜索全部 \(enabledSources.count) 个书源，找到 \(searchResults.count) 条结果"
    }

    private func isCurrentSearch(_ searchID: UUID) -> Bool {
        activeSearchID == searchID && !Task.isCancelled
    }

    func searchLibrary(keyword: String) {
        do {
            librarySearchHits = try storage.search(keyword: keyword)
        } catch {
            librarySearchHits = []
        }
    }

    func addSearchResultToShelf(_ result: SearchResult) {
        Task { await addSearchResultToShelf(result) }
    }

    func addSearchResultToShelf(_ result: SearchResult) async {
        let book = Book(
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
            chapters: await fetchTOCPreview(for: result),
            addedAt: .now,
            updatedAt: .now
        )
        books.insert(book, at: 0)
        enqueueChapterDownloads(for: book)
        save()
    }

    func downloadSearchResult(_ result: SearchResult) async {
        guard let source = sources.first(where: { $0.name == result.sourceName }) else {
            activityMessage = "未找到书源：\(result.sourceName)"
            return
        }

        let taskID = UUID()
        let pendingBookID = UUID()
        downloads.insert(
            DownloadTaskItem(
                id: taskID,
                bookID: pendingBookID,
                title: result.title,
                sourceName: result.sourceName,
                progress: 0.08,
                state: .running,
                message: "正在读取目录",
                createdAt: .now
            ),
            at: 0
        )
        save()

        let progressTask = animateDownloadProgress(id: taskID, upperBound: 0.72, message: "正在下载正文")
        defer { progressTask.cancel() }

        do {
            var book = try await sourceEngine.downloadBook(from: result, source: source)
            book.id = pendingBookID
            book.remoteBookURL = result.bookURL
            book.remoteBookURLString = result.bookURL.absoluteString
            markDownload(taskID, state: .running, progress: 0.78, message: "正在写入书架")
            books.insert(book, at: 0)
            markDownload(taskID, state: .finished, progress: 1, message: "已下载 \(book.chapters.count) 章")
            activityMessage = "已下载：\(book.title)"
            save()
        } catch {
            markDownload(taskID, state: .failed, progress: 0, message: error.localizedDescription)
            activityMessage = "下载失败：\(error.localizedDescription)"
        }
    }

    func downloadTask(for result: SearchResult) -> DownloadTaskItem? {
        downloads.first {
            $0.kind == .book
                && $0.title == result.title
                && $0.sourceName == result.sourceName
        }
    }

    func importBookSourceJSON(_ data: Data) {
        do {
            let importedSources = try decodeBookSources(data)
            upsertBookSources(importedSources)
            activityMessage = "已导入 \(importedSources.count) 个书源"
            save()
        } catch {
            activityMessage = "书源导入失败：\(error.localizedDescription)"
        }
    }

    func importBookSourceURL(_ value: String) async {
        guard let url = normalizedBookSourceImportURL(value) else {
            activityMessage = "书源链接无效"
            return
        }

        activityMessage = "正在导入远程书源"
        do {
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 AppleWebKit YuanYue", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw AppServiceError.invalidResponse
            }
            let importedSources = try decodeBookSources(data)
            upsertBookSources(importedSources)
            activityMessage = "已从远程导入 \(importedSources.count) 个书源"
            save()
        } catch {
            activityMessage = "远程书源导入失败：\(error.localizedDescription)"
        }
    }

    func exportBookSource(_ source: BookSource) -> Data? {
        try? JSONEncoder.appEncoder.encode(source)
    }

    func exportLibraryBackup() -> Data? {
        let snapshot = LibrarySnapshot(
            books: books,
            sources: sources,
            nasConnections: nasConnections,
            downloads: downloads,
            readerTheme: readerTheme
        )
        return try? JSONEncoder.appEncoder.encode(snapshot)
    }

    func importLibraryBackup(_ data: Data) {
        do {
            let snapshot = try JSONDecoder.appDecoder.decode(LibrarySnapshot.self, from: data)
            books = snapshot.books
            sources = snapshot.sources
            nasConnections = restoreNASCredentials(snapshot.nasConnections)
            downloads = snapshot.downloads
            readerTheme = snapshot.readerTheme
            migrateDecodedNASPasswords(snapshot.nasConnections)
            save()
            activityMessage = "已恢复备份"
        } catch {
            activityMessage = "恢复备份失败：\(error.localizedDescription)"
        }
    }

    func pushCloudSync() async {
        guard let cloudSyncService else {
            activityMessage = CloudSyncError.unavailable.localizedDescription
            return
        }
        do {
            try await cloudSyncService.push(payload: cloudPayload())
            activityMessage = "已同步到 iCloud"
        } catch {
            activityMessage = "iCloud 同步失败：\(error.localizedDescription)"
        }
    }

    func pullCloudSync() async {
        guard let cloudSyncService else {
            activityMessage = CloudSyncError.unavailable.localizedDescription
            return
        }
        do {
            let payload = try await cloudSyncService.pull()
            applyCloudPayload(payload)
            save()
            activityMessage = "已从 iCloud 恢复阅读状态"
        } catch {
            activityMessage = "iCloud 恢复失败：\(error.localizedDescription)"
        }
    }

    func browseNAS(_ connection: NASConnection) async {
        await browseNAS(connection, path: connection.baseURL)
    }

    func browseNAS(_ connection: NASConnection, path: URL) async {
        activityMessage = "正在连接 \(connection.name)"
        do {
            nasItems = try await webDAVClient.listDirectory(connection: connection, path: path)
                .sorted { lhs, rhs in
                    if lhs.isDirectory != rhs.isDirectory {
                        return lhs.isDirectory && !rhs.isDirectory
                    }
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
            activityMessage = "\(connection.name) 返回 \(nasItems.count) 个项目"
        } catch AppServiceError.unauthorized {
            nasItems = []
            activityMessage = AppServiceError.unauthorized.localizedDescription
        } catch AppServiceError.forbidden {
            nasItems = []
            activityMessage = AppServiceError.forbidden.localizedDescription
        } catch AppServiceError.unsupportedProtocol(let name) {
            nasItems = []
            activityMessage = "\(name) 需要接入对应原生客户端库；当前可先使用 WebDAV，侧载版后续可挂 SMB/SFTP 适配器"
        } catch {
            nasItems = NASPreviewFactory.previewItems(baseURL: path)
            activityMessage = "无法连接 NAS，已显示预览数据：\(error.localizedDescription)"
        }
    }

    func makeNASFolder(named name: String, in connection: NASConnection, parentURL: URL) async {
        do {
            try await webDAVClient.makeDirectory(connection: connection, parentURL: parentURL, name: name)
            activityMessage = "已新建文件夹：\(name)"
            await browseNAS(connection, path: parentURL)
        } catch {
            activityMessage = "新建文件夹失败：\(error.localizedDescription)"
        }
    }

    func deleteNASItem(_ item: NASItem, from connection: NASConnection, refreshPath: URL) async {
        do {
            try await webDAVClient.deleteItem(connection: connection, item: item)
            activityMessage = "已删除：\(item.name)"
            await browseNAS(connection, path: refreshPath)
        } catch {
            activityMessage = "删除失败：\(error.localizedDescription)"
        }
    }

    func importNASItem(_ item: NASItem, from connection: NASConnection) async {
        guard !item.isDirectory else { return }
        let taskID = UUID()
        downloads.insert(
            DownloadTaskItem(
                id: taskID,
                bookID: UUID(),
                title: item.name,
                sourceName: connection.name,
                progress: 0,
                state: .running,
                message: "正在缓存 NAS 文件",
                createdAt: .now
            ),
            at: 0
        )
        save()

        let progressTask = animateDownloadProgress(id: taskID, upperBound: 0.86, message: "正在缓存 NAS 文件")
        defer { progressTask.cancel() }

        do {
            let cachedURL = try await webDAVClient.downloadFile(connection: connection, item: item, cache: cache)
            if item.name.lowercased().hasSuffix(".txt") {
                let data = try Data(contentsOf: cachedURL)
                guard let text = TextDecoder().decode(data) else {
                    markDownload(taskID, state: .failed, progress: 0, message: "无法识别 TXT 编码")
                    return
                }
                let parsed = PlainTextBookParser().parse(title: cachedURL.deletingPathExtension().lastPathComponent, author: "NAS", text: text)
                var imported = parsed
                imported.sourceName = connection.name
                imported.localURL = cachedURL
                books.insert(imported, at: 0)
                markDownload(taskID, state: .finished, progress: 1, message: "已导入 TXT")
            } else if item.name.lowercased().hasSuffix(".epub") {
                let book = (try? EPUBBookParser().parse(url: cachedURL, author: "NAS", sourceName: connection.name)) ?? EPUBBookParser().parsePlaceholder(
                    title: cachedURL.deletingPathExtension().lastPathComponent,
                    author: "NAS",
                    sourceName: connection.name,
                    localURL: cachedURL
                )
                books.insert(book, at: 0)
                markDownload(taskID, state: .finished, progress: 1, message: "已缓存 EPUB")
            } else {
                markDownload(taskID, state: .failed, progress: 0, message: "暂不支持该格式")
            }
            save()
        } catch {
            markDownload(taskID, state: .failed, progress: 0, message: error.localizedDescription)
        }
    }

    func startQueuedDownloads() {
        startQueuedDownloadsIfNeeded(includePaused: true)
    }

    func pauseDownload(_ task: DownloadTaskItem) {
        guard let index = downloads.firstIndex(where: { $0.id == task.id }) else { return }
        downloads[index].state = .paused
        downloads[index].message = "已暂停"
        save()
    }

    func resumeDownload(_ task: DownloadTaskItem) {
        guard let index = downloads.firstIndex(where: { $0.id == task.id }) else { return }
        downloads[index].state = .running
        downloads[index].progress = max(downloads[index].progress, 0.12)
        downloads[index].message = "后台任务已继续"
        scheduleDownloadWorker(for: task.id)
        save()
    }

    func retryDownload(_ task: DownloadTaskItem) {
        guard let index = downloads.firstIndex(where: { $0.id == task.id }) else { return }
        downloads[index].state = .queued
        downloads[index].progress = 0
        downloads[index].message = "等待重试"
        startQueuedDownloadsIfNeeded()
        save()
    }

    func clearFinishedDownloads() {
        downloads.removeAll { $0.state == .finished }
        save()
    }

    func cacheFollowingChapters(for book: Book, limit: Int? = 50) {
        guard let currentBook = books.first(where: { $0.id == book.id }) else {
            activityMessage = "未找到书籍：\(book.title)"
            return
        }
        let useReaderServer = isReaderServerBackedBook(currentBook) && readerServerConnection != nil
        if isReaderServerBackedBook(currentBook) && !useReaderServer {
            activityMessage = "Reader 服务不可用，暂时无法缓存后续章节"
            return
        }
        let startIndex = min(currentBook.progress.chapterIndex + 1, currentBook.chapters.count)
        let chapters = currentBook.chapters
            .dropFirst(startIndex)
            .filter { chapter in
                !chapter.isDownloaded
                    && !hasActiveChapterDownload(bookID: currentBook.id, chapterIndex: chapter.index)
                    && (useReaderServer || chapter.url != nil)
            }
        // Cap the queue size to avoid creating thousands of tasks at once.
        // When a batch finishes, startQueuedDownloadsIfNeeded() will pick up more.
        let maxQueueSize = 30
        let effectiveLimit = limit.map { min($0, maxQueueSize) } ?? maxQueueSize
        let totalAvailable = chapters.count
        let selectedChapters = Array(chapters.prefix(effectiveLimit))
        guard !selectedChapters.isEmpty else {
            activityMessage = "后续章节已经缓存完成"
            return
        }
        let queued = selectedChapters.map { chapter in
            DownloadTaskItem(
                bookID: currentBook.id,
                title: "\(currentBook.title) · \(chapter.title)",
                sourceName: currentBook.sourceName,
                chapterIndex: chapter.index,
                kind: .chapter,
                remoteURL: useReaderServer ? nil : chapter.url,
                localURL: useReaderServer ? nil : chapter.url.map { cache.localURL(for: $0) },
                progress: 0,
                state: .queued,
                message: useReaderServer ? "等待缓存 Reader 章节" : "等待下载章节正文",
                createdAt: .now
            )
        }
        downloads.insert(contentsOf: queued, at: 0)
        let remaining = totalAvailable - selectedChapters.count
        if remaining > 0 {
            activityMessage = "已加入 \(queued.count) 章缓存任务（剩余 \(remaining) 章将自动继续）"
            // Store info for auto-continue when this batch completes
            pendingCacheContinuation = (bookID: currentBook.id, originalLimit: limit)
        } else {
            activityMessage = "已加入 \(queued.count) 个章节缓存任务"
        }
        batchCacheSaveCounter = 0
        save()
        startQueuedDownloads()
    }

    func canLoadReaderServerContent(for book: Book) -> Bool {
        isReaderServerBackedBook(book)
    }

    func cacheAllReadingBooksForOffline() {
        let readingBooks = books.filter { $0.status == .reading && $0.format == .web }
        guard !readingBooks.isEmpty else {
            activityMessage = "暂无在读的网络小说需要缓存"
            return
        }
        var queued = 0
        for book in readingBooks {
            let useReaderServer = isReaderServerBackedBook(book) && readerServerConnection != nil
            if isReaderServerBackedBook(book) && !useReaderServer { continue }
            let pendingChapters = book.chapters.filter { chapter in
                !chapter.isDownloaded
                    && !hasActiveChapterDownload(bookID: book.id, chapterIndex: chapter.index)
                    && (useReaderServer || chapter.url != nil)
            }
            let newTasks = pendingChapters.map { chapter in
                DownloadTaskItem(
                    bookID: book.id,
                    title: "\(book.title) · \(chapter.title)",
                    sourceName: book.sourceName,
                    chapterIndex: chapter.index,
                    kind: .chapter,
                    remoteURL: useReaderServer ? nil : chapter.url,
                    localURL: useReaderServer ? nil : chapter.url.map { cache.localURL(for: $0) },
                    progress: 0,
                    state: .queued,
                    message: useReaderServer ? "等待缓存 Reader 章节" : "等待下载章节正文",
                    createdAt: .now
                )
            }
            downloads.append(contentsOf: newTasks)
            queued += newTasks.count
        }
        if queued > 0 {
            activityMessage = "已加入 \(queued) 章节到下载队列"
            save()
            startQueuedDownloads()
        } else {
            activityMessage = "所有在读书籍章节均已缓存"
        }
    }

    @discardableResult
    func loadChapterContentIfNeeded(bookID: UUID, chapterIndex: Int) async -> Bool {
        guard let bookIndex = books.firstIndex(where: { $0.id == bookID }),
              books[bookIndex].chapters.indices.contains(chapterIndex) else {
            activityMessage = "未找到要阅读的章节"
            return false
        }
        let chapter = books[bookIndex].chapters[chapterIndex]
        guard chapter.localText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return true
        }
        guard isReaderServerBackedBook(books[bookIndex]) else {
            return false
        }
        guard let remoteBookURLString = books[bookIndex].remoteBookURLString ?? books[bookIndex].remoteBookURL?.absoluteString,
              let connection = readerServerConnection else {
            activityMessage = "Reader 服务不可用，无法在线读取正文"
            return false
        }

        let serverChapterIndex = readerServerIndex(for: chapter, fallback: chapterIndex)
        activityMessage = "正在从 Reader 服务读取：\(chapter.title)"
        do {
            let content = try await readerServerContent(bookURLString: remoteBookURLString, index: serverChapterIndex, connection: connection)
            storeReaderServerContent(content, bookID: bookID, chapterIndex: chapterIndex)
            activityMessage = content.isEmpty ? "Reader 返回空章节：\(chapter.title)" : "已读取并缓存：\(chapter.title)"
            return true
        } catch let appErr as AppServiceError {
            // Server returned isSuccess:false with an errorMsg
            activityMessage = appErr.localizedDescription
            return false
        } catch {
            let nsErr = error as NSError
            let isNetworkError = nsErr.domain == NSURLErrorDomain
            if isNetworkError {
                switch nsErr.code {
                case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                    activityMessage = "当前无网络连接"
                case NSURLErrorTimedOut:
                    activityMessage = "连接超时，服务器可能不在线"
                case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost:
                    activityMessage = "无法连接到阅读服务器，请检查地址和端口"
                default:
                    activityMessage = "网络错误：\(nsErr.localizedDescription)"
                }
            } else if let decodingErr = error as? DecodingError {
                // JSON format mismatch
                activityMessage = "服务器返回了无法识别的格式，请确认 Reader 版本兼容"
                _ = decodingErr
            } else {
                activityMessage = "读取失败：\(nsErr.localizedDescription)"
            }
            return false
        }
    }

    func recoverBackgroundDownloads() async {
        let requests = downloads.compactMap { task -> DownloadRequest? in
            guard task.state == .running,
                  let remoteURL = task.remoteURL else {
                return nil
            }
            return DownloadRequest(id: task.id, remoteURL: remoteURL, destinationURL: task.localURL ?? cache.localURL(for: remoteURL))
        }
        guard !requests.isEmpty else {
            recoverLocalDownloadWorkers()
            return
        }
        let streams = Dictionary(uniqueKeysWithValues: requests.map { ($0.id, backgroundDownloadService.events(for: $0)) })
        let recoveredIDs = await backgroundDownloadService.recover(requests)
        let recoveredSet = Set(recoveredIDs)
        for request in requests where !recoveredSet.contains(request.id) {
            if let index = downloads.firstIndex(where: { $0.id == request.id }) {
                downloads[index].state = .queued
                downloads[index].progress = 0
                downloads[index].message = "等待重新开始"
            }
        }
        for id in recoveredIDs {
            if let index = downloads.firstIndex(where: { $0.id == id }) {
                downloads[index].message = "已恢复系统后台下载"
                downloads[index].progress = max(downloads[index].progress, 0.05)
            }
            if let stream = streams[id] {
                consumeDownloadEvents(for: id, stream: stream)
            }
        }
        recoverLocalDownloadWorkers()
        activityMessage = recoveredIDs.isEmpty ? "下载任务已准备恢复" : "已恢复 \(recoveredIDs.count) 个后台下载"
        save()
    }

    private func recoverLocalDownloadWorkers() {
        var recoveredCount = 0
        for index in downloads.indices where downloads[index].state == .running && downloads[index].remoteURL == nil {
            guard shouldUseReaderServerChapterWorker(for: downloads[index]) else {
                downloads[index].state = .queued
                downloads[index].progress = 0
                downloads[index].message = "等待重新开始"
                continue
            }
            scheduleDownloadWorker(for: downloads[index].id)
            recoveredCount += 1
        }
        startQueuedDownloadsIfNeeded()
        if recoveredCount > 0 {
            activityMessage = "已恢复 \(recoveredCount) 个章节缓存任务"
        }
    }

    private func scheduleDownloadWorker(for id: UUID) {
        guard downloadWorkers[id] == nil else { return }
        guard let task = downloads.first(where: { $0.id == id }) else { return }
        if let remoteURL = task.remoteURL {
            scheduleURLDownloadWorker(for: task, remoteURL: remoteURL)
            return
        }
        if shouldUseReaderServerChapterWorker(for: task) {
            scheduleReaderServerChapterWorker(for: task)
            return
        }
        downloadWorkers[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.downloadWorkers[id] = nil }
            for step in 1...5 {
                try? await Task.sleep(for: .milliseconds(320))
                guard let index = self.downloads.firstIndex(where: { $0.id == id }) else { return }
                guard self.downloads[index].state == .running else { return }
                self.downloads[index].progress = min(0.95, max(self.downloads[index].progress, Double(step) * 0.18))
                self.downloads[index].message = "后台下载处理中"
            }
            guard let index = self.downloads.firstIndex(where: { $0.id == id }),
                  self.downloads[index].state == .running else {
                return
            }
            self.downloads[index].progress = 1
            self.downloads[index].state = .finished
            self.downloads[index].message = "后台任务完成"
            self.save()
            self.startQueuedDownloadsIfNeeded()
        }
    }

    private func scheduleURLDownloadWorker(for task: DownloadTaskItem, remoteURL: URL) {
        let destination = task.localURL ?? cache.localURL(for: remoteURL)
        downloadWorkers[task.id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.downloadWorkers[task.id] = nil }
            let request = DownloadRequest(id: task.id, remoteURL: remoteURL, destinationURL: destination)
            await self.handleDownloadEvents(for: task.id, stream: self.backgroundDownloadService.download(request))
        }
    }

    private func scheduleReaderServerChapterWorker(for task: DownloadTaskItem) {
        downloadWorkers[task.id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.downloadWorkers[task.id] = nil }
            guard let taskIndex = self.downloads.firstIndex(where: { $0.id == task.id }),
                  self.downloads[taskIndex].state == .running,
                  let chapterIndex = self.downloads[taskIndex].chapterIndex,
                  let bookIndex = self.books.firstIndex(where: { $0.id == self.downloads[taskIndex].bookID }),
                  self.books[bookIndex].chapters.indices.contains(chapterIndex),
                  let remoteBookURLString = self.books[bookIndex].remoteBookURLString ?? self.books[bookIndex].remoteBookURL?.absoluteString,
                  let connection = self.readerServerConnection else {
                self.markDownload(task.id, state: .failed, progress: 0, message: "Reader 服务不可用")
                return
            }
            let serverChapterIndex = self.readerServerIndex(for: self.books[bookIndex].chapters[chapterIndex], fallback: chapterIndex)

            self.downloads[taskIndex].progress = max(self.downloads[taskIndex].progress, 0.18)
            self.downloads[taskIndex].message = "正在请求 Reader 服务"
            let progressTask = self.animateDownloadProgress(id: task.id, upperBound: 0.84, message: "正在缓存章节正文")
            defer { progressTask.cancel() }

            do {
                let content = try await self.readerServerContent(bookURLString: remoteBookURLString, index: serverChapterIndex, connection: connection)
                guard let latestTaskIndex = self.downloads.firstIndex(where: { $0.id == task.id }),
                      self.downloads[latestTaskIndex].state == .running,
                      let latestBookIndex = self.books.firstIndex(where: { $0.id == self.downloads[latestTaskIndex].bookID }),
                      self.books[latestBookIndex].chapters.indices.contains(chapterIndex) else {
                    return
                }
                self.storeReaderServerContent(content, bookID: self.books[latestBookIndex].id, chapterIndex: chapterIndex)
                self.downloads[latestTaskIndex].progress = 1
                self.downloads[latestTaskIndex].state = .finished
                self.downloads[latestTaskIndex].message = content.isEmpty ? "章节为空，已记录" : "已缓存章节正文"
                // Debounced save — avoids re-encoding the entire library JSON on every chapter
                self.batchCacheSaveCounter += 1
                let shouldSaveNow = self.batchCacheSaveCounter % 5 == 0
                    || self.downloads.allSatisfy({ $0.state != .queued })
                if shouldSaveNow {
                    self.save()
                } else {
                    self.scheduleSave(debounce: .seconds(3))
                }
                self.startQueuedDownloadsIfNeeded()
            } catch {
                self.markDownload(task.id, state: .failed, progress: 0, message: error.localizedDescription)
                self.save()
                self.startQueuedDownloadsIfNeeded()
            }
        }
    }

    private func consumeDownloadEvents(for id: UUID, stream: AsyncStream<DownloadEvent>) {
        guard downloadWorkers[id] == nil else { return }
        downloadWorkers[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.downloadWorkers[id] = nil }
            await self.handleDownloadEvents(for: id, stream: stream)
        }
    }

    private func handleDownloadEvents(for id: UUID, stream: AsyncStream<DownloadEvent>) async {
        for await event in stream {
            guard let index = downloads.firstIndex(where: { $0.id == id }) else { return }
            switch event {
            case .progress(_, let progress):
                guard downloads[index].state == .running else { return }
                downloads[index].progress = progress
                downloads[index].message = "后台下载中"
            case .finished(_, let url):
                downloads[index].localURL = url
                if ingestFinishedDownload(downloads[index], fileURL: url) {
                    downloads[index].progress = 1
                    downloads[index].state = .finished
                    downloads[index].message = "已保存到本地缓存"
                } else {
                    downloads[index].progress = 0
                    downloads[index].state = .failed
                    downloads[index].message = "章节正文解析失败"
                }
                save()
                startQueuedDownloadsIfNeeded()
            case .failed(_, let message):
                downloads[index].state = .failed
                downloads[index].message = message
                save()
                startQueuedDownloadsIfNeeded()
            }
        }
    }

    private func startQueuedDownloadsIfNeeded(includePaused: Bool = false) {
        for task in downloads where task.state == .running && task.remoteURL == nil {
            scheduleDownloadWorker(for: task.id)
        }

        let activeRunningCount = downloads.filter { task in
            task.state == .running && (task.remoteURL != nil || downloadWorkers[task.id] != nil)
        }.count
        let staleRunningIDs = downloads.filter { task in
            task.state == .running && task.remoteURL == nil && downloadWorkers[task.id] == nil
        }.map(\.id)
        for id in staleRunningIDs {
            if let index = downloads.firstIndex(where: { $0.id == id }) {
                downloads[index].state = .queued
                downloads[index].progress = 0
                downloads[index].message = "等待重新开始"
            }
        }

        let runningCount = activeRunningCount
        var availableSlots = max(0, maxConcurrentDownloads - runningCount)
        guard availableSlots > 0 else { return }

        var didStartTask = false
        var startedIDs: Set<UUID> = []
        for index in downloads.indices {
            let canStart = downloads[index].state == .queued || (includePaused && downloads[index].state == .paused)
            guard canStart, availableSlots > 0 else { continue }
            downloads[index].state = .running
            downloads[index].progress = max(downloads[index].progress, 0.18)
            downloads[index].message = "后台任务已启动"
            availableSlots -= 1
            didStartTask = true
            startedIDs.insert(downloads[index].id)
        }
        for task in downloads where task.state == .running && (task.remoteURL == nil || startedIDs.contains(task.id)) {
            scheduleDownloadWorker(for: task.id)
        }
        if didStartTask || !staleRunningIDs.isEmpty {
            save()
        }

        // Auto-continue: if all queued/running tasks are done and there's a pending batch, queue more
        if !didStartTask,
           !downloads.contains(where: { $0.state == .queued || $0.state == .running }),
           let continuation = pendingCacheContinuation,
           let book = books.first(where: { $0.id == continuation.bookID }) {
            pendingCacheContinuation = nil
            // Clean up finished tasks to free memory before next batch
            downloads.removeAll { $0.state == .finished }
            cacheFollowingChapters(for: book, limit: continuation.originalLimit)
        }
    }

    private func fetchTOCPreview(for result: SearchResult) async -> [Chapter] {
        guard let source = sources.first(where: { $0.name == result.sourceName }),
              let chapters = try? await sourceEngine.fetchTableOfContents(from: result, source: source),
              !chapters.isEmpty else {
            return []
        }
        return chapters
    }

    private func enqueueChapterDownloads(for book: Book) {
        let queued = book.chapters.compactMap { chapter -> DownloadTaskItem? in
            guard let url = chapter.url else { return nil }
            return DownloadTaskItem(
                bookID: book.id,
                title: "\(book.title) · \(chapter.title)",
                sourceName: book.sourceName,
                chapterIndex: chapter.index,
                kind: .chapter,
                remoteURL: url,
                localURL: cache.localURL(for: url),
                progress: 0,
                state: .queued,
                message: "等待下载章节正文",
                createdAt: .now
            )
        }
        downloads.insert(contentsOf: queued, at: 0)
    }

    private func hasActiveChapterDownload(bookID: UUID, chapterIndex: Int) -> Bool {
        downloads.contains {
            $0.kind == .chapter
                && $0.bookID == bookID
                && $0.chapterIndex == chapterIndex
                && $0.state != .failed
                && $0.state != .finished
        }
    }

    private func shouldUseReaderServerChapterWorker(for task: DownloadTaskItem) -> Bool {
        guard task.kind == .chapter,
              task.remoteURL == nil,
              task.chapterIndex != nil,
              let book = books.first(where: { $0.id == task.bookID }) else {
            return false
        }
        return isReaderServerBackedBook(book) && book.chapters.indices.contains(task.chapterIndex ?? -1)
    }

    private func isReaderServerBackedBook(_ book: Book) -> Bool {
        if book.isReaderServerBacked == true { return true }
        guard book.format == .web, book.remoteBookURL != nil else { return false }
        return !sources.contains { $0.name == book.sourceName }
    }

    private func ingestFinishedDownload(_ task: DownloadTaskItem, fileURL: URL) -> Bool {
        guard task.kind == .chapter,
              let chapterIndex = task.chapterIndex,
              let source = sources.first(where: { $0.name == task.sourceName }),
              let bookIndex = books.firstIndex(where: { $0.id == task.bookID }),
              books[bookIndex].chapters.indices.contains(chapterIndex),
              let data = try? Data(contentsOf: fileURL),
              let text = try? sourceEngine.parseChapterContent(data: data, source: source) else {
            return false
        }
        books[bookIndex].chapters[chapterIndex].localText = text
        books[bookIndex].chapters[chapterIndex].isDownloaded = true
        books[bookIndex].updatedAt = .now
        if selectedBook?.id == books[bookIndex].id {
            selectedBook = books[bookIndex]
        }
        return true
    }

    func addConnection(_ connection: NASConnection) {
        nasConnections.append(connection)
        if !connection.password.isEmpty {
            do {
                try credentialStore.savePassword(connection.password, for: connection)
            } catch {
                activityMessage = "NAS 密码保存到 Keychain 失败：\(error.localizedDescription)"
            }
        }
        save()
    }

    func updateConnection(_ connection: NASConnection) {
        guard let index = nasConnections.firstIndex(where: { $0.id == connection.id }) else {
            addConnection(connection)
            return
        }
        nasConnections[index] = connection
        do {
            try credentialStore.savePassword(connection.password, for: connection)
        } catch {
            activityMessage = "NAS 密码保存到 Keychain 失败：\(error.localizedDescription)"
        }
        save()
    }

    func deleteConnection(_ connection: NASConnection) {
        nasConnections.removeAll { $0.id == connection.id }
        credentialStore.deletePassword(for: connection)
        nasItems = []
        activityMessage = "已删除 NAS：\(connection.name)"
        save()
    }

    func installBuiltInBookSources() {
        upsertBookSources(BuiltInBookSources.all)
        activityMessage = "已添加 \(BuiltInBookSources.all.count) 个推荐书源"
        save()
    }

    func saveBookSource(_ source: BookSource) {
        if let index = sources.firstIndex(where: { $0.id == source.id }) {
            sources[index] = source
            activityMessage = "已更新书源：\(source.name)"
        } else if let index = sources.firstIndex(where: { $0.name == source.name }) {
            sources[index] = source
            activityMessage = "已更新书源：\(source.name)"
        } else {
            sources.append(source)
            activityMessage = "已新增书源：\(source.name)"
        }
        save()
    }

    func enableOnlyBuiltInBookSources() {
        upsertBookSources(BuiltInBookSources.all)
        let builtInNames = Set(BuiltInBookSources.all.map(\.name))
        for index in sources.indices {
            sources[index].isEnabled = builtInNames.contains(sources[index].name)
        }
        activityMessage = "已仅启用推荐书源"
        save()
    }

    func setAllSourcesEnabled(_ isEnabled: Bool) {
        for index in sources.indices {
            sources[index].isEnabled = isEnabled
        }
        activityMessage = isEnabled ? "已启用全部书源" : "已停用全部书源"
        save()
    }

    func deleteBookSource(_ source: BookSource) {
        sources.removeAll { $0.id == source.id }
        searchResults.removeAll { $0.sourceName == source.name }
        activityMessage = "已删除书源：\(source.name)"
        save()
    }

    func deleteAllBookSources() {
        sourceSearchTask?.cancel()
        activeSearchID = nil
        sources.removeAll()
        searchResults.removeAll()
        isSourceSearching = false
        sourceSearchProgress = 0
        activityMessage = "已删除全部书源"
        save()
    }

    func startNASDiscovery() {
        activityMessage = "正在扫描局域网 NAS 服务"
        bonjourBrowser.start { [weak self] results in
            self?.discoveredNASServices = results
            self?.activityMessage = results.isEmpty ? "暂未发现 NAS 服务" : "发现 \(results.count) 个服务"
        }
    }

    func stopNASDiscovery() {
        bonjourBrowser.stop()
    }

    func addDiscoveredConnection(_ result: NASDiscoveryResult) {
        guard let url = result.url else {
            activityMessage = "无法生成连接地址：\(result.name)"
            return
        }
        addConnection(
            NASConnection(
                name: result.name,
                kind: result.kind,
                baseURL: url,
                username: "",
                password: "",
                isEnabled: true
            )
        )
        activityMessage = "已添加 NAS：\(result.name)"
    }

    func syncLocalReadingStateWithReaderServerIfNeeded() async {
        guard !pendingReaderSyncBookIDs.isEmpty else { return }
        await syncLocalReadingStateWithReaderServer()
    }

    func syncLocalReadingStateWithReaderServer() async {
        guard let connection = readerServerConnection else {
            isReaderServerReachable = false
            activityMessage = "还没有配置阅读服务器"
            return
        }

        let pendingIDs = pendingReaderSyncBookIDs
        guard !pendingIDs.isEmpty else {
            let reachable = await checkReaderServerReachability(connection)
            isReaderServerReachable = reachable
            activityMessage = reachable ? "阅读服务器在线，没有待同步进度" : "阅读服务器暂时不在线"
            return
        }

        isReaderServerSyncing = true
        defer { isReaderServerSyncing = false }

        let reachable = await checkReaderServerReachability(connection)
        isReaderServerReachable = reachable
        guard reachable else {
            activityMessage = "阅读服务器不在线，已保留 \(pendingIDs.count) 本待同步"
            return
        }

        var completedIDs = Set<UUID>()
        var pushedCount = 0
        var localOnlyCount = 0

        for bookID in pendingIDs {
            guard let book = books.first(where: { $0.id == bookID }) else {
                completedIDs.insert(bookID)
                continue
            }

            guard isReaderServerBackedBook(book) else {
                localOnlyCount += 1
                completedIDs.insert(bookID)
                continue
            }

            do {
                try await pushProgress(book, toReaderServer: connection)
                pushedCount += 1
                completedIDs.insert(bookID)
            } catch {
                activityMessage = "部分进度暂未同步：\(error.localizedDescription)"
            }
        }

        pendingReaderSyncBookIDs.subtract(completedIDs)
        if !completedIDs.isEmpty {
            lastReaderServerSyncAt = .now
        }
        persistReaderSyncState()

        if pendingReaderSyncBookIDs.isEmpty {
            if pushedCount > 0 {
                activityMessage = "已同步 \(pushedCount) 本阅读进度到 Reader 服务"
            } else if localOnlyCount > 0 {
                activityMessage = "本机书架进度已保留，纯本地书无需上传"
            } else {
                activityMessage = "阅读状态已同步"
            }
        } else {
            activityMessage = "已同步 \(pushedCount) 本，仍有 \(pendingReaderSyncBookIDs.count) 本待同步"
        }
    }

    func syncReaderServerShelfToLocal() async {
        guard let connection = readerServerConnection else {
            isReaderServerReachable = false
            activityMessage = "还没有配置阅读服务器"
            return
        }

        isReaderServerSyncing = true
        defer { isReaderServerSyncing = false }

        do {
            let shelf: ReaderServerEnvelope<[ReaderServerShelfBook]> = try await readerServerGET("reader3/getShelfBookWithCacheInfo", connection: connection)
            guard shelf.isSuccess, let shelfBooks = shelf.data else {
                activityMessage = shelf.errorMsg?.isEmpty == false ? shelf.errorMsg! : "Reader 书架同步失败"
                return
            }

            var importedCount = 0
            var updatedCount = 0

            for shelfBook in shelfBooks {
                guard let remoteURL = URL(string: shelfBook.bookUrl) else { continue }
                let originalBookURLString = shelfBook.bookUrl
                let chapters = (try? await readerServerChapters(for: shelfBook, connection: connection)) ?? []
                let currentIndex = max(shelfBook.durChapterIndex ?? 0, 0)
                let currentContent = (try? await readerServerContent(bookURLString: originalBookURLString, index: currentIndex, connection: connection)) ?? ""
                let coverImageURL = await readerServerCoverURL(for: shelfBook, connection: connection)
                let book = makeLocalBook(from: shelfBook, chapters: chapters, currentContent: currentContent, coverImageURL: coverImageURL)

                if let index = books.firstIndex(where: { $0.remoteBookURL == remoteURL }) {
                    books[index].summary = book.summary
                    books[index].sourceName = book.sourceName
                    books[index].remoteBookURL = remoteURL
                    books[index].remoteBookURLString = originalBookURLString
                    books[index].isReaderServerBacked = true
                    books[index].coverImageURL = book.coverImageURL ?? books[index].coverImageURL
                    books[index].progress = book.progress
                    books[index].updatedAt = .now
                    if !book.chapters.isEmpty {
                        books[index].chapters = mergeLocalChapters(existing: books[index].chapters, incoming: book.chapters)
                    }
                    updatedCount += 1
                } else {
                    books.insert(book, at: 0)
                    importedCount += 1
                }
            }

            lastReaderServerSyncAt = .now
            persistReaderSyncState()
            save()
            activityMessage = "已同步 Reader 书架：新增 \(importedCount) 本，更新 \(updatedCount) 本"
        } catch {
            activityMessage = "Reader 书架同步失败：\(error.localizedDescription)"
        }
    }

    private var readerServerConnection: NASConnection? {
        nasConnections.first { $0.kind == .readerServer && $0.isEnabled }
    }

    private func markBookNeedsReaderSync(_ bookID: UUID) {
        pendingReaderSyncBookIDs.insert(bookID)
        persistReaderSyncState()
    }

    private func loadReaderSyncState() {
        let defaults = UserDefaults.standard
        let rawIDs = defaults.array(forKey: pendingReaderSyncKey) as? [String] ?? []
        pendingReaderSyncBookIDs = Set(rawIDs.compactMap(UUID.init(uuidString:)))
        lastReaderServerSyncAt = defaults.object(forKey: lastReaderSyncKey) as? Date
    }

    private func persistReaderSyncState() {
        let defaults = UserDefaults.standard
        defaults.set(pendingReaderSyncBookIDs.map(\.uuidString), forKey: pendingReaderSyncKey)
        if let lastReaderServerSyncAt {
            defaults.set(lastReaderServerSyncAt, forKey: lastReaderSyncKey)
        } else {
            defaults.removeObject(forKey: lastReaderSyncKey)
        }
    }

    private func checkReaderServerReachability(_ connection: NASConnection) async -> Bool {
        var request = URLRequest(url: connection.baseURL, timeoutInterval: 3.5)
        request.httpMethod = "GET"
        request.setValue("Mozilla/5.0 YuanYue", forHTTPHeaderField: "User-Agent")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<500).contains(http.statusCode)
        } catch {
            return false
        }
    }

    private func pushProgress(_ book: Book, toReaderServer connection: NASConnection) async throws {
        guard let remoteBookURLString = book.remoteBookURLString ?? book.remoteBookURL?.absoluteString,
              let url = URL(string: "reader3/saveBookProgress", relativeTo: connection.baseURL)?.absoluteURL else {
            throw AppServiceError.invalidResponse
        }

        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 YuanYue", forHTTPHeaderField: "User-Agent")
        let localIndex = min(max(book.progress.chapterIndex, 0), max(book.chapters.count - 1, 0))
        let serverIndex = book.chapters.indices.contains(localIndex)
            ? readerServerIndex(for: book.chapters[localIndex], fallback: localIndex)
            : localIndex
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "url": remoteBookURLString,
            "index": serverIndex
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AppServiceError.invalidResponse
        }
        if let envelope = try? JSONDecoder.appDecoder.decode(ReaderServerStatusEnvelope.self, from: data),
           !envelope.isSuccess {
            throw AppServiceError.invalidResponse
        }
    }

    // Shared ephemeral session — bypasses NSURLCache, avoids "data missing" file errors.
    private let readerSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private func readerServerAuthHeader(for connection: NASConnection) -> String? {
        guard !connection.username.isEmpty else { return nil }
        let cred = "\(connection.username):\(connection.password)"
        guard let data = cred.data(using: .utf8) else { return nil }
        return "Basic \(data.base64EncodedString())"
    }

    private func readerServerGET<T: Decodable>(_ path: String, connection: NASConnection) async throws -> T {
        guard let url = URL(string: path, relativeTo: connection.baseURL)?.absoluteURL else {
            throw AppServiceError.invalidResponse
        }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 YuanYue", forHTTPHeaderField: "User-Agent")
        if let auth = readerServerAuthHeader(for: connection) {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await readerSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AppServiceError.invalidResponse
        }
        return try JSONDecoder.appDecoder.decode(T.self, from: data)
    }

    private func readerServerPOST<T: Decodable>(_ path: String, body: [String: Any], connection: NASConnection) async throws -> T {
        guard let url = URL(string: path, relativeTo: connection.baseURL)?.absoluteURL else {
            throw AppServiceError.invalidResponse
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 YuanYue", forHTTPHeaderField: "User-Agent")
        if let auth = readerServerAuthHeader(for: connection) {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await readerSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AppServiceError.invalidResponse
        }
        return try JSONDecoder.appDecoder.decode(T.self, from: data)
    }

    private func readerServerChapters(for book: ReaderServerShelfBook, connection: NASConnection) async throws -> [ReaderServerChapter] {
        let response: ReaderServerEnvelope<[ReaderServerChapter]> = try await readerServerPOST(
            "reader3/getChapterList",
            body: ["url": book.bookUrl, "refresh": 0],
            connection: connection
        )
        guard response.isSuccess, let chapters = response.data else {
            throw AppServiceError.serverError(response.errorMsg ?? "获取章节列表失败")
        }
        return chapters.sorted { ($0.index ?? 0) < ($1.index ?? 0) }
    }

    /// Fetch chapter content from the reader server.
    /// - Parameter bookURLString: The **original, unmodified** bookUrl string from the server.
    ///   Using `URL.absoluteString` would percent-encode embedded JSON and break books
    ///   from sources like "阅读助手" (e.g. 剑来, 神秘复苏).
    private func readerServerContent(bookURLString: String, index: Int, connection: NASConnection, allowTocRetry: Bool = true) async throws -> String {
        let response: ReaderServerEnvelope<String> = try await readerServerPOST(
            "reader3/getBookContent",
            body: ["url": bookURLString, "index": index],
            connection: connection
        )
        guard response.isSuccess, let text = response.data else {
            let errorMsg = response.errorMsg ?? "服务器未返回正文"
            // Legado throws TocEmptyException when chapter list hasn't been loaded yet.
            // Force-refresh the chapter list, then retry content fetch once.
            if allowTocRetry && (errorMsg.contains("TocEmpty") || errorMsg.contains("目录为空")) {
                let _: ReaderServerEnvelope<[ReaderServerChapter]>? = try? await readerServerPOST(
                    "reader3/getChapterList",
                    body: ["url": bookURLString, "refresh": 1],
                    connection: connection
                )
                try? await Task.sleep(for: .seconds(2))
                return try await readerServerContent(bookURLString: bookURLString, index: index, connection: connection, allowTocRetry: false)
            }
            throw AppServiceError.serverError(errorMsg)
        }
        return normalizeReaderServerContent(text)
    }

    private func readerServerIndex(for chapter: Chapter, fallback: Int) -> Int {
        max(chapter.remoteIndex ?? fallback, 0)
    }

    private func normalizeReaderServerContent(_ content: String) -> String {
        content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func storeReaderServerContent(_ content: String, bookID: UUID, chapterIndex: Int) {
        guard let bookIndex = books.firstIndex(where: { $0.id == bookID }),
              books[bookIndex].chapters.indices.contains(chapterIndex) else {
            return
        }
        books[bookIndex].chapters[chapterIndex].localText = normalizeReaderServerContent(content)
        books[bookIndex].chapters[chapterIndex].isDownloaded = true
        books[bookIndex].updatedAt = .now
        if selectedBook?.id == books[bookIndex].id {
            selectedBook = books[bookIndex]
        }
    }

    private func readerServerCoverURL(for book: ReaderServerShelfBook, connection: NASConnection) async -> URL? {
        guard let rawCover = book.coverUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawCover.isEmpty,
              let remoteURL = URL(string: rawCover, relativeTo: connection.baseURL)?.absoluteURL else {
            return nil
        }
        return await cacheRemoteCover(remoteURL, fallback: remoteURL)
    }

    private func cacheRemoteCover(_ remoteURL: URL, fallback: URL) async -> URL? {
        guard remoteURL.scheme == "http" || remoteURL.scheme == "https" else { return fallback }
        do {
            var request = URLRequest(url: remoteURL, timeoutInterval: 8)
            request.setValue("image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
            request.setValue("Mozilla/5.0 YuanYue", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else {
                return fallback
            }
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appending(path: "NovelReaderApp/Covers", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let ext = remoteURL.pathExtension.isEmpty ? "jpg" : remoteURL.pathExtension
            let safeBase = remoteURL.absoluteString
                .replacingOccurrences(of: #"[^A-Za-z0-9_-]+"#, with: "-", options: .regularExpression)
                .prefix(80)
            let destination = directory.appending(path: "\(safeBase).\(ext)")
            try data.write(to: destination, options: [.atomic])
            return destination
        } catch {
            return fallback
        }
    }

    private func makeLocalBook(from shelfBook: ReaderServerShelfBook, chapters: [ReaderServerChapter], currentContent: String, coverImageURL: URL?) -> Book {
        let currentRemoteIndex = max(shelfBook.durChapterIndex ?? 0, 0)
        let chapterModels: [Chapter]
        if chapters.isEmpty {
            chapterModels = [
                Chapter(
                    index: 0,
                    title: shelfBook.durChapterTitle ?? "当前章节",
                    url: shelfBook.tocUrl.flatMap(URL.init(string:)),
                    localText: normalizeReaderServerContent(currentContent),
                    isDownloaded: !currentContent.isEmpty
                )
            ]
        } else {
            let currentLocalIndex = chapters.firstIndex { ($0.index ?? 0) == currentRemoteIndex } ?? min(currentRemoteIndex, max(chapters.count - 1, 0))
            chapterModels = chapters.enumerated().map { offset, chapter in
                Chapter(
                    index: offset,
                    remoteIndex: chapter.index,
                    title: chapter.title,
                    url: chapter.url.flatMap(URL.init(string:)),
                    localText: offset == currentLocalIndex ? normalizeReaderServerContent(currentContent) : "",
                    isDownloaded: offset == currentLocalIndex && !currentContent.isEmpty
                )
            }
        }

        let chapterCount = max(chapterModels.count - 1, 1)
        let safeIndex = chapterModels.firstIndex { ($0.remoteIndex ?? $0.index) == currentRemoteIndex } ?? min(currentRemoteIndex, max(chapterModels.count - 1, 0))
        let remoteURL = URL(string: shelfBook.bookUrl)
        return Book(
            title: shelfBook.name,
            author: shelfBook.author?.isEmpty == false ? shelfBook.author ?? "未知作者" : "未知作者",
            summary: shelfBook.intro ?? "",
            coverSymbol: "books.vertical.fill",
            coverImageURL: coverImageURL,
            format: .web,
            sourceName: shelfBook.originName ?? "Reader 服务",
            localURL: nil,
            remoteBookURL: remoteURL,
            remoteBookURLString: shelfBook.bookUrl,
            isReaderServerBacked: true,
            status: safeIndex > 0 ? .reading : .unread,
            progress: ReadingProgress(chapterIndex: safeIndex, scrollOffset: 0, percentage: Double(safeIndex) / Double(chapterCount)),
            chapters: chapterModels,
            addedAt: .now,
            updatedAt: .now
        )
    }

    private func mergeLocalChapters(existing: [Chapter], incoming: [Chapter]) -> [Chapter] {
        guard !existing.isEmpty else { return incoming }
        var merged = incoming
        for index in merged.indices {
            if merged[index].localText.isEmpty,
               let oldChapter = matchingExistingChapter(for: merged[index], in: existing),
               !oldChapter.localText.isEmpty {
                merged[index].localText = oldChapter.localText
                merged[index].isDownloaded = oldChapter.isDownloaded
            }
        }
        return merged
    }

    private func matchingExistingChapter(for incoming: Chapter, in existing: [Chapter]) -> Chapter? {
        if let remoteIndex = incoming.remoteIndex,
           let match = existing.first(where: { $0.remoteIndex == remoteIndex }) {
            return match
        }
        if let url = incoming.url,
           let match = existing.first(where: { $0.url == url }) {
            return match
        }
        if let match = existing.first(where: { $0.title == incoming.title }) {
            return match
        }
        guard incoming.remoteIndex == nil else { return nil }
        return existing.first { $0.remoteIndex == nil && $0.index == incoming.index }
    }

    private func installDefaultReaderServerIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: defaultReaderServerInstallKey),
              !nasConnections.contains(where: { $0.kind == .readerServer }),
              let url = URL(string: "http://192.168.31.205:4396/") else {
            return
        }
        nasConnections.insert(
            NASConnection(
                name: "家里阅读服务器",
                kind: .readerServer,
                baseURL: url,
                username: "",
                password: "",
                isEnabled: true
            ),
            at: 0
        )
        defaults.set(true, forKey: defaultReaderServerInstallKey)
        activityMessage = "已添加阅读服务器：192.168.31.205:4396"
        save()
    }

    func deleteBooks(at offsets: IndexSet) {
        books.remove(atOffsets: offsets)
        save()
    }

    func deleteBook(_ book: Book) {
        books.removeAll { $0.id == book.id }
        downloads.removeAll { $0.bookID == book.id }
        pendingReaderSyncBookIDs.remove(book.id)
        persistReaderSyncState()
        if selectedBook?.id == book.id {
            selectedBook = nil
        }
        save()
    }

    func clearLocalCache(for book: Book) {
        guard let url = book.localURL else {
            activityMessage = "这本书没有本地缓存文件"
            return
        }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            if let index = books.firstIndex(where: { $0.id == book.id }) {
                books[index].localURL = nil
                books[index].chapters = books[index].chapters.map { chapter in
                    var updated = chapter
                    updated.isDownloaded = false
                    return updated
                }
            }
            activityMessage = "已清除缓存：\(book.title)"
            save()
        } catch {
            activityMessage = "清除缓存失败：\(error.localizedDescription)"
        }
    }

    func cacheSize(for book: Book) -> Int64? {
        guard let url = book.localURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return nil
        }
        return size.int64Value
    }

    private func markDownload(_ id: UUID, state: DownloadState, progress: Double, message: String) {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else { return }
        downloads[index].state = state
        downloads[index].progress = progress
        downloads[index].message = message
        save()
    }

    private func animateDownloadProgress(id: UUID, upperBound: Double, message: String) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(320))
                guard !Task.isCancelled,
                      let self,
                      let index = self.downloads.firstIndex(where: { $0.id == id }),
                      self.downloads[index].state == .running else {
                    return
                }
                let current = self.downloads[index].progress
                let easedStep = max(0.018, (upperBound - current) * 0.12)
                self.downloads[index].progress = min(upperBound, current + easedStep)
                self.downloads[index].message = message
            }
        }
    }

    private func decodeBookSources(_ data: Data) throws -> [BookSource] {
        let decoder = JSONDecoder.appDecoder
        if let source = try? decoder.decode(BookSource.self, from: data) {
            return [source]
        }
        if let sources = try? decoder.decode([BookSource].self, from: data) {
            return sources
        }
        return try LegadoSourceAdapter.decodeSources(from: data)
    }

    private func normalizedBookSourceImportURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("legado://"),
           let components = URLComponents(string: trimmed),
           let src = components.queryItems?.first(where: { $0.name == "src" })?.value {
            return URL(string: src)
        }

        return URL(string: trimmed)
    }

    private func upsertBookSources(_ importedSources: [BookSource]) {
        for imported in importedSources {
            if let index = sources.firstIndex(where: { $0.name == imported.name }) {
                sources[index] = imported
            } else {
                sources.append(imported)
            }
        }
    }

    private func installBuiltInBookSourcesIfNeeded() {
        let existingNames = Set(sources.map(\.name))
        let missingSources = BuiltInBookSources.all.filter { !existingNames.contains($0.name) }
        if !missingSources.isEmpty {
            sources.append(contentsOf: missingSources)
            save()
        }
    }

    private func replaceLegacySampleSourceIfNeeded() {
        guard sources.contains(where: { $0.name == "示例书源" || $0.baseURL.absoluteString == "https://example.com" }) else { return }
        sources.removeAll { $0.name == "示例书源" || $0.baseURL.absoluteString == "https://example.com" }
        upsertBookSources(BuiltInBookSources.all)
        save()
    }

    private func removeLegacySampleNASIfNeeded() {
        let count = nasConnections.count
        nasConnections.removeAll { connection in
            connection.name == "家里 NAS"
                && connection.baseURL.absoluteString == "https://nas.local:5006/books/"
                && connection.username == "reader"
                && connection.password.isEmpty
        }
        if nasConnections.count != count {
            save()
        }
    }

    private func restoreNASCredentials(_ connections: [NASConnection]) -> [NASConnection] {
        connections.map { connection in
            guard connection.password.isEmpty,
                  let password = credentialStore.password(for: connection) else {
                return connection
            }
            var restored = connection
            restored.password = password
            return restored
        }
    }

    private func migrateDecodedNASPasswords(_ connections: [NASConnection]) {
        for connection in connections where !connection.password.isEmpty {
            try? credentialStore.savePassword(connection.password, for: connection)
        }
    }

    private func persistNASCredentials(_ connections: [NASConnection]) {
        for connection in connections {
            if connection.password.isEmpty {
                credentialStore.deletePassword(for: connection)
            } else {
                try? credentialStore.savePassword(connection.password, for: connection)
            }
        }
    }

    private func cloudPayload() -> CloudSyncPayload {
        CloudSyncPayload(
            books: books.map {
                CloudBookMetadata(
                    id: $0.id,
                    title: $0.title,
                    author: $0.author,
                    sourceName: $0.sourceName,
                    format: $0.format,
                    status: $0.status,
                    progress: $0.progress,
                    updatedAt: $0.updatedAt
                )
            },
            readerTheme: readerTheme,
            updatedAt: .now
        )
    }

    private func applyCloudPayload(_ payload: CloudSyncPayload) {
        readerTheme = payload.readerTheme
        for metadata in payload.books {
            if let index = books.firstIndex(where: { $0.id == metadata.id }) {
                books[index].status = metadata.status
                books[index].progress = metadata.progress
                books[index].updatedAt = metadata.updatedAt
            }
        }
    }
}
