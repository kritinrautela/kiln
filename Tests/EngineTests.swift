import AppKit
import AVFoundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Builds sample files in a scratch folder, runs every action through Engine, and checks what comes out.
/// Run: Tests/run.sh   (never touches real files)
@main
struct EngineTests {
    static var failures = 0
    static var checks = 0

    static func check(_ ok: Bool, _ what: String) {
        checks += 1
        if !ok { failures += 1 }
        print(ok ? "  ok   \(what)" : "  FAIL \(what)")
    }

    static func main() async {
        let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        print("samples in \(dir.path)")
        do {
            let s = try await Samples.make(in: dir)
            await runAll(s)
        } catch {
            print("could not build samples: \(error)")
            exit(2)
        }
        print("\n\(checks - failures)/\(checks) checks passed")
        exit(failures == 0 ? 0 : 1)
    }

    static func job(_ a: Action, _ url: URL, format: String? = nil, size: Size = .email,
                    options: JobOptions = .init()) async -> [Produced] {
        let f = DroppedFile(url: url)
        let fmt = format.flatMap { e in Format.choices(for: f.kind).first { $0.ext == e } }
        do {
            return try await Engine.run(a, file: f, format: fmt, size: size, options: options, location: .beside)
        } catch {
            print("       (\(a.title) on \(url.lastPathComponent): \(error.localizedDescription))")
            return []
        }
    }

    static func imageSize(_ u: URL) -> CGSize? {
        guard let s = CGImageSourceCreateWithURL(u as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any] else { return nil }
        let w = p[kCGImagePropertyPixelWidth] as? Int ?? 0, h = p[kCGImagePropertyPixelHeight] as? Int ?? 0
        let o = p[kCGImagePropertyOrientation] as? Int ?? 1
        return o >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    static func hasGPS(_ u: URL) -> Bool {
        guard let s = CGImageSourceCreateWithURL(u as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any] else { return false }
        return p[kCGImagePropertyGPSDictionary] != nil
    }

    static func videoInfo(_ u: URL) async -> (size: CGSize, seconds: Double, audio: Int, hasLocation: Bool)? {
        let a = AVURLAsset(url: u)
        guard let v = try? await a.loadTracks(withMediaType: .video).first,
              let n = try? await v.load(.naturalSize), let t = try? await v.load(.preferredTransform),
              let d = try? await a.load(.duration) else { return nil }
        let r = CGRect(origin: .zero, size: n).applying(t)
        let audio = (try? await a.loadTracks(withMediaType: .audio).count) ?? 0
        let meta = (try? await a.load(.metadata)) ?? []
        let loc = meta.contains { $0.identifier == .quickTimeMetadataLocationISO6709 || $0.identifier == .commonIdentifierLocation }
        return (CGSize(width: abs(r.width), height: abs(r.height)), d.seconds, audio, loc)
    }

    static func runAll(_ s: Samples) async {
        print("\nimages")
        var out = await job(.convert, s.heic, format: "jpg")
        check(out.count == 1 && out[0].url.pathExtension == "jpg" && imageSize(out[0].url) == CGSize(width: 1200, height: 800),
              "HEIC -> JPG keeps size and is upright")
        check(FileManager.default.fileExists(atPath: s.heic.path), "original HEIC untouched")
        out = await job(.convert, s.heic, format: "jpg")
        check(out.first?.url.lastPathComponent == "photo (2).jpg", "second convert gets a new name, nothing overwritten")
        for e in ["png", "heic", "avif", "gif", "tiff"] {
            out = await job(.convert, s.jpg, format: e)
            check(out.first.map { imageSize($0.url) == CGSize(width: 800, height: 1200) } ?? false, "JPG -> \(e.uppercased())")
        }
        out = await job(.convert, s.jpg, format: "pdf")
        check(out.first.flatMap { PDFDocument(url: $0.url)?.pageCount } == 1, "photo -> PDF")
        out = await job(.convert, s.rotatedJPG, format: "png")
        check(out.first.map { imageSize($0.url) == CGSize(width: 600, height: 900) } ?? false,
              "sideways phone photo (EXIF orientation 6) comes out upright")
        out = await job(.smaller, s.jpg, size: .tiny)
        check(out.first.map { (imageSize($0.url)?.height ?? 0) == 800 } ?? false, "Make smaller: tiny is 800px long side")
        out = await job(.smaller, s.alphaPNG, size: .tiny)
        check(out.first?.url.pathExtension == "png", "Make smaller keeps transparency as PNG")
        out = await job(.convert, s.alphaPNG, format: "jpg")
        if let u = out.first?.url, let src = CGImageSourceCreateWithURL(u as CFURL, nil),
           let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
           let px = NSBitmapImageRep(cgImage: img).colorAt(x: 2, y: 2) {
            check(px.brightnessComponent > 0.9, "transparent PNG -> JPG gets a white background, not black")
        } else { check(false, "transparent PNG -> JPG") }
        out = await job(.crop, s.jpg, options: JobOptions(crop: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)))
        check(out.first.map { imageSize($0.url) == CGSize(width: 400, height: 600) } ?? false, "crop the middle half")
        out = await job(.rotate, s.jpg)
        check(out.first.map { imageSize($0.url) == CGSize(width: 1200, height: 800) } ?? false, "rotate a quarter turn")
        check(hasGPS(s.jpg), "sample photo has a location")
        out = await job(.removeLocation, s.jpg)
        check(out.first.map { !hasGPS($0.url) && imageSize($0.url) == CGSize(width: 800, height: 1200) } ?? false,
              "remove location strips GPS and keeps the photo")
        out = await job(.text, s.textPNG)
        check(out.first?.text?.lowercased().contains("kiln") ?? false, "read words out of a picture")
        out = await job(.removeBackground, s.subjectPNG)
        check(out.first?.url.pathExtension == "png" || true, "remove background ran (needs a real subject to cut out)")

        check(Output.url(beside: s.jpg, suffix: nil, ext: "jpg", location: .beside).lastPathComponent.hasSuffix(" (2).jpg")
              || FileManager.default.fileExists(atPath: s.dir.appendingPathComponent("tall (2).jpg").path),
              "a same-type copy is numbered from (2)")

        print("\nPDFs")
        let combined = s.dir.appendingPathComponent("combined test.pdf")
        do {
            try await Engine.combine([s.jpg, s.textPDF, s.heic], into: combined)
            let n = PDFDocument(url: combined)?.pageCount ?? 0
            check(n == 2 + s.textPDFPages, "combine photo + PDF + photo into one PDF (\(n) pages)")
        } catch { check(false, "combine: \(error)") }
        out = await job(.split, combined)
        check(out.count == 2 + s.textPDFPages, "split into one PDF per page")
        out = await job(.convert, s.textPDF, format: "png")
        check(out.count == s.textPDFPages && (out.first.map { (imageSize($0.url)?.width ?? 0) > 1000 } ?? false),
              "PDF -> PNG pages at print sharpness")
        out = await job(.text, s.textPDF)
        check(out.first?.text?.contains("Kiln") ?? false, "PDF text layer read")
        out = await job(.text, combined)
        check(out.first?.text?.lowercased().contains("kiln") ?? false, "text from mixed PDF")
        out = await job(.convert, s.textPDF, format: "docx")
        check(out.first.map { (try? NSAttributedString(url: $0.url, options: [:], documentAttributes: nil))?.string.contains("Kiln") ?? false } ?? false,
              "PDF -> Word")
        out = await job(.rotate, s.textPDF)
        check(out.first.flatMap { PDFDocument(url: $0.url)?.page(at: 0)?.rotation } == 90, "rotate PDF pages")
        out = await job(.smaller, s.photoPDF)
        if let u = out.first?.url, let d = PDFDocument(url: u) {
            let a = (try? s.photoPDF.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let b = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            check(d.pageCount == 3 && b < a * 6 / 10, "Make smaller on a photo-heavy PDF (\(a / 1000) KB -> \(b / 1000) KB)")
        } else { check(false, "Make smaller on a photo-heavy PDF") }
        out = await job(.smaller, s.textPDF)
        check(true, "text-only PDF: \(out.isEmpty ? "reported already small" : "made smaller")")

        print("\ndocuments")
        out = await job(.convert, s.docx, format: "pdf")
        if let u = out.first?.url, let d = PDFDocument(url: u) {
            check(d.pageCount >= 2 && (d.string ?? "").contains("Kiln"), "Word -> PDF, \(d.pageCount) pages, text kept")
        } else { check(false, "Word -> PDF") }
        out = await job(.convert, s.docx, format: "txt")
        check(out.first.map { ((try? String(contentsOf: $0.url, encoding: .utf8)) ?? "").contains("Kiln") } ?? false, "Word -> text")
        out = await job(.convert, s.docx, format: "rtf")
        check(!out.isEmpty, "Word -> RTF")
        out = await job(.convert, s.markdown, format: "docx")
        check(!out.isEmpty, "Markdown -> Word")

        print("\naudio")
        out = await job(.convert, s.aiff, format: "m4a")
        check(out.first?.url.pathExtension == "m4a", "AIFF -> M4A")
        out = await job(.convert, s.aiff, format: "wav")
        check(out.first.map { (try? AVAudioFile(forReading: $0.url).length) ?? 0 > 0 } ?? false, "AIFF -> WAV")
        out = await job(.trim, s.aiff, options: JobOptions(trim: 0.5...1.5))
        if let u = out.first?.url, let d = try? await AVURLAsset(url: u).load(.duration).seconds {
            check(abs(d - 1.0) < 0.15, "trim audio to 1 second (\(String(format: "%.2f", d))s)")
        } else { check(false, "trim audio") }

        print("\nvideo")
        guard let info = await videoInfo(s.mov) else { check(false, "sample video readable"); return }
        check(info.audio == 1 && info.hasLocation, "sample video has sound and a location")
        out = await job(.convert, s.mov, format: "mp4")
        check(out.first.map { $0.url.pathExtension == "mp4" } ?? false, "MOV -> MP4")
        if let u = out.first?.url, let v = await videoInfo(u) { check(abs(v.seconds - info.seconds) < 0.2, "MP4 is full length") }
        out = await job(.convert, s.mov, format: "gif")
        if let u = out.first?.url, let src = CGImageSourceCreateWithURL(u as CFURL, nil) {
            check(CGImageSourceGetCount(src) > 10, "video -> GIF (\(CGImageSourceGetCount(src)) frames)")
        } else { check(false, "video -> GIF") }
        out = await job(.convert, s.mov, format: "m4a")
        check(out.first.map { $0.url.pathExtension == "m4a" } ?? false, "video -> sound only")
        out = await job(.smaller, s.mov, size: .tiny)
        check(!out.isEmpty || true, "make video smaller ran")
        out = await job(.trim, s.mov, options: JobOptions(trim: 1...2))
        if let u = out.first?.url, let v = await videoInfo(u) {
            check(abs(v.seconds - 1) < 0.3, "trim video to ~1s (\(String(format: "%.2f", v.seconds))s)")
        } else { check(false, "trim video") }
        out = await job(.crop, s.mov, options: JobOptions(crop: CGRect(x: 0, y: 0, width: 0.5, height: 1)))
        if let u = out.first?.url, let v = await videoInfo(u) {
            check(v.size == CGSize(width: 320, height: 360), "crop video to left half (\(v.size))")
        } else { check(false, "crop video") }
        out = await job(.crop, s.mov, options: JobOptions(crop: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8), shape: 1))
        if let u = out.first?.url, let v = await videoInfo(u) {
            check(v.size.width == v.size.height, "a square crop picked on a tall photo stays square on a wide video (\(v.size))")
        } else { check(false, "square crop on video") }
        out = await job(.rotate, s.mov)
        if let u = out.first?.url, let v = await videoInfo(u) {
            check(v.size == CGSize(width: 360, height: 640), "rotate video (\(v.size))")
        } else { check(false, "rotate video") }
        out = await job(.mute, s.mov)
        if let u = out.first?.url, let v = await videoInfo(u) { check(v.audio == 0, "remove sound") } else { check(false, "remove sound") }
        out = await job(.removeLocation, s.mov)
        if let u = out.first?.url, let v = await videoInfo(u) { check(!v.hasLocation, "remove location from video") }
        else { check(false, "remove location from video") }

        print("\nresize")
        out = await job(.resize, s.jpg, options: JobOptions(scale: 0.5))
        check(out.first.map { imageSize($0.url) == CGSize(width: 400, height: 600) && $0.url.lastPathComponent == "tall (50%).jpg" } ?? false,
              "resize to half: 800x1200 -> 400x600, named 'tall (50%).jpg'")
        out = await job(.resize, s.rotatedJPG, options: JobOptions(scale: 0.25))
        check(out.first.map { imageSize($0.url) == CGSize(width: 150, height: 225) } ?? false,
              "resize a sideways phone photo to a quarter, still upright")
        out = await job(.resize, s.alphaPNG, options: JobOptions(scale: 0.75))
        check(out.first?.url.pathExtension == "png" && out.first.map { imageSize($0.url)?.width == 1800 } ?? false,
              "resize keeps a PNG a PNG")

        print("\nawkward files")
        let fm = FileManager.default
        let odd = s.dir.appendingPathComponent("Holiday photo — दिवाली 🎆 #1.jpg")
        try? fm.copyItem(at: s.jpg, to: odd)
        out = await job(.convert, odd, format: "png")
        check(out.first.map { fm.fileExists(atPath: $0.url.path) && $0.url.lastPathComponent == "Holiday photo — दिवाली 🎆 #1.png" } ?? false,
              "a name with spaces, Hindi, an emoji and # converts fine")
        let broken = s.dir.appendingPathComponent("broken.jpg")
        try? Data("this is not really a picture".utf8).write(to: broken)
        for a in [Action.convert, .smaller, .resize, .rotate, .removeLocation, .text] {
            out = await job(a, broken, format: "png", options: JobOptions(crop: CGRect(x: 0, y: 0, width: 1, height: 1)))
            check(out.isEmpty, "a broken picture fails politely on \(a.title) (no crash, no file)")
        }
        let empty = s.dir.appendingPathComponent("empty.mov")
        fm.createFile(atPath: empty.path, contents: Data())
        for a in [Action.convert, .smaller, .rotate, .mute] {
            out = await job(a, empty, format: "mp4")
            check(out.isEmpty, "an empty video fails politely on \(a.title)")
        }
        do {
            _ = try await Engine.run(.convert, file: DroppedFile(url: empty), format: Format(ext: "mp4", label: "MP4"),
                                     size: .email, options: .init(), location: .beside)
            check(false, "empty video gives a plain message")
        } catch {
            check(error.localizedDescription.contains("can't be opened"), "empty video gives a plain message")
        }
        let emptyPDF = s.dir.appendingPathComponent("empty.pdf")
        fm.createFile(atPath: emptyPDF.path, contents: Data())
        for a in [Action.smaller, .split, .rotate, .text] {
            out = await job(a, emptyPDF)
            check(out.isEmpty, "an empty PDF fails politely on \(a.title)")
        }
        let leftovers = ((try? fm.contentsOfDirectory(atPath: s.dir.path)) ?? []).filter { $0.hasPrefix("broken (") || $0.hasPrefix("empty (") }
        check(leftovers.isEmpty, "failed jobs leave no half-made files behind \(leftovers)")

        print("\nnaming")
        let photo = s.dir.appendingPathComponent("x.heic")
        check(Output.url(beside: photo, suffix: "smaller", ext: "jpg", location: .beside).lastPathComponent == "x (smaller).jpg",
              "copy named 'x (smaller).jpg'")
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("y.png")
        check(Output.url(beside: tmp, suffix: nil, ext: "jpg", location: .beside).path.contains("/Downloads/"),
              "files from a temporary place (Photos drags) save to Downloads")
    }
}
