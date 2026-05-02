import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject private var store: AppStore

    private var runningCount: Int {
        store.downloads.filter { $0.state == .running }.count
    }

    private var failedCount: Int {
        store.downloads.filter { $0.state == .failed }.count
    }

    var body: some View {
        NavigationStack {
            AppScreen {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        PageHeader(title: "下载", subtitle: store.downloads.isEmpty ? "没有下载任务" : "共 \(store.downloads.count) 个任务")
                            .padding(.top, 18)

                        HStack(spacing: 10) {
                            StatTile(title: "全部任务", value: store.downloads.count.formatted(), systemImage: "tray.full.fill", tint: AppTheme.accent)
                            StatTile(title: "进行中", value: runningCount.formatted(), systemImage: "arrow.down.circle.fill", tint: .orange)
                            StatTile(title: "失败", value: failedCount.formatted(), systemImage: "exclamationmark.triangle.fill", tint: AppTheme.destructive)
                        }

                        if store.downloads.isEmpty {
                            PremiumCard {
                                EmptyStateView(systemImage: "arrow.down.circle", title: "没有下载任务", subtitle: "从书源加入书籍或从 NAS 缓存文件后，任务会显示在这里。")
                                    .frame(minHeight: 360)
                            }
                        } else {
                            LazyVStack(spacing: 10) {
                                ForEach(store.downloads) { task in
                                    DownloadTaskRow(task: task)
                                        .environmentObject(store)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 28)
                }
            }
            .platformInlineNavigationTitle()
            .toolbar {
                ToolbarItemGroup {
                    Button {
                        store.startQueuedDownloads()
                    } label: {
                        Label("开始", systemImage: "play.fill")
                    }

                    Button {
                        store.clearFinishedDownloads()
                    } label: {
                        Label("清理", systemImage: "checkmark.circle")
                    }
                }
            }
        }
    }
}

struct DownloadTaskRow: View {
    @EnvironmentObject private var store: AppStore
    var task: DownloadTaskItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                PremiumIcon(systemName: icon, tint: task.state.tint)

                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(task.title)
                            .font(.headline)
                            .lineLimit(1)
                        Spacer()
                        StatusBadge(title: task.state.title, color: task.state.tint)
                    }
                    Text("\(task.sourceName) · \(task.message)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        StatusBadge(title: task.kind.title, color: .indigo)
                        if let chapterIndex = task.chapterIndex {
                            StatusBadge(title: "第 \(chapterIndex + 1) 章", color: .blue)
                        }
                    }
                }
            }

            ProgressView(value: task.progress)
                .tint(task.state.tint)
                .animation(.easeInOut(duration: 0.25), value: task.progress)

            HStack {
                switch task.state {
                case .running:
                    Button {
                        store.pauseDownload(task)
                    } label: {
                        Label("暂停", systemImage: "pause.fill")
                    }
                case .paused, .queued:
                    Button {
                        store.resumeDownload(task)
                    } label: {
                        Label("继续", systemImage: "play.fill")
                    }
                case .failed:
                    Button {
                        store.retryDownload(task)
                    } label: {
                        Label("重试", systemImage: "arrow.clockwise")
                    }
                case .finished:
                    Label("完成", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Spacer()
                Text(task.progress.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .padding(14)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.035), radius: 16, x: 0, y: 8)
        .animation(.easeInOut(duration: 0.25), value: task.state)
        .animation(.easeInOut(duration: 0.25), value: task.progress)
    }

    private var icon: String {
        switch task.state {
        case .queued: "clock.fill"
        case .running: "arrow.down.circle.fill"
        case .paused: "pause.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .finished: "checkmark.circle.fill"
        }
    }
}
