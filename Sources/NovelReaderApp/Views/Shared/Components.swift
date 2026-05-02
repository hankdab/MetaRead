import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Theme

enum AppTheme {
    static let background    = Color(hex: "#EDEAE3")   // warm parchment
    static let surface       = Color(hex: "#F7F4F0")   // warm near-white
    static let elevatedSurface = Color(hex: "#FDFCFA")
    static let ink           = Color(hex: "#1A1714")   // warm near-black
    static let mutedInk      = Color(hex: "#9A9690")   // warm stone
    static let hairline      = Color.black.opacity(0.045)
    static let accent        = Color(hex: "#4E6480")   // steel slate — calm, not iOS blue
    static let success       = Color(hex: "#3D8C6A")
    static let destructive   = Color(hex: "#C0392B")
}

// MARK: - Layout containers

struct AppScreen<Content: View>: View {
    var content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content.background(AppTheme.background.ignoresSafeArea())
    }
}

// MARK: - Page header

struct PageHeader: View {
    var title: String
    var subtitle: String?
    var trailingSystemImage: String?
    var trailingAction: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 28, weight: .regular, design: .default))
                    .foregroundStyle(AppTheme.ink)
                    .kerning(-0.3)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.mutedInk)
                        .lineLimit(2)
                }
            }
            Spacer()
            if let trailingSystemImage, let trailingAction {
                Button(action: trailingAction) {
                    Image(systemName: trailingSystemImage)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(AppTheme.mutedInk)
                        .frame(width: 36, height: 36)
                        .background(AppTheme.surface, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("更多")
            }
        }
    }
}

// MARK: - Card

struct PremiumCard<Content: View>: View {
    var content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .padding(16)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.025), radius: 12, x: 0, y: 4)
    }
}

// MARK: - Row layout

struct PremiumRow<Leading: View, Content: View, Trailing: View>: View {
    var leading: Leading
    var content: Content
    var trailing: Trailing

    init(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder content: () -> Content,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.leading = leading()
        self.content = content()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            leading
            content
            Spacer(minLength: 8)
            trailing
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }
}

// MARK: - Icon chip

struct PremiumIcon: View {
    var systemName: String
    var tint: Color = AppTheme.accent

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 32, height: 32)
            .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Section label

struct PremiumSectionLabel: View {
    var title: String
    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .kerning(0.8)
            .foregroundStyle(AppTheme.mutedInk)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
    }
}

// MARK: - Search field

struct PremiumSearchField: View {
    var placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AppTheme.mutedInk)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.02), radius: 4, y: 1)
    }
}

// MARK: - Filter pills

struct SegmentedPillBar<Option: Hashable>: View {
    var options: [(Option, String)]
    @Binding var selection: Option

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options, id: \.0) { option, title in
                Button {
                    withAnimation(.snappy(duration: 0.16)) { selection = option }
                } label: {
                    Text(title)
                        .font(.subheadline.weight(selection == option ? .medium : .regular))
                        .foregroundStyle(selection == option ? AppTheme.ink : AppTheme.mutedInk)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(
                            selection == option
                                ? AppTheme.elevatedSurface
                                : Color.clear,
                            in: Capsule()
                        )
                        .shadow(color: selection == option ? .black.opacity(0.05) : .clear, radius: 6, y: 2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.black.opacity(0.04), in: Capsule())
    }
}

// MARK: - Chips & badges

struct SmallStatusChip: View {
    var title: String
    var tint: Color

    var body: some View {
        Text(title)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.10), in: Capsule())
    }
}

struct StatusBadge: View {
    var title: String
    var color: Color

    var body: some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.10), in: Capsule())
    }
}

struct FormatBadge: View {
    var format: BookFormat
    var body: some View { StatusBadge(title: format.rawValue.uppercased(), color: color) }

    private var color: Color {
        switch format {
        case .txt:  .green
        case .epub: .indigo
        case .web:  AppTheme.accent
        }
    }
}

// MARK: - Divider

struct RowDivider: View {
    var body: some View {
        Rectangle()
            .fill(AppTheme.hairline)
            .frame(height: 1)
            .padding(.leading, 44)
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    var systemImage: String
    var title: String
    var subtitle: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(AppTheme.mutedInk.opacity(0.6))
            VStack(spacing: 6) {
                Text(title)
                    .font(.headline.weight(.medium))
                    .foregroundStyle(AppTheme.ink)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.mutedInk)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Section title

struct SectionTitle: View {
    var title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline.weight(.medium))
            if let subtitle {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Stat tile

struct StatTile: View {
    var title: String
    var value: String
    var systemImage: String
    var tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.title3.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.ink)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedInk)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Progress pill

struct ProgressPill: View {
    var value: Double
    var body: some View {
        Text(value.formatted(.percent.precision(.fractionLength(0))))
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
    }
}

// MARK: - Book cover

struct BookCoverView: View {
    var book: Book

    var body: some View {
        ZStack {
            if let url = book.coverImageURL, url.isFileURL,
               let img = PlatformImage(contentsOfFile: url.path) {
                CoverImage(image: img)
            } else if let url = book.coverImageURL,
                      url.scheme == "http" || url.scheme == "https" {
                RemoteCoverImage(url: url) { generatedCover }
            } else {
                generatedCover
            }
        }
        .aspectRatio(0.68, contentMode: .fit)
        .shadow(color: .black.opacity(0.14), radius: 8, y: 4)
    }

    private var generatedCover: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.20, green: 0.24, blue: 0.28),
                             Color(red: 0.50, green: 0.38, blue: 0.26)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
            VStack(spacing: 8) {
                Image(systemName: book.coverSymbol)
                    .font(.system(size: 24, weight: .regular))
                Text(book.title)
                    .font(.caption.weight(.medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(.white.opacity(0.92))
            .padding(10)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Internals

#if os(macOS)
typealias PlatformImage = NSImage
#else
typealias PlatformImage = UIImage
#endif

private struct CoverImage: View {
    var image: PlatformImage
    var body: some View {
        #if os(macOS)
        Image(nsImage: image).resizable().scaledToFill()
            .clipShape(RoundedRectangle(cornerRadius: 8))
        #else
        Image(uiImage: image).resizable().scaledToFill()
            .clipShape(RoundedRectangle(cornerRadius: 8))
        #endif
    }
}

private struct RemoteCoverImage<Placeholder: View>: View {
    var url: URL
    var placeholder: Placeholder
    init(url: URL, @ViewBuilder placeholder: () -> Placeholder) {
        self.url = url; self.placeholder = placeholder()
    }
    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            case .failure:
                placeholder
            case .empty:
                ZStack {
                    placeholder
                    ProgressView().controlSize(.small)
                        .padding(6).background(.thinMaterial, in: Circle())
                }
            @unknown default:
                placeholder
            }
        }
    }
}

// MARK: - Extensions

extension ReadingStatus {
    var tint: Color {
        switch self {
        case .unread:   .secondary
        case .reading:  AppTheme.accent
        case .finished: AppTheme.success
        }
    }
}

extension DownloadState {
    var tint: Color {
        switch self {
        case .queued:   .secondary
        case .running:  AppTheme.accent
        case .paused:   .orange
        case .failed:   AppTheme.destructive
        case .finished: AppTheme.success
        }
    }
}

extension DownloadKind {
    var title: String {
        switch self {
        case .book:    "整书"
        case .chapter: "章节"
        case .file:    "文件"
        }
    }
}

extension Color {
    init(hex: String) {
        let clean = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt64(clean, radix: 16) ?? 0
        let r = Double((value >> 16) & 0xff) / 255
        let g = Double((value >>  8) & 0xff) / 255
        let b = Double( value        & 0xff) / 255
        self.init(red: r, green: g, blue: b)
    }
}

extension View {
    @ViewBuilder
    func platformInlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
