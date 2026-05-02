import SwiftUI
@preconcurrency import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct NASView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selectedConnection: NASConnection?
    @State private var showingAddConnection = false
    @State private var editingConnection: NASConnection?

    private var activeConnection: NASConnection? {
        store.nasConnections.first
    }

    var body: some View {
        NavigationStack {
            AppScreen {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        PageHeader(
                            title: "阅读服务",
                            subtitle: "打开家里的 Reader 服务，也可以管理 NAS 文件库。",
                            trailingSystemImage: "plus"
                        ) {
                            showingAddConnection = true
                        }
                        .padding(.top, 18)

                        serviceCard
                        outsideHomeCard

                        if !store.nasConnections.isEmpty {
                            connectionList
                        }

                        if !store.discoveredNASServices.isEmpty {
                            discoveredServices
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 28)
                }
            }
            .platformInlineNavigationTitle()
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        store.startNASDiscovery()
                    } label: {
                        Label("发现", systemImage: "dot.radiowaves.left.and.right")
                    }
                    Button {
                        showingAddConnection = true
                    } label: {
                        Label("新增", systemImage: "plus")
                    }
                }
            }
            .task {
                await store.syncLocalReadingStateWithReaderServerIfNeeded()
            }
            .navigationDestination(item: $selectedConnection) { connection in
                let liveConnection = store.nasConnections.first { $0.id == connection.id } ?? connection
                destination(for: liveConnection)
            }
        }
        .sheet(isPresented: $showingAddConnection) {
            NASConnectionEditorView()
                .environmentObject(store)
        }
        .sheet(item: $editingConnection) { connection in
            NASConnectionEditorView(connection: connection)
                .environmentObject(store)
        }
    }

    private var serviceCard: some View {
        PremiumCard {
            if let connection = activeConnection {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        PremiumIcon(systemName: icon(for: connection), tint: AppTheme.accent)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Text(connection.name)
                                    .font(.headline.weight(.semibold))
                                    .foregroundStyle(AppTheme.ink)
                                SmallStatusChip(title: connection.kind.title, tint: AppTheme.accent)
                                SmallStatusChip(title: statusTitle(for: connection), tint: statusTint(for: connection))
                            }
                            Text(connection.baseURL.absoluteString)
                                .font(.callout)
                                .foregroundStyle(AppTheme.mutedInk)
                                .lineLimit(2)
                        }
                        Spacer()
                        Menu {
                            Button {
                                editingConnection = connection
                            } label: {
                                Label("编辑连接", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                delete(connection)
                            } label: {
                                Label("删除连接", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(AppTheme.mutedInk)
                                .frame(width: 34, height: 34)
                        }
                    }

                    HStack(spacing: 10) {
                        Button {
                            selectedConnection = connection
                        } label: {
                            Label(primaryActionTitle(for: connection), systemImage: connection.kind == .readerServer ? "safari" : "folder")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.accent)

                        Button {
                            if connection.kind == .readerServer {
                                Task { await store.syncReaderServerShelfToLocal() }
                            } else {
                                Task { await store.browseNAS(connection) }
                                selectedConnection = connection
                            }
                        } label: {
                            Label(connection.kind == .readerServer ? "同步书架" : "刷新", systemImage: "arrow.clockwise")
                                .labelStyle(.iconOnly)
                                .frame(width: 42, height: 34)
                        }
                        .buttonStyle(.bordered)
                        .disabled(connection.kind == .readerServer && store.isReaderServerSyncing)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        PremiumIcon(systemName: "externaldrive.badge.plus", tint: AppTheme.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("还没有阅读服务")
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(AppTheme.ink)
                            Text("填写 Reader 服务地址或 NAS 文件库地址后，就能从这里打开。")
                                .font(.callout)
                                .foregroundStyle(AppTheme.mutedInk)
                        }
                    }

                    Button {
                        showingAddConnection = true
                    } label: {
                        Label("添加 NAS 连接", systemImage: "plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.accent)
                }
            }
        }
    }

    private var outsideHomeCard: some View {
        PremiumCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    PremiumIcon(systemName: "lock.shield.fill", tint: AppTheme.success)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text("外出阅读")
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(AppTheme.ink)
                            if store.pendingReaderSyncBookIDs.isEmpty {
                                SmallStatusChip(title: "本机可读", tint: AppTheme.success)
                            } else {
                                SmallStatusChip(title: "\(store.pendingReaderSyncBookIDs.count) 本待同步", tint: .orange)
                            }
                        }
                        Text("192.168.x.x 是家里内网地址，离开家里 Wi-Fi 后无法直连。已下载到本机书架的书可以继续读；回到家后会把可同步的阅读进度推回 Reader 服务。外出直连可改用 Tailscale、WireGuard、ZeroTier 或 HTTPS 域名。")
                            .font(.callout)
                            .foregroundStyle(AppTheme.mutedInk)
                            .fixedSize(horizontal: false, vertical: true)
                        if let lastSync = store.lastReaderServerSyncAt {
                            Text("上次同步：\(lastSync.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(AppTheme.ink.opacity(0.62))
                        }
                    }
                }

                if store.isReaderServerSyncing {
                    ProgressView()
                        .controlSize(.small)
                }

                HStack(spacing: 10) {
                    Button {
                        Task { await store.syncReaderServerShelfToLocal() }
                    } label: {
                        Label("同步 Reader 书架", systemImage: "books.vertical")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.accent)

                    Button {
                        Task { await store.syncLocalReadingStateWithReaderServer() }
                    } label: {
                        Label("同步本机进度", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .disabled(store.isReaderServerSyncing)

                Button {
                    store.cacheAllReadingBooksForOffline()
                } label: {
                    Label("外出包：缓存全部在读书籍", systemImage: "bag.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var connectionList: some View {
        VStack(alignment: .leading, spacing: 9) {
            PremiumSectionLabel(title: "最近连接")
            PremiumCard {
                VStack(spacing: 0) {
                    ForEach(Array(store.nasConnections.enumerated()), id: \.element.id) { index, connection in
                        NASConnectionRow(
                            connection: connection,
                            openAction: { selectedConnection = connection },
                            editAction: { editingConnection = connection },
                            deleteAction: { delete(connection) }
                        )
                        if index < store.nasConnections.count - 1 {
                            RowDivider()
                        }
                    }
                }
            }
        }
    }

    private var discoveredServices: some View {
        VStack(alignment: .leading, spacing: 9) {
            PremiumSectionLabel(title: "局域网发现")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(store.discoveredNASServices) { service in
                        Button {
                            store.addDiscoveredConnection(service)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "plus.circle.fill")
                                Text("\(service.name) · \(service.kind.title)")
                                    .lineLimit(1)
                            }
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(AppTheme.ink)
                            .padding(.horizontal, 12)
                            .frame(height: 38)
                            .background(AppTheme.surface, in: Capsule())
                            .overlay(Capsule().stroke(AppTheme.hairline, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func delete(_ connection: NASConnection) {
        store.deleteConnection(connection)
        if selectedConnection?.id == connection.id {
            selectedConnection = nil
        }
    }

    @ViewBuilder
    private func destination(for connection: NASConnection) -> some View {
        if connection.kind == .readerServer {
            ReaderServerView(connection: connection)
                .id(connection.id)
        } else {
            NASBrowserDetail(
                connection: connection,
                editAction: { editingConnection = connection },
                deleteAction: { delete(connection) }
            )
            .environmentObject(store)
            .id(connection.id)
        }
    }

    private func icon(for connection: NASConnection) -> String {
        connection.kind == .readerServer ? "books.vertical.fill" : "externaldrive.connected.to.line.below.fill"
    }

    private func statusTitle(for connection: NASConnection) -> String {
        if connection.kind == .readerServer { return "Web" }
        return connection.username.isEmpty ? "匿名" : "已登录"
    }

    private func statusTint(for connection: NASConnection) -> Color {
        if connection.kind == .readerServer { return AppTheme.success }
        return connection.username.isEmpty ? AppTheme.mutedInk : AppTheme.success
    }

    private func primaryActionTitle(for connection: NASConnection) -> String {
        connection.kind == .readerServer ? "打开阅读服务器" : "打开文件管理"
    }
}

struct NASConnectionRow: View {
    var connection: NASConnection
    var openAction: () -> Void
    var editAction: () -> Void
    var deleteAction: () -> Void

    var body: some View {
        PremiumRow {
            PremiumIcon(systemName: connection.kind == .readerServer ? "books.vertical.fill" : "server.rack", tint: AppTheme.accent)
        } content: {
            Button(action: openAction) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(connection.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.ink)
                            .lineLimit(1)
                        SmallStatusChip(title: connection.kind.title, tint: AppTheme.accent)
                    }
                    Text(connection.baseURL.absoluteString)
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedInk)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        } trailing: {
            Menu {
                Button(action: openAction) {
                    Label("打开", systemImage: connection.kind == .readerServer ? "safari" : "folder")
                }
                Button(action: editAction) {
                    Label("编辑", systemImage: "pencil")
                }
                Button(role: .destructive, action: deleteAction) {
                    Label("删除", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(AppTheme.mutedInk)
            }
            .buttonStyle(.plain)
        }
        .contextMenu {
            Button(action: openAction) {
                Label("打开", systemImage: connection.kind == .readerServer ? "safari" : "folder")
            }
            Button(action: editAction) {
                Label("编辑", systemImage: "pencil")
            }
            Button(role: .destructive, action: deleteAction) {
                Label("删除", systemImage: "trash")
            }
        }
    }
}

struct ReaderServerView: View {
    @EnvironmentObject private var store: AppStore
    var connection: NASConnection
    @StateObject private var webModel = ReaderServerWebModel()

    var body: some View {
        AppScreen {
            VStack(spacing: 12) {
                header
                ReaderServerWebContainer(model: webModel)
                    .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(AppTheme.hairline, lineWidth: 1)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(connection.name)
        .platformInlineNavigationTitle()
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    webModel.goBack()
                } label: {
                    Label("后退", systemImage: "chevron.left")
                }
                .disabled(!webModel.canGoBack)

                Button {
                    webModel.goForward()
                } label: {
                    Label("前进", systemImage: "chevron.right")
                }
                .disabled(!webModel.canGoForward)

                Button {
                    webModel.reload()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }

                Button {
                    openExternally(connection.baseURL)
                } label: {
                    Label("外部打开", systemImage: "safari")
                }
            }
        }
        .task(id: connection.id) {
            webModel.load(connection.baseURL)
            await store.syncLocalReadingStateWithReaderServerIfNeeded()
        }
    }

    private var header: some View {
        PremiumCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    PremiumIcon(systemName: "books.vertical.fill", tint: AppTheme.accent)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text(webModel.pageTitle.isEmpty ? connection.name : webModel.pageTitle)
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(AppTheme.ink)
                                .lineLimit(1)
                            SmallStatusChip(title: webModel.isLoading ? "载入中" : "Web", tint: webModel.isLoading ? .orange : AppTheme.success)
                        }
                        Text(connection.baseURL.absoluteString)
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedInk)
                            .lineLimit(1)
                    }
                    Spacer()
                }

                if store.isReaderServerSyncing {
                    ProgressView(value: 0.62)
                        .tint(AppTheme.accent)
                }

                Button {
                    Task { await store.syncReaderServerShelfToLocal() }
                } label: {
                    Label("同步 Reader 书架到本机", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(store.isReaderServerSyncing)
            }
        }
    }

    private func openExternally(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}

@MainActor
final class ReaderServerWebModel: NSObject, ObservableObject {
    let webView: WKWebView
    @Published var pageTitle = ""
    @Published var isLoading = false
    @Published var canGoBack = false
    @Published var canGoForward = false

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        #if os(iOS)
        webView.scrollView.keyboardDismissMode = .interactive
        webView.scrollView.backgroundColor = .clear
        #endif
    }

    func load(_ url: URL) {
        guard webView.url != url else {
            updateState()
            return
        }
        webView.load(URLRequest(url: url, timeoutInterval: 12))
        updateState()
    }

    func goBack() {
        guard webView.canGoBack else { return }
        webView.goBack()
        updateState()
    }

    func goForward() {
        guard webView.canGoForward else { return }
        webView.goForward()
        updateState()
    }

    func reload() {
        webView.reload()
        updateState()
    }

    private func updateState() {
        pageTitle = webView.title ?? pageTitle
        isLoading = webView.isLoading
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }
}

extension ReaderServerWebModel: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Task { @MainActor [weak self] in
            self?.isLoading = true
            self?.updateState()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        Task { @MainActor [weak self] in
            self?.updateState()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak self] in
            self?.updateState()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak self] in
            self?.updateState()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak self] in
            self?.updateState()
        }
    }
}

extension ReaderServerWebModel: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil,
              let url = navigationAction.request.url else {
            return nil
        }
        Task { @MainActor in
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}

#if os(macOS)
struct ReaderServerWebContainer: NSViewRepresentable {
    @ObservedObject var model: ReaderServerWebModel

    func makeNSView(context: Context) -> WKWebView {
        model.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#else
struct ReaderServerWebContainer: UIViewRepresentable {
    @ObservedObject var model: ReaderServerWebModel

    func makeUIView(context: Context) -> WKWebView {
        model.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif

struct NASBrowserDetail: View {
    @EnvironmentObject private var store: AppStore
    var connection: NASConnection
    var editAction: () -> Void
    var deleteAction: () -> Void

    @State private var currentURL: URL?
    @State private var history: [URL] = []
    @State private var newFolderName = ""
    @State private var showingNewFolder = false

    private var activeURL: URL {
        currentURL ?? connection.baseURL
    }

    var body: some View {
        AppScreen {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    browserHeader
                        .padding(.top, 18)

                    browserActions

                    if connection.kind == .webDAV {
                        NASFileList(
                            items: store.nasItems,
                            openAction: open,
                            importAction: { item in
                                Task { await store.importNASItem(item, from: connection) }
                            },
                            deleteAction: { item in
                                Task { await store.deleteNASItem(item, from: connection, refreshPath: activeURL) }
                            }
                        )
                    } else {
                        PremiumCard {
                            EmptyStateView(
                                systemImage: "externaldrive.trianglebadge.exclamationmark",
                                title: "\(connection.kind.title) 文件管理待接入",
                                subtitle: "连接配置已经保存。当前侧载版的浏览、导入、新建和删除先支持 WebDAV。"
                            )
                            .frame(minHeight: 320)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle(connection.name)
        .platformInlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(action: editAction) {
                        Label("编辑连接", systemImage: "pencil")
                    }
                    Button(role: .destructive, action: deleteAction) {
                        Label("删除连接", systemImage: "trash")
                    }
                } label: {
                    Label("更多", systemImage: "ellipsis.circle")
                }
            }
        }
        .alert("新建文件夹", isPresented: $showingNewFolder) {
            TextField("文件夹名称", text: $newFolderName)
            Button("取消", role: .cancel) {
                newFolderName = ""
            }
            Button("创建") {
                let name = newFolderName
                newFolderName = ""
                Task { await store.makeNASFolder(named: name, in: connection, parentURL: activeURL) }
            }
            .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .task(id: connection.id) {
            currentURL = connection.baseURL
            history.removeAll()
            if connection.kind == .webDAV {
                await store.browseNAS(connection, path: connection.baseURL)
            }
        }
    }

    private var browserHeader: some View {
        PremiumCard {
            HStack(alignment: .top, spacing: 12) {
                PremiumIcon(systemName: "folder.fill", tint: AppTheme.accent)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(connection.name)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(AppTheme.ink)
                        SmallStatusChip(title: connection.kind.title, tint: AppTheme.accent)
                    }
                    Text(activeURL.absoluteString)
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedInk)
                        .lineLimit(2)
                    Text(store.activityMessage.isEmpty ? "准备就绪" : store.activityMessage)
                        .font(.caption)
                        .foregroundStyle(AppTheme.ink.opacity(0.62))
                        .lineLimit(2)
                }
                Spacer()
            }
        }
    }

    private var browserActions: some View {
        HStack(spacing: 10) {
            Button {
                goBack()
            } label: {
                Label("上级", systemImage: "chevron.left")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(history.isEmpty || connection.kind != .webDAV)

            Button {
                showingNewFolder = true
            } label: {
                Label("新建", systemImage: "folder.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(connection.kind != .webDAV)

            Button {
                refresh()
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.accent)
            .disabled(connection.kind != .webDAV)
        }
        .font(.subheadline.weight(.medium))
    }

    private func open(_ item: NASItem) {
        guard item.isDirectory else { return }
        history.append(activeURL)
        currentURL = item.url
        Task { await store.browseNAS(connection, path: item.url) }
    }

    private func goBack() {
        guard let previous = history.popLast() else { return }
        currentURL = previous
        Task { await store.browseNAS(connection, path: previous) }
    }

    private func refresh() {
        Task { await store.browseNAS(connection, path: activeURL) }
    }
}

struct NASFileList: View {
    var items: [NASItem]
    var openAction: (NASItem) -> Void
    var importAction: (NASItem) -> Void
    var deleteAction: (NASItem) -> Void

    var body: some View {
        if items.isEmpty {
            PremiumCard {
                EmptyStateView(
                    systemImage: "folder",
                    title: "目录为空",
                    subtitle: "刷新目录，或在 NAS 上放入 TXT/EPUB 文件。"
                )
                .frame(minHeight: 320)
            }
        } else {
            LazyVStack(spacing: 10) {
                ForEach(items) { item in
                    NASItemRow(item: item) {
                        openAction(item)
                    } importAction: {
                        importAction(item)
                    } deleteAction: {
                        deleteAction(item)
                    }
                }
            }
        }
    }
}

struct NASItemRow: View {
    var item: NASItem
    var openAction: () -> Void
    var importAction: () -> Void
    var deleteAction: () -> Void

    var body: some View {
        PremiumCard {
            HStack(spacing: 12) {
                PremiumIcon(systemName: item.isDirectory ? "folder.fill" : "doc.text.fill", tint: item.isDirectory ? AppTheme.accent : AppTheme.mutedInk)

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(AppTheme.ink)
                        .lineLimit(1)
                    Text(metadata)
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedInk)
                        .lineLimit(1)
                }

                Spacer()

                Button(action: item.isDirectory ? openAction : importAction) {
                    Label(item.isDirectory ? "进入" : "导入", systemImage: item.isDirectory ? "chevron.right" : "square.and.arrow.down")
                        .labelStyle(.iconOnly)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.bordered)

                Menu {
                    if item.isDirectory {
                        Button(action: openAction) {
                            Label("进入", systemImage: "folder")
                        }
                    } else {
                        Button(action: importAction) {
                            Label("导入书架", systemImage: "square.and.arrow.down")
                        }
                    }
                    Button(role: .destructive, action: deleteAction) {
                        Label("从 NAS 删除", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(AppTheme.mutedInk)
                }
                .buttonStyle(.plain)
            }
        }
        .contextMenu {
            if item.isDirectory {
                Button(action: openAction) {
                    Label("进入", systemImage: "folder")
                }
            } else {
                Button(action: importAction) {
                    Label("导入书架", systemImage: "square.and.arrow.down")
                }
            }
            Button(role: .destructive, action: deleteAction) {
                Label("从 NAS 删除", systemImage: "trash")
            }
        }
    }

    private var metadata: String {
        if item.isDirectory {
            return item.url.absoluteString
        }
        let sizeText = item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "未知大小"
        if let modifiedAt = item.modifiedAt {
            return "\(sizeText) · \(modifiedAt.formatted(date: .abbreviated, time: .shortened))"
        }
        return sizeText
    }
}

struct NASConnectionEditorView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    private let editingConnection: NASConnection?
    @State private var name: String
    @State private var kind: NASKind
    @State private var host: String
    @State private var port: String
    @State private var path: String
    @State private var username: String
    @State private var password: String
    @State private var usesHTTPS: Bool
    @State private var usesFullURL: Bool
    @State private var fullURL: String

    init(connection: NASConnection? = nil) {
        editingConnection = connection
        let parsed = Self.parse(connection)
        _name = State(initialValue: connection?.name ?? "")
        _kind = State(initialValue: connection?.kind ?? .readerServer)
        _host = State(initialValue: parsed.host)
        _port = State(initialValue: parsed.port)
        _path = State(initialValue: parsed.path)
        _username = State(initialValue: connection?.username ?? "")
        _password = State(initialValue: connection?.password ?? "")
        _usesHTTPS = State(initialValue: parsed.usesHTTPS)
        _usesFullURL = State(initialValue: false)
        _fullURL = State(initialValue: connection?.baseURL.absoluteString ?? "")
    }

    private var resolvedURL: URL? {
        if usesFullURL {
            return URL(string: fullURL.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHost.isEmpty else { return nil }
        let scheme: String
        switch kind {
        case .readerServer:
            scheme = usesHTTPS ? "https" : "http"
        case .webDAV:
            scheme = usesHTTPS ? "https" : "http"
        case .smb:
            scheme = "smb"
        case .sftp:
            scheme = "sftp"
        }

        var components = URLComponents()
        components.scheme = scheme
        components.host = cleanHost
        if let portNumber = Int(port.trimmingCharacters(in: .whitespacesAndNewlines)) {
            components.port = portNumber
        }
        components.path = normalizedPath
        return components.url
    }

    private var normalizedPath: String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "/" }
        return trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("连接") {
                    TextField("名称", text: $name, prompt: Text("家里阅读服务器"))
                    Picker("协议", selection: $kind) {
                        ForEach(NASKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    Toggle("使用完整 URL", isOn: $usesFullURL)
                }

                if usesFullURL {
                    Section("完整地址") {
                        TextField("URL", text: $fullURL, prompt: Text("http://192.168.31.205:4396/"))
                            .textContentType(.URL)
                            #if os(iOS)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                    }
                } else {
                    Section("地址") {
                        TextField("IP 或域名", text: $host, prompt: Text("192.168.1.10"))
                            #if os(iOS)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                        TextField("端口", text: $port, prompt: Text(defaultPortText))
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                        TextField("目录", text: $path, prompt: Text(pathPrompt))
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                        if kind == .webDAV || kind == .readerServer {
                            Toggle("HTTPS", isOn: $usesHTTPS)
                        }
                    }
                }

                Section("账号") {
                    TextField("用户名", text: $username)
                        .textContentType(.username)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                    SecureField("密码", text: $password)
                        .textContentType(.password)
                }

                Section {
                    Text(previewURLText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if kind == .readerServer {
                        Label("会在 App 内打开 Reader Web。外出访问请把地址改成 VPN、Tailscale 或 HTTPS 域名。", systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if kind != .webDAV {
                        Label("当前文件管理器先支持 WebDAV。SMB/SFTP 会保存连接配置，后续接入原生协议库后可直接复用。", systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(editingConnection == nil ? "新增 NAS" : "编辑 NAS")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        save()
                    }
                    .disabled(resolvedURL == nil)
                }
            }
            #if os(macOS)
            .frame(width: 520, height: 600)
            #endif
        }
        .onChange(of: kind) { _, newKind in
            applyDefaults(for: newKind)
        }
    }

    private var defaultPortText: String {
        switch kind {
        case .readerServer: "4396"
        case .webDAV: usesHTTPS ? "5006" : "5005"
        case .smb: "445"
        case .sftp: "22"
        }
    }

    private var pathPrompt: String {
        switch kind {
        case .readerServer: "/"
        case .webDAV: "/books/"
        case .smb, .sftp: "/"
        }
    }

    private var previewURLText: String {
        resolvedURL?.absoluteString ?? "请填写有效地址"
    }

    private func save() {
        guard let url = resolvedURL else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let connection = NASConnection(
            id: editingConnection?.id ?? UUID(),
            name: trimmedName.isEmpty ? defaultName(for: url) : trimmedName,
            kind: kind,
            baseURL: url,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password,
            isEnabled: true
        )
        if editingConnection == nil {
            store.addConnection(connection)
        } else {
            store.updateConnection(connection)
        }
        dismiss()
    }

    private func defaultName(for url: URL) -> String {
        if kind == .readerServer {
            return url.host.map { "Reader \($0)" } ?? "家里阅读服务器"
        }
        return url.host.map { "NAS \($0)" } ?? kind.title
    }

    private func applyDefaults(for kind: NASKind) {
        switch kind {
        case .readerServer:
            if port.isEmpty || port == "5005" || port == "5006" || port == "445" || port == "22" {
                port = "4396"
            }
            if path.isEmpty || path == "/books/" {
                path = "/"
            }
            usesHTTPS = false
        case .webDAV:
            if port.isEmpty || port == "4396" || port == "445" || port == "22" {
                port = usesHTTPS ? "5006" : "5005"
            }
            if path.isEmpty || path == "/" {
                path = "/books/"
            }
        case .smb:
            if port.isEmpty || port == "4396" || port == "5005" || port == "5006" || port == "22" {
                port = "445"
            }
            if path.isEmpty { path = "/" }
        case .sftp:
            if port.isEmpty || port == "4396" || port == "5005" || port == "5006" || port == "445" {
                port = "22"
            }
            if path.isEmpty { path = "/" }
        }
    }

    private static func parse(_ connection: NASConnection?) -> (host: String, port: String, path: String, usesHTTPS: Bool) {
        guard let url = connection?.baseURL else {
            return ("192.168.31.205", "4396", "/", false)
        }
        let port = url.port.map(String.init) ?? ""
        return (
            url.host ?? "",
            port,
            url.path.isEmpty ? "/" : url.path,
            url.scheme == "https"
        )
    }
}
