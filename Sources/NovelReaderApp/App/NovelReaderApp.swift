import SwiftUI

@main
struct NovelReaderApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
        }
        #if os(macOS)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Import Sample Library") {
                    store.bootstrapSampleData()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }
        }
        #endif
    }
}
