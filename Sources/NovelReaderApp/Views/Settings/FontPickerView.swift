import SwiftUI
import CoreText
import UniformTypeIdentifiers

struct FontOption: Identifiable {
    let id: String       // PostScript name
    let displayName: String
    let category: String
}

private let builtinFontOptions: [FontOption] = [
    .init(id: "__serif", displayName: "宋体感（内置）", category: "内置样式"),
    .init(id: "__sans", displayName: "黑体（内置）", category: "内置样式"),
    .init(id: "__rounded", displayName: "圆体（内置）", category: "内置样式"),
    .init(id: "__mono", displayName: "等宽（内置）", category: "内置样式"),
]

private let systemFontCandidates: [(id: String, displayName: String, category: String)] = [
    ("PingFangSC-Regular", "苹方 细体", "系统中文"),
    ("PingFangSC-Medium", "苹方 中等", "系统中文"),
    ("PingFangSC-Semibold", "苹方 半粗", "系统中文"),
    ("HiraginoSansGB-W3", "冬青黑体 W3", "系统中文"),
    ("HiraginoSansGB-W6", "冬青黑体 W6", "系统中文"),
    ("STKaitiSC-Regular", "华文楷体", "系统中文"),
    ("STSong", "华文宋体", "系统中文"),
    ("STFangsong", "华文仿宋", "系统中文"),
    ("Georgia", "Georgia", "英文衬线"),
    ("TimesNewRomanPSMT", "Times New Roman", "英文衬线"),
    ("HelveticaNeue", "Helvetica Neue", "英文无衬线"),
    ("Futura-Medium", "Futura", "英文无衬线"),
]

struct FontPickerView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var importedFonts: [FontOption] = []
    @State private var isFontImporterPresented = false
    @State private var importError: String?

    private var availableSystemFonts: [FontOption] {
        systemFontCandidates.compactMap { candidate in
            let font = CTFontCreateWithName(candidate.id as CFString, 12, nil)
            let actualName = CTFontCopyPostScriptName(font) as String
            guard actualName == candidate.id else { return nil }
            return FontOption(id: candidate.id, displayName: candidate.displayName, category: candidate.category)
        }
    }

    private var currentSelection: String {
        store.readerTheme.customFontName ?? "__\(store.readerTheme.fontDesign.rawValue)"
    }

    var body: some View {
        Form {
            Section("内置样式") {
                ForEach(builtinFontOptions) { option in
                    fontRow(option)
                }
            }

            let systemFonts = availableSystemFonts
            if !systemFonts.isEmpty {
                let categories = Dictionary(grouping: systemFonts, by: \.category)
                ForEach(Array(categories.keys.sorted()), id: \.self) { category in
                    Section(category) {
                        ForEach(categories[category] ?? []) { option in
                            fontRow(option)
                        }
                    }
                }
            }

            if !importedFonts.isEmpty {
                Section("已导入字体") {
                    ForEach(importedFonts) { option in
                        fontRow(option)
                    }
                }
            }

            Section("自定义字体文件") {
                Button {
                    isFontImporterPresented = true
                } label: {
                    Label("导入 TTF / OTF 文件", systemImage: "square.and.arrow.down")
                }
                if let error = importError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Text("导入后字体保存在 App 文档目录，重装 App 后需要重新导入。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("选择字体")
        .onAppear { loadImportedFonts() }
        .fileImporter(
            isPresented: $isFontImporterPresented,
            allowedContentTypes: [
                UTType(filenameExtension: "ttf") ?? .data,
                UTType(filenameExtension: "otf") ?? .data,
            ],
            allowsMultipleSelection: false
        ) { result in
            importError = nil
            guard case .success(let urls) = result, let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else {
                importError = "无法访问该文件"
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }
            installFont(from: url)
        }
    }

    @ViewBuilder
    private func fontRow(_ option: FontOption) -> some View {
        Button {
            applyFont(option)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    if option.id.hasPrefix("__") {
                        Text(option.displayName)
                    } else {
                        Text(option.displayName)
                            .font(.custom(option.id, size: 17))
                        Text("永和九年，歲在癸丑")
                            .font(.custom(option.id, size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if currentSelection == option.id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.blue)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func applyFont(_ option: FontOption) {
        if option.id.hasPrefix("__") {
            let designRaw = String(option.id.dropFirst(2))
            store.readerTheme.fontDesign = ReaderFontDesign(rawValue: designRaw) ?? .serif
            store.readerTheme.customFontName = nil
        } else {
            store.readerTheme.customFontName = option.id
        }
        store.save()
    }

    private func fontsDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("Fonts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func installFont(from sourceURL: URL) {
        let dest = fontsDirectory().appendingPathComponent(sourceURL.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: sourceURL, to: dest)
        } catch {
            importError = "复制文件失败：\(error.localizedDescription)"
            return
        }

        var error: Unmanaged<CFError>?
        let registered = CTFontManagerRegisterFontsForURL(dest as CFURL, .process, &error)
        if !registered {
            importError = "注册字体失败：\(error?.takeRetainedValue().localizedDescription ?? "未知错误")"
            return
        }

        let font = CTFontCreateWithName(dest.deletingPathExtension().lastPathComponent as CFString, 12, nil)
        let psName = CTFontCopyPostScriptName(font) as String
        loadImportedFonts()
        store.readerTheme.customFontName = psName
        store.save()
    }

    private func loadImportedFonts() {
        let dir = fontsDirectory()
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let fontFiles = files.filter { ["ttf", "otf"].contains($0.pathExtension.lowercased()) }

        var error: Unmanaged<CFError>?
        for url in fontFiles {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        }

        importedFonts = fontFiles.compactMap { url in
            let font = CTFontCreateWithName(url.deletingPathExtension().lastPathComponent as CFString, 12, nil)
            let psName = CTFontCopyPostScriptName(font) as String
            let fullName = CTFontCopyFullName(font) as String
            guard !psName.isEmpty else { return nil }
            return FontOption(id: psName, displayName: fullName.isEmpty ? url.deletingPathExtension().lastPathComponent : fullName, category: "已导入")
        }
    }
}
