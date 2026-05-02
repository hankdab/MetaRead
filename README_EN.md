# MetaRead (元阅)

<p align="center">
  <b>A native Apple-platform novel reader</b><br/>
  iOS · iPadOS · macOS
</p>

<p align="center">
  <a href="#features">Features</a> •
  <a href="#getting-started">Getting Started</a> •
  <a href="#acknowledgements">Acknowledgements</a> •
  <a href="#license">License</a>
</p>

<p align="center">
  <a href="./README.md">中文</a>
</p>

---

## About

**MetaRead (元阅)** is a private novel reader for iOS, iPadOS, and macOS. It connects to a [Legado Reader Server](https://github.com/hectorqin/reader) to sync your bookshelf, and also supports local TXT/EPUB import, WebDAV NAS browsing, and configurable book sources.

This project's server API protocol is inspired by **[hectorqin/reader](https://github.com/hectorqin/reader)** (Legado Reader Server). Special thanks to that project and its community.

## Features

- **Immersive Reading** — Adjustable font size, line height, paragraph spacing, bold weight, and multiple themes
- **Reader Server Sync** — Connect to a Legado server to auto-sync your bookshelf
- **Local Import** — TXT files with smart chapter splitting, basic EPUB parsing
- **Book Sources** — Configurable rules with CSS selectors, XPath, JSONPath, and JavaScript
- **NAS Browsing** — WebDAV file browser with Bonjour/mDNS discovery
- **Background Downloads** — Chapter-level caching for offline reading, survives app restart
- **Cross-platform** — Native SwiftUI on iPhone, iPad, and Mac with adaptive layouts
- **Data Safety** — SQLite persistence, FTS full-text search, Keychain password storage, backup/restore

## Getting Started

### Requirements

- Xcode 15+
- iOS 17+ / macOS 14+
- Swift 5.9+

### Build & Run

```bash
git clone https://github.com/hankdab/MetaRead.git
cd MetaRead
swift build

# Or open in Xcode
open NovelReader.xcodeproj
```

### Connect to a Reader Server

1. Deploy [Legado Reader Server](https://github.com/hectorqin/reader)
2. Open MetaRead, follow the setup guide to enter your server IP and port
3. Your bookshelf will sync automatically

## Project Structure

```
Sources/NovelReaderApp
├── App/          # App entry, root view
├── Core/         # Models, AppStore, service engine
├── Views/        # UI views
│   ├── Discover/   # Book discovery
│   ├── Downloads/  # Download manager
│   ├── NAS/        # NAS file browser
│   ├── Reader/     # Reader view
│   ├── Settings/   # Settings
│   ├── Shared/     # Shared components
│   └── Shelf/      # Bookshelf
└── Resources/    # Assets
```

## Acknowledgements

- **[hectorqin/reader](https://github.com/hectorqin/reader)** — Legado Reader Server, whose API protocol this project is built upon
- **[gedoor/legado](https://github.com/gedoor/legado)** — Legado Android client, the original source of book source rule formats

## License

This project is licensed under the [MIT License](./LICENSE).
