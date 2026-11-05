import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension Color {
    /// Kiln's one tint: a deep ember. White text on it clears 4.5:1.
    static let ember = Color(red: 0.78, green: 0.29, blue: 0.09)
}

@main
struct KilnApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Window("Kiln", id: "main") {
            ContentView(store: Store.shared)
                .tint(.ember)
        }
        .defaultSize(width: 600, height: 680)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Updates.check() }
            }
            CommandGroup(replacing: .newItem) {
                Button("Choose Files…") { Pickers.open(into: Store.shared) }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .pasteboard) {
                Button("Paste Files") { Pickers.paste(into: Store.shared) }
                    .keyboardShortcut("v")
            }
        }

        Settings {
            SettingsView(store: Store.shared)
        }
    }
}

extension Store {
    @MainActor static let shared = Store()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self   // Finder: right-click > Quick Actions / Services > Open in Kiln
        NSUpdateDynamicServices()
    }

    /// The "Open in Kiln" service.
    @objc func openFiles(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        Task { @MainActor in
            Store.shared.add(urls)
            NSApp.activate()
        }
    }

    /// Files dropped on the Dock icon, or opened with "Open With > Kiln".
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in Store.shared.add(urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

enum Pickers {
    @MainActor
    static func open(into store: Store) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Choose"
        panel.message = "Pick photos, videos, music, PDFs or documents."
        if panel.runModal() == .OK { store.add(panel.urls) }
    }

    /// Files copied in Finder, or a picture copied from anywhere (a screenshot, a web image).
    @MainActor
    static func paste(into store: Store) {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            store.add(urls)
            return
        }
        guard let image = NSImage(pasteboard: pb), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        let stamp = Date().formatted(.dateTime.year().month().day().hour().minute().second())
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        let url = Drops.scratchFolder().appendingPathComponent("Pasted picture \(stamp).png")
        if (try? png.write(to: url)) != nil { store.add([url]) }
    }
}

enum Drops {
    static func scratchFolder() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Kiln-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static let types: [UTType] = [.fileURL, .movie, .image, .audio, .pdf]

    @MainActor
    static func load(_ providers: [NSItemProvider], into store: Store) {
        Task {
            var urls: [URL] = []
            for p in providers {
                if let u = await url(from: p) { urls.append(u) }
            }
            store.add(urls)
        }
    }

    /// A Finder file arrives as its real location. A photo dragged out of Photos arrives as a promise,
    /// so it's copied somewhere temporary first (and its results go to Downloads).
    static func url(from p: NSItemProvider) async -> URL? {
        if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return await withCheckedContinuation { c in
                _ = p.loadObject(ofClass: URL.self) { u, _ in c.resume(returning: u) }
            }
        }
        for type in [UTType.movie, .image, .audio, .pdf] where p.hasItemConformingToTypeIdentifier(type.identifier) {
            return await withCheckedContinuation { c in
                p.loadFileRepresentation(forTypeIdentifier: type.identifier) { u, _ in
                    guard let u else { return c.resume(returning: nil) }
                    var name = p.suggestedName ?? u.deletingPathExtension().lastPathComponent
                    if !u.pathExtension.isEmpty, !name.lowercased().hasSuffix("." + u.pathExtension.lowercased()) {
                        name += "." + u.pathExtension
                    }
                    let dest = scratchFolder().appendingPathComponent(name)
                    c.resume(returning: (try? FileManager.default.copyItem(at: u, to: dest)) != nil ? dest : nil)
                }
            }
        }
        return nil
    }
}

/// Asks GitHub for the newest release and offers to open its page. Only runs when chosen from the menu.
enum Updates {
    static let page = URL(string: "https://github.com/kritinrautela/kiln/releases/latest")!
    static let api = URL(string: "https://api.github.com/repos/kritinrautela/kiln/releases/latest")!

    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    /// "1.10" is newer than "1.9"; a leading "v" is ignored.
    static func isNewer(_ latest: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(latest), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    @MainActor
    static func check() {
        Task {
            var req = URLRequest(url: api, timeoutInterval: 15)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let alert = NSAlert()
            do {
                let (data, _) = try await URLSession.shared.data(for: req)
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard let tag = json?["tag_name"] as? String else { throw KilnError("No release found.") }
                if isNewer(tag, than: current) {
                    alert.messageText = "A new Kiln is ready"
                    alert.informativeText = "You have \(current). Version \(tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))) is out. Download it, then drag the new Kiln into Applications to replace this one."
                    alert.addButton(withTitle: "Download")
                    alert.addButton(withTitle: "Later")
                    if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(page) }
                    return
                }
                alert.messageText = "Kiln is up to date"
                alert.informativeText = "You have the newest version, \(current)."
            } catch {
                alert.messageText = "Couldn't check for updates"
                alert.informativeText = "Check the internet connection and try again."
            }
            alert.runModal()
        }
    }
}
