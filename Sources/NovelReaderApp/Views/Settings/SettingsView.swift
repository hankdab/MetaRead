import SwiftUI
import CoreText
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var isBackupImporterPresented = false
    @State private var isBackupExporterPresented = false
    @State private var backupDocument = LibraryBackupDocument(data: Data())
    @State private var autoSyncOnWiFi = true
    @State private var syncReadingProgress = true
    @State private var keepDownloadsInBackground = true

    private var enabledSourceCount: Int {
        store.sources.filter(\.isEnabled).count
    }

    private var fontLabel: String {
        if let custom = store.readerTheme.customFontName, !custom.isEmpty {
            let font = CTFontCreateWithName(custom as CFString, 12, nil)
            let full = CTFontCopyFullName(font) as String
            return full.isEmpty ? custom : full
        }
        return store.readerTheme.fontDesign.title
    }

    private var primaryConnection: NASConnection? {
        store.nasConnections.first
    }

    var body: some View {
        NavigationStack {
            AppScreen {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        PageHeader(title: "设置", subtitle: store.activityMessage.isEmpty ? "准备就绪" : store.activityMessage)
                            .padding(.top, 18)

                        serviceSummary
                        sourceSummary
                        readingStyleCard
                        syncCard
                        backupCard

                        if let connection = primaryConnection {
                            Button(role: .destructive) {
                                store.deleteConnection(connection)
                            } label: {
                                Label("断开 \(connection.name)", systemImage: "xmark.circle")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 28)
                }
            }
            .platformInlineNavigationTitle()
            .fileImporter(isPresented: $isBackupImporterPresented, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                guard url.startAccessingSecurityScopedResource() else { return }
                defer { url.stopAccessingSecurityScopedResource() }
                if let data = try? Data(contentsOf: url) {
                    store.importLibraryBackup(data)
                }
            }
            .fileExporter(isPresented: $isBackupExporterPresented, document: backupDocument, contentType: .json, defaultFilename: "MetaReadBackup") { result in
                if case .failure(let error) = result {
                    store.activityMessage = "导出失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private var serviceSummary: some View {
        PremiumCard {
            PremiumRow {
                PremiumIcon(systemName: "externaldrive.connected.to.line.below.fill", tint: AppTheme.accent)
            } content: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(primaryConnection?.name ?? "未连接阅读服务")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(AppTheme.ink)
                    Text(primaryConnection?.baseURL.absoluteString ?? "在 NAS 页填写 IP、目录和账号密码。")
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedInk)
                        .lineLimit(2)
                }
            } trailing: {
                SmallStatusChip(title: primaryConnection?.username.isEmpty == false ? "已登录" : "未登录", tint: primaryConnection == nil ? AppTheme.mutedInk : AppTheme.success)
            }
        }
    }

    private var sourceSummary: some View {
        VStack(alignment: .leading, spacing: 9) {
            PremiumSectionLabel(title: "书源")
            NavigationLink {
                BookSourceManagementView()
                    .environmentObject(store)
            } label: {
                PremiumCard {
                    PremiumRow {
                        PremiumIcon(systemName: "books.vertical.fill", tint: AppTheme.accent)
                    } content: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("书源管理")
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(AppTheme.ink)
                            Text("导入、启用、编辑或删除书源")
                                .font(.caption)
                                .foregroundStyle(AppTheme.mutedInk)
                        }
                    } trailing: {
                        HStack(spacing: 8) {
                            SmallStatusChip(title: "\(enabledSourceCount)/\(store.sources.count)", tint: AppTheme.accent)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(AppTheme.mutedInk)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var readingStyleCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            PremiumSectionLabel(title: "阅读")
            PremiumCard {
                VStack(spacing: 12) {
                    NavigationLink {
                        FontPickerView()
                            .environmentObject(store)
                    } label: {
                        HStack(spacing: 12) {
                            Text("字体")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(AppTheme.ink)
                                .frame(width: 44, alignment: .leading)
                            Spacer()
                            Text(fontLabel)
                                .font(.subheadline)
                                .foregroundStyle(AppTheme.mutedInk)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.mutedInk)
                        }
                    }
                    .buttonStyle(.plain)
                    RowDivider()
                    sliderRow(title: "字号", value: $store.readerTheme.fontSize, range: 14...30, step: 1)
                    RowDivider()
                    sliderRow(title: "行距", value: $store.readerTheme.lineSpacing, range: 2...18, step: 1)
                    RowDivider()
                    sliderRow(
                        title: "字距",
                        value: $store.readerTheme.effectiveCharacterSpacing,
                        range: 0...4,
                        step: 0.5,
                        valueText: { $0.formatted(.number.precision(.fractionLength(1))) }
                    )
                    RowDivider()
                    sliderRow(
                        title: "首行",
                        value: $store.readerTheme.effectiveFirstLineIndent,
                        range: 0...4,
                        step: 0.5,
                        valueText: { "\($0.formatted(.number.precision(.fractionLength(1))))字" }
                    )
                    RowDivider()
                    sliderRow(title: "段距", value: $store.readerTheme.paragraphSpacing, range: 4...28, step: 1)
                    RowDivider()
                    Toggle("加粗正文", isOn: $store.readerTheme.isBold)
                        .tint(AppTheme.accent)
                        .font(.subheadline.weight(.medium))
                        .onChange(of: store.readerTheme.isBold) { _, _ in store.save() }
                }
            }
        }
    }

    private var syncCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            PremiumSectionLabel(title: "同步与下载")
            PremiumCard {
                VStack(spacing: 0) {
                    toggleRow(title: "Wi-Fi 自动同步", icon: "wifi", isOn: $autoSyncOnWiFi)
                    RowDivider()
                    toggleRow(title: "同步阅读进度", icon: "icloud", isOn: $syncReadingProgress)
                    RowDivider()
                    toggleRow(title: "后台下载恢复", icon: "arrow.clockwise.icloud", isOn: $keepDownloadsInBackground)
                    RowDivider()
                    HStack(spacing: 10) {
                        Button {
                            Task { await store.pushCloudSync() }
                        } label: {
                            Label("上传", systemImage: "icloud.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        Button {
                            Task { await store.pullCloudSync() }
                        } label: {
                            Label("恢复", systemImage: "icloud.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.accent)
                    }
                    .padding(.top, 12)
                }
            }
        }
    }

    private var backupCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            PremiumSectionLabel(title: "备份")
            PremiumCard {
                VStack(spacing: 0) {
                    settingsActionRow(title: "导出书库备份", subtitle: "保存书架、书源和阅读状态", icon: "square.and.arrow.up") {
                        backupDocument = LibraryBackupDocument(data: store.exportLibraryBackup() ?? Data())
                        isBackupExporterPresented = true
                    }
                    RowDivider()
                    settingsActionRow(title: "恢复书库备份", subtitle: "从 JSON 备份恢复", icon: "arrow.counterclockwise") {
                        isBackupImporterPresented = true
                    }
                    RowDivider()
                    settingsActionRow(title: "保存当前配置", subtitle: "立即写入本地数据库", icon: "checkmark.seal") {
                        store.save()
                    }
                }
            }
        }
    }

    private func sliderRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        valueText: @escaping (Double) -> String = { Int($0).formatted() }
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.ink)
                .frame(width: 44, alignment: .leading)
            Slider(value: value, in: range, step: step, onEditingChanged: { isEditing in
                if !isEditing { store.save() }
            })
            .tint(AppTheme.accent)
            Text(valueText(value.wrappedValue))
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(AppTheme.mutedInk)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }

    private func toggleRow(title: String, icon: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            PremiumIcon(systemName: icon, tint: AppTheme.accent)
            Toggle(title, isOn: isOn)
                .tint(AppTheme.accent)
                .font(.subheadline.weight(.medium))
        }
        .padding(.vertical, 8)
    }

    private func settingsActionRow(title: String, subtitle: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            PremiumRow {
                PremiumIcon(systemName: icon, tint: AppTheme.accent)
            } content: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.ink)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedInk)
                }
            } trailing: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppTheme.mutedInk)
            }
        }
        .buttonStyle(.plain)
    }
}

struct BookSourceManagementView: View {
    @EnvironmentObject private var store: AppStore
    @State private var isSourceImporterPresented = false
    @State private var sourceEditor: BookSourceEditorPresentation?
    @State private var showingDeleteAllConfirmation = false
    @State private var sourcePendingDeletion: BookSource?
    @State private var remoteSourceURL = ""

    var body: some View {
        Form {
            Section("概览") {
                HStack {
                    Label("启用书源", systemImage: "checkmark.circle")
                    Spacer()
                    Text("\(store.sources.filter(\.isEnabled).count)/\(store.sources.count)")
                        .foregroundStyle(.secondary)
                }
                Button {
                    store.enableOnlyBuiltInBookSources()
                } label: {
                    Label("仅启用推荐书源", systemImage: "speedometer")
                }
                Button(role: .destructive) {
                    store.setAllSourcesEnabled(false)
                } label: {
                    Label("停用全部书源", systemImage: "pause.circle")
                }
                Button(role: .destructive) {
                    showingDeleteAllConfirmation = true
                } label: {
                    Label("删除全部书源", systemImage: "trash")
                }
                .disabled(store.sources.isEmpty)
            }

            Section("操作") {
                Button {
                    store.installBuiltInBookSources()
                } label: {
                    Label("推荐书源", systemImage: "sparkles")
                }
                Button {
                    sourceEditor = .add
                } label: {
                    Label("新增", systemImage: "plus")
                }
                Button {
                    isSourceImporterPresented = true
                } label: {
                    Label("导入 JSON/Legado", systemImage: "square.and.arrow.down")
                }
            }

            Section("远程书源") {
                HStack {
                    TextField("https://...", text: $remoteSourceURL)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                    Button {
                        let value = remoteSourceURL
                        Task {
                            await store.importBookSourceURL(value)
                            remoteSourceURL = ""
                        }
                    } label: {
                        Label("导入", systemImage: "link.badge.plus")
                    }
                    .disabled(remoteSourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .buttonStyle(.borderless)
                }

                ForEach(RemoteBookSourcePacks.all) { pack in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(pack.name)
                            Text(pack.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            Task { await store.importBookSourceURL(pack.url.absoluteString) }
                        } label: {
                            Label("导入", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            Section("已安装书源") {
                ForEach($store.sources) { $source in
                    HStack(spacing: 12) {
                        Toggle(isOn: $source.isEnabled) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(source.name)
                                Text(source.baseURL.host ?? source.baseURL.absoluteString)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .onChange(of: source.isEnabled) { _, _ in
                            store.save()
                        }

                        Menu {
                            Button {
                                sourceEditor = .edit(source)
                            } label: {
                                Label("编辑", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                sourcePendingDeletion = source
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.borderless)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            sourcePendingDeletion = source
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                        Button {
                            sourceEditor = .edit(source)
                        } label: {
                            Label("编辑", systemImage: "pencil")
                        }
                        .tint(AppTheme.accent)
                    }
                }
            }
        }
        .navigationTitle("书源管理")
        .fileImporter(isPresented: $isSourceImporterPresented, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }
            if let data = try? Data(contentsOf: url) {
                store.importBookSourceJSON(data)
            }
        }
        .sheet(item: $sourceEditor) { presentation in
            switch presentation {
            case .add:
                BookSourceEditorView()
                    .environmentObject(store)
            case .edit(let source):
                BookSourceEditorView(source: source)
                    .environmentObject(store)
            }
        }
        .confirmationDialog("删除全部书源？", isPresented: $showingDeleteAllConfirmation, titleVisibility: .visible) {
            Button("删除全部书源", role: .destructive) {
                store.deleteAllBookSources()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后需要重新导入，或重新添加推荐书源。")
        }
        .confirmationDialog(
            "删除书源？",
            isPresented: Binding(
                get: { sourcePendingDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        sourcePendingDeletion = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            if let source = sourcePendingDeletion {
                Button("删除 \(source.name)", role: .destructive) {
                    store.deleteBookSource(source)
                    sourcePendingDeletion = nil
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后不会影响已经加入书架的书籍。")
        }
    }
}

private enum BookSourceEditorPresentation: Identifiable {
    case add
    case edit(BookSource)

    var id: String {
        switch self {
        case .add:
            "add"
        case .edit(let source):
            "edit-\(source.id.uuidString)"
        }
    }
}

struct LibraryBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct BookSourceEditorView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    private let editingSource: BookSource?
    @State private var name: String
    @State private var baseURL: String
    @State private var isEnabled: Bool
    @State private var searchPath: String
    @State private var resultListSelector: String
    @State private var titleSelector: String
    @State private var authorSelector: String
    @State private var bookURLSelector: String
    @State private var tocListSelector: String
    @State private var chapterTitleSelector: String
    @State private var chapterURLSelector: String
    @State private var contentSelector: String
    @State private var replacements: [ReplacementRule]

    init(source: BookSource? = nil) {
        editingSource = source
        _name = State(initialValue: source?.name ?? "")
        _baseURL = State(initialValue: source?.baseURL.absoluteString ?? "")
        _isEnabled = State(initialValue: source?.isEnabled ?? true)
        _searchPath = State(initialValue: source?.rule.searchPath ?? "/search?q={{keyword}}")
        _resultListSelector = State(initialValue: source?.rule.resultListSelector ?? ".result")
        _titleSelector = State(initialValue: source?.rule.titleSelector ?? ".title@text")
        _authorSelector = State(initialValue: source?.rule.authorSelector ?? ".author@text")
        _bookURLSelector = State(initialValue: source?.rule.bookURLSelector ?? ".title@href")
        _tocListSelector = State(initialValue: source?.rule.tocListSelector ?? ".chapter-list a")
        _chapterTitleSelector = State(initialValue: source?.rule.chapterTitleSelector ?? "@text")
        _chapterURLSelector = State(initialValue: source?.rule.chapterURLSelector ?? "@href")
        _contentSelector = State(initialValue: source?.rule.contentSelector ?? "#content@html")
        _replacements = State(initialValue: source?.rule.replacements ?? [])
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("名称", text: $name)
                    TextField("站点地址", text: $baseURL)
                    Toggle("启用书源", isOn: $isEnabled)
                }
                Section("搜索") {
                    TextField("搜索路径", text: $searchPath)
                    TextField("结果列表", text: $resultListSelector)
                    TextField("标题", text: $titleSelector)
                    TextField("作者", text: $authorSelector)
                    TextField("书籍链接", text: $bookURLSelector)
                }
                Section("目录与正文") {
                    TextField("目录列表", text: $tocListSelector)
                    TextField("章节标题", text: $chapterTitleSelector)
                    TextField("章节链接", text: $chapterURLSelector)
                    TextField("正文", text: $contentSelector)
                }
            }
            .navigationTitle(editingSource == nil ? "新增书源" : "编辑书源")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard let url = URL(string: trimmedBaseURL), !trimmedName.isEmpty else { return }
                        var source = BookSource(
                            name: trimmedName,
                            baseURL: url,
                            isEnabled: isEnabled,
                            rule: SourceRule(
                                searchPath: searchPath,
                                resultListSelector: resultListSelector,
                                titleSelector: titleSelector,
                                authorSelector: authorSelector,
                                bookURLSelector: bookURLSelector,
                                tocListSelector: tocListSelector,
                                chapterTitleSelector: chapterTitleSelector,
                                chapterURLSelector: chapterURLSelector,
                                contentSelector: contentSelector,
                                replacements: replacements
                            )
                        )
                        if let editingSource {
                            source.id = editingSource.id
                        }
                        store.saveBookSource(source)
                        dismiss()
                    }
                }
            }
            .padding()
            #if os(macOS)
            .frame(width: 620, height: 620)
            #endif
        }
    }
}
