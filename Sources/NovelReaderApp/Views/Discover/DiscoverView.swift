import SwiftUI

struct DiscoverView: View {
    @EnvironmentObject private var store: AppStore
    @State private var keyword = ""
    @FocusState private var isKeywordFocused: Bool

    private var enabledSourceCount: Int {
        store.sources.filter(\.isEnabled).count
    }

    var body: some View {
        NavigationStack {
            AppScreen {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        header
                            .padding(.top, 18)

                        searchCard

                        if store.isSourceSearching {
                            SearchProgressCard(
                                progress: store.sourceSearchProgress,
                                message: store.activityMessage,
                                sourceCount: enabledSourceCount,
                                resultCount: store.searchResults.count
                            )
                        }

                        if store.searchResults.isEmpty && !store.isSourceSearching {
                            PremiumCard {
                                EmptyStateView(
                                    systemImage: "sparkle.magnifyingglass",
                                    title: "搜索一本小说",
                                    subtitle: enabledSourceCount == 0 ? "先导入或启用书源，再搜索书名、作者或关键词。" : "会并发搜索已启用书源，结果会逐条出现。"
                                )
                                .frame(minHeight: 360)
                            }
                        } else if !store.searchResults.isEmpty {
                            PremiumSectionLabel(title: "搜索结果")
                            ForEach(store.searchResults) { result in
                                SearchResultRow(result: result)
                                    .environmentObject(store)
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 28)
                }
                #if os(iOS)
                .scrollDismissesKeyboard(.interactively)
                #endif
                .contentShape(Rectangle())
                .simultaneousGesture(
                    DragGesture(minimumDistance: 18)
                        .onChanged { _ in dismissKeyboard() }
                )
            }
            .platformInlineNavigationTitle()
            .toolbar {
                #if os(iOS)
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") {
                        dismissKeyboard()
                    }
                }
                #endif
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                Text("发现")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(AppTheme.ink)
                Text(enabledSourceCount == 0 ? "没有启用的书源" : "已启用 \(enabledSourceCount) 个书源")
                    .font(.callout)
                    .foregroundStyle(AppTheme.mutedInk)
            }
            Spacer()
            NavigationLink {
                BookSourceManagementView()
                    .environmentObject(store)
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AppTheme.ink)
                    .frame(width: 44, height: 44)
                    .background(AppTheme.elevatedSurface, in: Circle())
                    .overlay(Circle().stroke(AppTheme.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("书源管理")
        }
    }

    private var searchCard: some View {
        PremiumCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AppTheme.mutedInk)
                    TextField("搜索书名、作者或关键词", text: $keyword)
                        .textFieldStyle(.plain)
                        .submitLabel(.search)
                        .focused($isKeywordFocused)
                        .onSubmit { performSearch() }
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    if !keyword.isEmpty {
                        Button {
                            keyword = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(Color.black.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                HStack(spacing: 10) {
                    SmallStatusChip(title: "\(store.searchResults.count) 条结果", tint: AppTheme.accent)
                    SmallStatusChip(title: store.isSourceSearching ? "搜索中" : "准备就绪", tint: store.isSourceSearching ? .orange : AppTheme.success)
                    Spacer()
                    Button {
                        if store.isSourceSearching {
                            store.cancelSourceSearch()
                            dismissKeyboard()
                        } else {
                            performSearch()
                        }
                    } label: {
                        Label(store.isSourceSearching ? "停止" : "搜索", systemImage: store.isSourceSearching ? "xmark" : "arrow.right")
                            .labelStyle(.titleAndIcon)
                            .font(.subheadline.weight(.semibold))
                            .frame(minWidth: 92)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(store.isSourceSearching ? AppTheme.destructive : AppTheme.accent)
                    .disabled(!store.isSourceSearching && keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func performSearch() {
        dismissKeyboard()
        store.startSearch(keyword: keyword)
    }

    private func dismissKeyboard() {
        isKeywordFocused = false
    }
}

struct SearchResultRow: View {
    @EnvironmentObject private var store: AppStore
    var result: SearchResult

    var body: some View {
        let downloadTask = store.downloadTask(for: result)
        let isActiveDownload = downloadTask.map { $0.state == .running || $0.state == .queued || $0.state == .paused } ?? false

        PremiumCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    PremiumIcon(systemName: "book.closed.fill", tint: AppTheme.accent)

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(result.title)
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(AppTheme.ink)
                                .lineLimit(2)
                            Spacer(minLength: 8)
                            SmallStatusChip(title: result.sourceName, tint: AppTheme.accent)
                        }
                        Text(result.author.isEmpty ? "作者未知" : result.author)
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.mutedInk)
                            .lineLimit(1)
                        if !result.summary.isEmpty {
                            Text(result.summary)
                                .font(.callout)
                                .foregroundStyle(AppTheme.ink.opacity(0.68))
                                .lineLimit(2)
                        }
                    }
                }

                if let downloadTask {
                    VStack(alignment: .leading, spacing: 7) {
                        ProgressView(value: downloadTask.progress)
                            .tint(downloadTask.state.tint)
                            .animation(.easeInOut(duration: 0.25), value: downloadTask.progress)
                        HStack {
                            Text(downloadTask.message)
                                .lineLimit(1)
                            Spacer()
                            Text(downloadTask.progress.formatted(.percent.precision(.fractionLength(0))))
                                .monospacedDigit()
                        }
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedInk)
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        store.addSearchResultToShelf(result)
                    } label: {
                        Label("加入书架", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        Task { await store.downloadSearchResult(result) }
                    } label: {
                        Label(isActiveDownload ? "下载中" : "下载", systemImage: isActiveDownload ? "arrow.down.circle.fill" : "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.accent)
                    .disabled(isActiveDownload)
                }
                .labelStyle(.titleAndIcon)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: downloadTask?.progress)
        .animation(.easeInOut(duration: 0.25), value: downloadTask?.state)
    }
}

private struct SearchProgressCard: View {
    var progress: Double
    var message: String
    var sourceCount: Int
    var resultCount: Int

    var body: some View {
        PremiumCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    PremiumIcon(systemName: "bolt.horizontal.circle.fill", tint: AppTheme.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("正在搜索书源")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(AppTheme.ink)
                        Text("已找到 \(resultCount) 条结果")
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedInk)
                    }
                    Spacer()
                    Text(progress.formatted(.percent.precision(.fractionLength(0))))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(AppTheme.mutedInk)
                }

                ProgressView(value: progress)
                    .tint(AppTheme.accent)
                    .animation(.easeInOut(duration: 0.25), value: progress)

                Text(sourceCount == 0 ? "没有启用的书源" : message)
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedInk)
                    .lineLimit(2)
            }
        }
    }
}
