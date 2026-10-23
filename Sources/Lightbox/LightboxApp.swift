import SwiftUI
import AppKit
import UniformTypeIdentifiers


struct LightboxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = Store()

    var body: some Scene {
        WindowGroup("Lightbox") {
            RootView()
                .environmentObject(store)
                .frame(minWidth: 980, minHeight: 640)
                .preferredColorScheme(.dark)
                .task {
                    if let u = Entry.openOnLaunch { await store.open(u); return }
                    await store.checkScanner(); store.warmLabIndex()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Scan…") { openPanel() }.keyboardShortcut("o")
            }
            CommandGroup(after: .saveItem) {
                Button("Save JPEG") { Task { await store.export(.jpeg) } }.keyboardShortcut("s")
                Button("Save 16-bit TIFF") { Task { await store.export(.tiff) } }.keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Add to Photos") { Task { await store.addToPhotos() } }.keyboardShortcut("p", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { store.undo() }.keyboardShortcut("z")
                Button("Redo") { store.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .help) {
                Button("Show the Walkthrough and Tips Again") { store.resetTips() }
            }
        }
    }

    private func openPanel() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [UTType(filenameExtension: "pnm")!, .tiff]
        p.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("Lightbox")
        if p.runModal() == .OK, let u = p.url { Task { await store.open(u) } }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct RootView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        ZStack {
            Color(white: 0.09).ignoresSafeArea()
            if store.onboarded {
                MainView().transition(.opacity)
            } else {
                WalkthroughView().transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: store.onboarded)
        .alert("Something went wrong", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }
}
