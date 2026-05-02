# Xcode 工程

仓库当前保持 Swift Package 可直接编译，同时提供 `project.yml` 生成正式 Xcode 工程。

## 生成工程

安装 XcodeGen 后执行：

```bash
scripts/generate-xcode.sh
open NovelReader.xcodeproj
```

生成后包含两个 App target：

- `NovelReader-iOS`：支持 iPhone 和 iPad。
- `NovelReader-macOS`：支持 macOS。

## Bundle 与能力

默认 bundle id：

- iOS/iPadOS：`com.cyberzen.reader`
- macOS：`com.cyberzen.reader.macos`

已预留：

- 本地网络权限，用于发现和连接 NAS。
- 文档类型，支持 TXT/EPUB 导入。
- JavaScriptCore framework，用于执行书源中的轻量 `<js>` 规则。
- Security framework，用于把 NAS 密码保存到 Keychain。

个人免费开发者账号不支持 iCloud/CloudKit capability，所以默认侧载配置已经移除 iCloud entitlement。NAS、本地阅读、书源和 Keychain 不受影响。

如果以后换成付费 Apple Developer Program，并想打开 CloudKit 同步，再在 Signing & Capabilities 里添加 iCloud/CloudKit，并把 container 设置成你账号下的容器，比如 `iCloud.com.cyberzen.reader`。

## 真机运行

1. 打开 `NovelReader.xcodeproj`。
2. 在 Signing & Capabilities 里选择你的 Team。
3. 确认 Bundle Identifier 是 `com.cyberzen.reader`，或改成你喜欢的唯一 ID。
4. 不要添加 iCloud/CloudKit capability，Personal Team 会报错。
5. 选择 iPhone、iPad 或 Mac 目标运行。

Swift Package 下可以继续用：

```bash
swift test
swift run NovelReaderApp
```

## 侧载版状态

当前 WebDAV 已经是可用路径：支持账号密码、目录浏览、TXT/EPUB 导入和后台 URLSession 下载恢复。SMB/SFTP 连接配置和 Bonjour 发现入口已经保留，但真正浏览文件仍需要接入原生客户端库，例如 SMB2/libsmb2 或 libssh2/NMSSH 一类依赖；当前界面会明确提示协议尚未接入，而不会显示假数据。

## CloudKit

CloudKit 代码已保留，但默认侧载配置未启用 entitlement。启用后它只同步：

- 书籍元数据
- 阅读进度
- 阅读状态
- 阅读样式

不会同步小说正文、NAS 文件或书源下载内容。这样更适合作为个人阅读状态同步，也更容易控制 App Store 风险。
