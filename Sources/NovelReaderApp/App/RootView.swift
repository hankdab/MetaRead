import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case shelf
    case discover
    case nas
    case downloads
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shelf:     "书架"
        case .discover:  "发现"
        case .nas:       "服务"
        case .downloads: "下载"
        case .settings:  "设置"
        }
    }

    var icon: String {
        switch self {
        case .shelf:     "books.vertical"
        case .discover:  "magnifyingglass"
        case .nas:       "externaldrive.connected.to.line.below"
        case .downloads: "arrow.down.circle"
        case .settings:  "gearshape"
        }
    }
}

// MARK: - Root

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @State private var isShowingStartupOverlay = true

    var body: some View {
        ZStack {
            #if os(macOS)
            macOSLayout()
            #else
            iOSLayout()
            #endif
        }
        .task { await dismissStartup() }
        .overlay {
            if isShowingStartupOverlay {
                StartupLoadingView()
                    .transition(.opacity)
                    .ignoresSafeArea()
            }
        }
        .sheet(isPresented: $store.showServerSetup) {
            ServerSetupGuideView()
                .environmentObject(store)
                .interactiveDismissDisabled(store.needsServerSetup)
        }
    }

    @MainActor
    private func dismissStartup() async {
        // wait at most 60 ms for the library to finish loading, then show immediately
        let deadline = Date().addingTimeInterval(0.06)
        while store.isLibraryLoading && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        withAnimation(.easeOut(duration: 0.12)) {
            isShowingStartupOverlay = false
        }
    }
}

// MARK: - iOS layout (tab bar)

#if !os(macOS)
private struct iOSLayout: View {
    @EnvironmentObject private var store: AppStore
    @State private var selection: AppSection = .shelf

    var body: some View {
        TabView(selection: $selection) {
            ShelfView()
                .environmentObject(store)
                .tabItem { Label(AppSection.shelf.title,     systemImage: AppSection.shelf.icon) }
                .tag(AppSection.shelf)

            DiscoverView()
                .environmentObject(store)
                .tabItem { Label(AppSection.discover.title,  systemImage: AppSection.discover.icon) }
                .tag(AppSection.discover)

            NASView()
                .environmentObject(store)
                .tabItem { Label(AppSection.nas.title,       systemImage: AppSection.nas.icon) }
                .tag(AppSection.nas)

            DownloadsView()
                .environmentObject(store)
                .tabItem { Label(AppSection.downloads.title, systemImage: AppSection.downloads.icon) }
                .tag(AppSection.downloads)

            SettingsView()
                .environmentObject(store)
                .tabItem { Label(AppSection.settings.title,  systemImage: AppSection.settings.icon) }
                .tag(AppSection.settings)
        }
        .tint(AppTheme.accent)
    }
}
#endif

// MARK: - macOS layout (sidebar)

#if os(macOS)
private struct macOSLayout: View {
    @EnvironmentObject private var store: AppStore
    @State private var selection: AppSection? = .shelf

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.icon)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
            .navigationTitle("元阅")
        } detail: {
            switch selection ?? .shelf {
            case .shelf:     ShelfView().environmentObject(store)
            case .discover:  DiscoverView().environmentObject(store)
            case .nas:       NASView().environmentObject(store)
            case .downloads: DownloadsView().environmentObject(store)
            case .settings:  SettingsView().environmentObject(store)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .tint(AppTheme.accent)
    }
}
#endif

// MARK: - First-launch server setup guide

struct ServerSetupGuideView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var port = "4396"
    @State private var username = ""
    @State private var password = ""
    @State private var isTesting = false
    @State private var testResult: TestResult?

    private enum TestResult {
        case success
        case failure(String)
    }

    private var resolvedURL: URL? {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty else { return nil }
        let p = port.trimmingCharacters(in: .whitespacesAndNewlines)
        var components = URLComponents()
        components.scheme = "http"
        components.host = h
        if let portNum = Int(p), portNum > 0 { components.port = portNum }
        components.path = "/"
        return components.url
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    // Header
                    VStack(spacing: 6) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [Color(hex: "#2C3A4A"), Color(hex: "#1A2430")],
                                        startPoint: .topLeading, endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 56, height: 56)

                            Text("元")
                                .font(.system(size: 26, weight: .light, design: .serif))
                                .foregroundStyle(Color(hex: "#E8DCC8"))
                        }
                        .padding(.bottom, 8)

                        Text("欢迎使用元阅")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(AppTheme.ink)

                        Text("连接阅读服务器，开始您的阅读之旅")
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.mutedInk)
                    }
                    .padding(.top, 28)
                    .padding(.bottom, 28)

                    // Form
                    VStack(alignment: .leading, spacing: 18) {
                        PremiumSectionLabel(title: "服务器地址")

                        PremiumCard {
                            VStack(spacing: 0) {
                                setupField(label: "IP / 域名", placeholder: "192.168.1.100", text: $host)
                                RowDivider()
                                setupField(label: "端口号", placeholder: "4396", text: $port)
                            }
                        }

                        PremiumSectionLabel(title: "认证（选填）")

                        PremiumCard {
                            VStack(spacing: 0) {
                                setupField(label: "用户名", placeholder: "可留空", text: $username)
                                RowDivider()
                                HStack {
                                    Text("密码")
                                        .font(.subheadline)
                                        .foregroundStyle(AppTheme.ink)
                                        .frame(width: 80, alignment: .leading)
                                    SecureField("可留空", text: $password)
                                        .textFieldStyle(.plain)
                                        .font(.subheadline)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                            }
                        }

                        if let result = testResult {
                            switch result {
                            case .success:
                                Label("连接成功", systemImage: "checkmark.circle.fill")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(AppTheme.success)
                            case .failure(let msg):
                                Label(msg, systemImage: "exclamationmark.triangle.fill")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.red)
                            }
                        }

                        VStack(spacing: 10) {
                            Button {
                                saveAndDismiss()
                            } label: {
                                HStack {
                                    if isTesting {
                                        ProgressView()
                                            .controlSize(.small)
                                            .padding(.trailing, 4)
                                    }
                                    Text("连接并开始")
                                        .font(.headline.weight(.medium))
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: 46)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(AppTheme.accent)
                            .disabled(resolvedURL == nil || isTesting)

                            Button {
                                store.showServerSetup = false
                            } label: {
                                Text("暂时跳过")
                                    .font(.subheadline)
                                    .foregroundStyle(AppTheme.mutedInk)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.top, 8)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)
                }
            }
            .background(AppTheme.background)
            .navigationTitle("")
            .platformInlineNavigationTitle()
        }
    }

    private func setupField(label: String, placeholder: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(AppTheme.ink)
                .frame(width: 80, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.subheadline)
                #if os(iOS)
                .keyboardType(label.contains("端口") || label.contains("IP") ? .numbersAndPunctuation : .default)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                #endif
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func saveAndDismiss() {
        guard let url = resolvedURL else { return }
        isTesting = true
        testResult = nil

        Task {
            do {
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 8)
                if !username.trimmingCharacters(in: .whitespaces).isEmpty {
                    let cred = "\(username):\(password)"
                    if let data = cred.data(using: .utf8) {
                        request.setValue("Basic \(data.base64EncodedString())", forHTTPHeaderField: "Authorization")
                    }
                }
                let (_, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if code >= 200 && code < 500 {
                    addConnectionAndClose(url: url)
                } else {
                    isTesting = false
                    testResult = .failure("服务器返回异常状态码 \(code)")
                }
            } catch {
                addConnectionAndClose(url: url)
            }
        }
    }

    private func addConnectionAndClose(url: URL) {
        let connection = NASConnection(
            name: "阅读服务器",
            kind: .readerServer,
            baseURL: url,
            username: username.trimmingCharacters(in: .whitespaces),
            password: password,
            isEnabled: true
        )
        if let idx = store.nasConnections.firstIndex(where: { $0.kind == .readerServer }) {
            store.nasConnections[idx] = connection
        } else {
            store.nasConnections.insert(connection, at: 0)
        }
        store.save()
        isTesting = false
        testResult = .success
        store.showServerSetup = false
        store.activityMessage = "已添加阅读服务器：\(url.host ?? "")"
        Task {
            await store.syncReaderServerShelfToLocal()
        }
    }
}

// MARK: - Startup overlay

private struct StartupLoadingView: View {
    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Icon mark
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(hex: "#2C3A4A"),
                                    Color(hex: "#1A2430")
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 80, height: 80)
                        .shadow(color: .black.opacity(0.18), radius: 24, y: 10)

                    Text("元")
                        .font(.system(size: 38, weight: .light, design: .serif))
                        .foregroundStyle(Color(hex: "#E8DCC8"))
                        .kerning(-1)
                }

                // App name
                VStack(spacing: 4) {
                    Text("元阅")
                        .font(.system(size: 15, weight: .medium, design: .default))
                        .kerning(3)
                        .foregroundStyle(AppTheme.ink)

                    Text("MetaRead")
                        .font(.system(size: 10, weight: .regular))
                        .kerning(2)
                        .foregroundStyle(AppTheme.mutedInk)
                }
                .padding(.top, 20)

                Spacer()

                // Subtle loading indicator at bottom
                ProgressView()
                    .controlSize(.small)
                    .tint(AppTheme.mutedInk.opacity(0.4))
                    .padding(.bottom, 52)
            }
        }
    }
}
