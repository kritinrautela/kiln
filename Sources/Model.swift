import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

enum FileKind: String, CaseIterable {
    case image, video, audio, pdf, document, other

    static func of(_ url: URL) -> FileKind {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return .pdf }
        if ["doc", "docx", "rtf", "rtfd", "odt", "html", "htm", "txt", "text", "md", "markdown", "webarchive"]
            .contains(ext) { return .document }
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        return .other
    }

    var plural: String { self == .pdf ? "PDFs" : noun.prefix(1).uppercased() + noun.dropFirst() + "s" }

    var noun: String {
        switch self {
        case .image: "photo"
        case .video: "video"
        case .audio: "audio file"
        case .pdf: "PDF"
        case .document: "document"
        case .other: "file"
        }
    }
}

struct DroppedFile: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let kind: FileKind
    let size: Int64

    init(url: URL) {
        self.url = url
        kind = FileKind.of(url)
        size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }

    var name: String { url.lastPathComponent }
}

/// A finished copy, shown in the tray.
struct Result: Identifiable {
    let id = UUID()
    let url: URL
    let before: Int64
    let after: Int64
    var text: String? = nil   // for "Get text"
    var saving = false        // only "Make smaller" talks about size saved
}

struct Failure: Identifiable {
    let id = UUID()
    let name: String
    let reason: String
}

/// Everything Kiln can do. Each action says which kinds it works on.
enum Action: String, CaseIterable, Identifiable {
    case convert, smaller, resize, crop, trim, combine, removeBackground, text, rotate, removeLocation, mute, split

    var id: String { rawValue }

    var title: String {
        switch self {
        case .convert: "Convert"
        case .smaller: "Make smaller"
        case .resize: "Resize"
        case .crop: "Crop"
        case .trim: "Trim"
        case .combine: "Combine into one PDF"
        case .removeBackground: "Remove background"
        case .text: "Get the text"
        case .rotate: "Rotate"
        case .removeLocation: "Remove location"
        case .mute: "Remove sound"
        case .split: "Split into pages"
        }
    }

    var symbol: String {
        switch self {
        case .convert: "arrow.triangle.2.circlepath"
        case .smaller: "arrow.down.right.and.arrow.up.left"
        case .resize: "aspectratio"
        case .crop: "crop"
        case .trim: "timeline.selection"
        case .combine: "doc.on.doc"
        case .removeBackground: "person.crop.rectangle.badge.plus"
        case .text: "text.viewfinder"
        case .rotate: "rotate.right"
        case .removeLocation: "location.slash"
        case .mute: "speaker.slash"
        case .split: "square.split.2x1"
        }
    }

    var hint: String {
        switch self {
        case .convert: "Change the file type"
        case .smaller: "Shrink for email or messages"
        case .resize: "Scale the picture to ¾, ½ or ¼"
        case .crop: "Cut to a shape, like square or story"
        case .trim: "Cut the start or end"
        case .combine: "Put pages and photos together"
        case .removeBackground: "Keep the subject, lose the rest"
        case .text: "Copy the words out, even from a photo"
        case .rotate: "Turn a quarter to the right"
        case .removeLocation: "Strip where it was taken"
        case .mute: "Keep the picture, drop the audio"
        case .split: "One PDF per page"
        }
    }

    func applies(to kind: FileKind) -> Bool {
        switch self {
        case .convert: [.image, .video, .audio, .pdf, .document].contains(kind)
        case .smaller: [.image, .video, .pdf].contains(kind)
        case .resize: kind == .image
        case .crop: [.image, .video].contains(kind)
        case .trim: [.video, .audio].contains(kind)
        case .combine: [.image, .pdf].contains(kind)
        case .removeBackground: kind == .image
        case .text: [.image, .pdf, .document].contains(kind)
        case .rotate: [.image, .video, .pdf].contains(kind)
        case .removeLocation: [.image, .video].contains(kind)
        case .mute: kind == .video
        case .split: kind == .pdf
        }
    }

    /// Combine needs two or more files; the others need one.
    var minimumFiles: Int { self == .combine ? 2 : 1 }
}

/// Output formats offered by Convert, per kind.
struct Format: Hashable, Identifiable {
    let ext: String
    let label: String
    var id: String { label }

    static func choices(for kind: FileKind) -> [Format] {
        switch kind {
        case .image: [.init(ext: "jpg", label: "JPG"), .init(ext: "png", label: "PNG"), .init(ext: "heic", label: "HEIC"),
                      .init(ext: "avif", label: "AVIF"), .init(ext: "gif", label: "GIF"), .init(ext: "tiff", label: "TIFF"),
                      .init(ext: "pdf", label: "PDF")]
        case .video: [.init(ext: "mp4", label: "MP4"), .init(ext: "mov", label: "MOV"), .init(ext: "gif", label: "GIF"),
                      .init(ext: "m4a", label: "Sound only")]
        case .audio: [.init(ext: "m4a", label: "M4A"), .init(ext: "wav", label: "WAV"), .init(ext: "aiff", label: "AIFF")]
        case .pdf: [.init(ext: "jpg", label: "JPG pages"), .init(ext: "png", label: "PNG pages"),
                    .init(ext: "docx", label: "Word (text)"), .init(ext: "txt", label: "Text")]
        case .document: [.init(ext: "pdf", label: "PDF"), .init(ext: "docx", label: "Word"), .init(ext: "rtf", label: "RTF"),
                         .init(ext: "txt", label: "Text")]
        case .other: []
        }
    }
}

/// How small "Make smaller" goes.
enum Size: String, CaseIterable, Identifiable {
    case light, email, tiny
    var id: String { rawValue }
    var label: String {
        switch self {
        case .light: "A bit smaller"
        case .email: "For email"
        case .tiny: "Tiny"
        }
    }
    /// Longest side of a photo, in pixels.
    var imagePixels: Int {
        switch self {
        case .light: 3000
        case .email: 1600
        case .tiny: 800
        }
    }
    var imageQuality: Double {
        switch self {
        case .light: 0.8
        case .email: 0.72
        case .tiny: 0.65
        }
    }
}

enum SaveLocation: String, CaseIterable, Identifiable {
    case beside, downloads
    var id: String { rawValue }
    var label: String { self == .beside ? "Next to the original" : "Downloads folder" }
}

@MainActor
@Observable
final class Store {
    var files: [DroppedFile] = []
    var results: [Result] = []
    var failures: [Failure] = []
    var working = false
    var progress = 0.0
    var status = ""
    var newVersion: String?          // set by the weekly update check
    private var job: Task<Void, Never>?
    var pendingCrop: [DroppedFile] = []
    var pendingTrim: [DroppedFile] = []

    var saveLocation: SaveLocation = SaveLocation(rawValue: UserDefaults.standard.string(forKey: "save") ?? "") ?? .beside {
        didSet { UserDefaults.standard.set(saveLocation.rawValue, forKey: "save") }
    }

    var kinds: Set<FileKind> { Set(files.map(\.kind)) }

    var actions: [Action] {
        Action.allCases.filter { a in
            files.filter { a.applies(to: $0.kind) }.count >= a.minimumFiles
        }
    }

    func count(for action: Action) -> Int { files.filter { action.applies(to: $0.kind) }.count }

    func add(_ urls: [URL]) {
        var seen = Set(files.map(\.url))
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {   // a folder: take the files directly inside it
                let inside = (try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                for f in inside.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where !seen.contains(f) {
                    var d: ObjCBool = false
                    if FileManager.default.fileExists(atPath: f.path, isDirectory: &d), !d.boolValue {
                        files.append(DroppedFile(url: f))
                        seen.insert(f)
                    }
                }
            } else if !seen.contains(url) {
                files.append(DroppedFile(url: url))
                seen.insert(url)
            }
        }
        if !working {   // a drop mid-job joins the list but must not wipe results still coming in
            results = []
            failures = []
        }
    }

    func remove(_ file: DroppedFile) { files.removeAll { $0.id == file.id } }

    func clear() {
        files = []
        results = []
        failures = []
        status = ""
    }

    var showingResults: Bool { working || !results.isEmpty || !failures.isEmpty }

    func backToActions() {
        results = []
        failures = []
        status = ""
    }

    /// The one-click job most people want for what was dropped.
    var suggestion: Suggestion? {
        guard !files.isEmpty else { return nil }
        let k = kinds
        let exts = Set(files.map { $0.url.pathExtension.lowercased() })
        if k == [.document] { return .init(action: .convert, formats: [.document: .init(ext: "pdf", label: "PDF")],
                                           label: "Make PDF", symbol: "doc.richtext") }
        if files.count > 1, k.isSubset(of: [.image, .pdf]), k.contains(.pdf) {
            return .init(action: .combine, label: "Combine into one PDF", symbol: "doc.on.doc")
        }
        if k == [.image] {
            if !exts.isDisjoint(with: ["heic", "heif", "avif", "webp", "tif", "tiff", "bmp"]) {
                return .init(action: .convert, formats: [.image: .init(ext: "jpg", label: "JPG")],
                             label: "Make JPG", symbol: "photo")
            }
            return .init(action: .smaller, label: "Make smaller for sending", symbol: Action.smaller.symbol)
        }
        if k == [.video] {
            if !exts.isSubset(of: ["mp4"]) {
                return .init(action: .convert, formats: [.video: .init(ext: "mp4", label: "MP4")],
                             label: "Make MP4", symbol: "film")
            }
            return .init(action: .smaller, label: "Make smaller for sending", symbol: Action.smaller.symbol)
        }
        if k == [.pdf] {
            return files.count > 1
                ? .init(action: .combine, label: "Combine into one PDF", symbol: "doc.on.doc")
                : .init(action: .smaller, label: "Make smaller for sending", symbol: Action.smaller.symbol)
        }
        if k == [.audio], !exts.isSubset(of: ["m4a", "mp3"]) {
            return .init(action: .convert, formats: [.audio: .init(ext: "m4a", label: "M4A")],
                         label: "Make M4A", symbol: "music.note")
        }
        return nil
    }

    /// Runs one job per file (or one for all, for combine), off the main thread, filling the tray as copies land.
    func run(_ action: Action, formats: [FileKind: Format] = [:], size: Size = .email,
             options: [UUID: JobOptions] = [:], only: Set<UUID>? = nil, scale: Double = 0.5) {
        let targets = files.filter { action.applies(to: $0.kind) && (only?.contains($0.id) ?? true) }
        guard targets.count >= action.minimumFiles, !working else { return }
        working = true
        progress = 0
        results = []
        failures = []
        let location = saveLocation
        job = Task {
            if action == .combine {
                status = "Combining \(targets.count) files…"
                await record(targets.first!, location: location) { out in
                    try await Engine.combine(targets.map(\.url), into: out)
                } named: { Output.url(beside: targets[0].url, suffix: "combined", ext: "pdf", location: location) }
                progress = 1
            } else {
                for (i, f) in targets.enumerated() {
                    if Task.isCancelled { break }
                    status = "\(action.title): \(f.name)"
                    await perform(action, on: f, format: formats[f.kind], size: size, options: options[f.id] ?? JobOptions(scale: scale),
                                  location: location)
                    progress = Double(i + 1) / Double(targets.count)
                }
            }
            working = false
            job = nil
            if Task.isCancelled {
                status = "Stopped"
                return
            }
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }   // bounce the Dock icon
            status = failures.isEmpty ? "Done" : "Done, with \(failures.count) problem\(failures.count == 1 ? "" : "s")"
        }
    }

    /// Stops after the file being worked on (a video export stops straight away).
    func stop() { job?.cancel() }

    private func perform(_ action: Action, on f: DroppedFile, format: Format?, size: Size, options: JobOptions,
                         location: SaveLocation) async {
        do {
            let produced = try await Engine.run(action, file: f, format: format, size: size, options: options,
                                                location: location)
            for p in produced {
                let after = (try? p.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                results.append(Result(url: p.url, before: f.size, after: after, text: p.text, saving: action == .smaller))
            }
        } catch {
            if Task.isCancelled || error is CancellationError { return }
            failures.append(Failure(name: f.name, reason: error.localizedDescription))
        }
    }

    private func record(_ f: DroppedFile, location: SaveLocation, _ work: (URL) async throws -> Void,
                        named: () -> URL) async {
        let out = named()
        do {
            try await work(out)
            let after = (try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            results.append(Result(url: out, before: files.reduce(0) { $0 + $1.size }, after: after))
        } catch {
            try? FileManager.default.removeItem(at: out)
            failures.append(Failure(name: f.name, reason: error.localizedDescription))
        }
    }
}

struct Suggestion {
    let action: Action
    var formats: [FileKind: Format] = [:]
    let label: String
    let symbol: String
}

/// Per-file settings gathered by the crop and trim sheets.
struct JobOptions {
    var crop: CGRect? = nil            // normalized, top-left origin, 0...1
    var shape: CGFloat? = nil          // width/height in real pixels, when a shape like Square was picked
    var trim: ClosedRange<Double>? = nil   // seconds
    var scale: Double = 0.5            // Resize: share of the original width and height
}

struct KilnError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Output {
    /// A new file next to the original (or in Downloads), never replacing anything: "name (suffix).ext", then
    /// "name (suffix 2).ext"... Files that came from a temporary place (a drag out of Photos) go to Downloads.
    static func url(beside original: URL, suffix: String?, ext: String, location: SaveLocation) -> URL {
        var folder = original.deletingLastPathComponent()
        let real = folder.resolvingSymlinksInPath().path + "/"
        let scratch = [NSTemporaryDirectory(), "/tmp", "/var/folders"]
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path + "/" }
        let temp = scratch.contains { real.hasPrefix($0) } || real.contains("/Library/Containers/")
        if location == .downloads || temp || !FileManager.default.isWritableFile(atPath: folder.path) {
            folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        }
        let stem = original.deletingPathExtension().lastPathComponent
        let sameExt = original.pathExtension.lowercased() == ext.lowercased()
        func make(_ n: Int) -> URL {
            let tag: String
            if let suffix { tag = n == 1 ? " (\(suffix))" : " (\(suffix) \(n))" }
            else if !sameExt || folder != original.deletingLastPathComponent() { tag = n == 1 ? "" : " (\(n))" }
            else { tag = " (\(n + 1))" }
            return folder.appendingPathComponent(stem + tag).appendingPathExtension(ext)
        }
        var n = 1
        while FileManager.default.fileExists(atPath: make(n).path) || make(n) == original { n += 1 }
        return make(n)
    }
}

func byteString(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}
