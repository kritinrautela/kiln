import AppKit
import AVFoundation
import CoreImage
import ImageIO
import PDFKit
import Quartz
import UniformTypeIdentifiers
import Vision

struct Produced {
    let url: URL
    var text: String? = nil
}

/// All the file work. Apple frameworks only, nothing leaves the Mac.
enum Engine {
    static func run(_ action: Action, file f: DroppedFile, format: Format?, size: Size, options: JobOptions,
                    location: SaveLocation) async throws -> [Produced] {
        let src = f.url
        func out(_ suffix: String?, _ ext: String) -> URL {
            Output.url(beside: src, suffix: suffix, ext: ext, location: location)
        }
        let ext = src.pathExtension.lowercased()

        if f.kind == .video || f.kind == .audio {   // say it plainly up front instead of a framework error later
            let asset = AVURLAsset(url: src)
            let readable = (try? await asset.load(.isReadable)) ?? false
            let tracks = (try? await asset.load(.tracks)) ?? []
            guard readable, !tracks.isEmpty else {
                throw KilnError(f.kind == .video ? "This video can't be opened. It may be damaged or still downloading."
                                                 : "This sound file can't be opened. It may be damaged or still downloading.")
            }
        }

        switch (action, f.kind) {
        case (.convert, _):
            guard let format else { throw KilnError("Pick a format first.") }
            return try await convert(f, to: format, out: out)

        case (.smaller, .image):
            let s = try source(src)
            let img = try oriented(s, maxPixels: size.imagePixels)
            let keepPNG = hasAlpha(img)
            let o = out("smaller", keepPNG ? "png" : "jpg")
            try write(img, to: o, ext: keepPNG ? "png" : "jpg", props: props(s, quality: size.imageQuality))
            return [try notBigger(o, than: f.size)]

        case (.smaller, .video):
            let preset: String = switch size {
            case .light: AVAssetExportPresetHEVC1920x1080
            case .email: AVAssetExportPreset1280x720
            case .tiny: AVAssetExportPreset960x540
            }
            let o = out("smaller", "mp4")
            try await export(AVURLAsset(url: src), preset: preset, to: o)
            return [try notBigger(o, than: f.size)]

        case (.smaller, .pdf):
            let doc = try pdf(src)
            let o = out("smaller", "pdf")
            guard doc.write(to: o, withOptions: [PDFDocumentWriteOption(rawValue: "QuartzFilter"): shrinkFilter(size)])
            else { throw KilnError("Couldn't save the smaller PDF.") }
            return [try notBigger(o, than: f.size)]

        case (.resize, .image):
            let s = try source(src)
            let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any] ?? [:]
            let longest = max(p[kCGImagePropertyPixelWidth] as? Int ?? 0, p[kCGImagePropertyPixelHeight] as? Int ?? 0)
            guard longest > 1 else { throw KilnError("Couldn't read this picture's size.") }
            let scale = min(max(options.scale, 0.05), 1)
            let img = try oriented(s, maxPixels: max(1, Int((Double(longest) * scale).rounded())))
            let e = writable(ext) ? ext : "jpg"
            let o = out("\(Int((scale * 100).rounded()))%", e)
            try write(img, to: o, ext: e, props: props(s, quality: 0.9))
            return [.init(url: o)]

        case (.crop, .image):
            guard let r = options.crop else { throw KilnError("No crop was chosen.") }
            let s = try source(src)
            let img = try oriented(s)
            let px = shaped(r, options.shape, CGFloat(img.width), CGFloat(img.height)).integral
            guard let cut = img.cropping(to: px) else { throw KilnError("That crop is outside the picture.") }
            let e = writable(ext) ? ext : "jpg"
            let o = out("cropped", e)
            try write(cut, to: o, ext: e, props: props(s, quality: 0.92))
            return [.init(url: o)]

        case (.crop, .video):
            guard let r = options.crop else { throw KilnError("No crop was chosen.") }
            let o = out("cropped", videoExt(ext))
            try await cropVideo(src, rect: r, shape: options.shape, to: o)
            return [.init(url: o)]

        case (.trim, .video), (.trim, .audio):
            guard let t = options.trim else { throw KilnError("No trim was chosen.") }
            let asset = AVURLAsset(url: src)
            let range = CMTimeRange(start: CMTime(seconds: t.lowerBound, preferredTimescale: 600),
                                    end: CMTime(seconds: t.upperBound, preferredTimescale: 600))
            if f.kind == .audio {
                let o = out("trimmed", "m4a")
                try await export(asset, preset: AVAssetExportPresetAppleM4A, to: o, timeRange: range)
                return [.init(url: o)]
            }
            let o = out("trimmed", videoExt(ext))
            try await exportKeepingQuality(asset, to: o, timeRange: range)
            return [.init(url: o)]

        case (.removeBackground, .image):
            let o = out("cut out", "png")
            try removeBackground(src, to: o)
            return [.init(url: o)]

        case (.text, _):
            let text: String
            switch f.kind {
            case .image: text = try ocr(try oriented(try source(src)))
            case .pdf: text = try pdfText(src)
            default: text = try await MainActor.run { try readDocument(src).string }
            }
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { throw KilnError("No words were found in this \(f.kind.noun).") }
            let o = out("text", "txt")
            try clean.write(to: o, atomically: true, encoding: .utf8)
            return [.init(url: o, text: clean)]

        case (.rotate, .image):
            let s = try source(src)
            let img = try oriented(s)
            let e = writable(ext) ? ext : "jpg"
            let o = out("rotated", e)
            try write(rotated(img), to: o, ext: e, props: props(s, quality: 0.92))
            return [.init(url: o)]

        case (.rotate, .pdf):
            let doc = try pdf(src)
            for i in 0..<doc.pageCount { if let p = doc.page(at: i) { p.rotation = (p.rotation + 90) % 360 } }
            let o = out("rotated", "pdf")
            guard doc.write(to: o) else { throw KilnError("Couldn't save the rotated PDF.") }
            return [.init(url: o)]

        case (.rotate, .video):
            let o = out("rotated", videoExt(ext))
            try await exportKeepingQuality(try await rebuilt(AVURLAsset(url: src), keepAudio: true, rotate: true), to: o)
            return [.init(url: o)]

        case (.mute, .video):
            let o = out("no sound", videoExt(ext))
            try await exportKeepingQuality(try await rebuilt(AVURLAsset(url: src), keepAudio: false, rotate: false), to: o)
            return [.init(url: o)]

        case (.removeLocation, .image):
            let s = try source(src)
            let type = CGImageSourceGetType(s) ?? UTType.jpeg.identifier as CFString
            let o = out("no location", ext.isEmpty ? "jpg" : ext)
            guard let d = CGImageDestinationCreateWithURL(o as CFURL, type, 1, nil) else {
                throw KilnError("Couldn't save this picture.")
            }
            let opts: [CFString: Any] = [kCGImageMetadataShouldExcludeGPS: true]
            var err: Unmanaged<CFError>?
            if !CGImageDestinationCopyImageSource(d, s, opts as CFDictionary, &err) {
                // Some formats can't be copied untouched; re-save without GPS instead.
                guard let d2 = CGImageDestinationCreateWithURL(o as CFURL, type, 1, nil) else {
                    throw KilnError("Couldn't save this picture.")
                }
                var p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any] ?? [:]
                p[kCGImagePropertyGPSDictionary] = nil
                CGImageDestinationAddImageFromSource(d2, s, 0, p as CFDictionary)
                guard CGImageDestinationFinalize(d2) else { throw KilnError("Couldn't save this picture.") }
            }
            return [.init(url: o)]

        case (.removeLocation, .video):
            let o = out("no location", videoExt(ext))
            try await exportKeepingQuality(AVURLAsset(url: src), to: o, filter: .forSharing())
            return [.init(url: o)]

        case (.split, .pdf):
            let doc = try pdf(src)
            guard doc.pageCount > 1 else { throw KilnError("This PDF only has one page.") }
            var made: [Produced] = []
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
                let one = PDFDocument()
                one.insert(page, at: 0)
                let o = out("page \(i + 1)", "pdf")
                guard one.write(to: o) else { throw KilnError("Couldn't save page \(i + 1).") }
                made.append(.init(url: o))
            }
            return made

        default:
            throw KilnError("\(action.title) doesn't work on a \(f.kind.noun).")
        }
    }

    static func combine(_ urls: [URL], into out: URL) async throws {
        let doc = PDFDocument()
        for u in urls {
            if FileKind.of(u) == .pdf {
                let other = try pdf(u)
                for i in 0..<other.pageCount {
                    if let p = other.page(at: i)?.copy() as? PDFPage { doc.insert(p, at: doc.pageCount) }
                }
            } else {
                doc.insert(try imagePage(u), at: doc.pageCount)
            }
        }
        guard doc.pageCount > 0, doc.write(to: out) else { throw KilnError("Couldn't make the combined PDF.") }
    }

    // MARK: Convert

    private static func convert(_ f: DroppedFile, to format: Format,
                                out: (String?, String) -> URL) async throws -> [Produced] {
        let src = f.url
        switch f.kind {
        case .image:
            let o = out(nil, format.ext)
            if format.ext == "pdf" {
                try await combine([src], into: o)
            } else {
                let s = try source(src)
                try write(try oriented(s), to: o, ext: format.ext, props: props(s, quality: 0.9))
            }
            return [.init(url: o)]

        case .video:
            let asset = AVURLAsset(url: src)
            let o = out(nil, format.ext)
            switch format.ext {
            case "gif": try await videoToGIF(asset, to: o)
            case "m4a": try await export(asset, preset: AVAssetExportPresetAppleM4A, to: o)
            default: try await exportKeepingQuality(asset, to: o)
            }
            return [.init(url: o)]

        case .audio:
            let o = out(nil, format.ext)
            if format.ext == "m4a" {
                try await export(AVURLAsset(url: src), preset: AVAssetExportPresetAppleM4A, to: o)
            } else {
                try toPCM(src, o, bigEndian: format.ext == "aiff")
            }
            return [.init(url: o)]

        case .pdf:
            switch format.ext {
            case "txt", "docx":
                let text = try pdfText(src)
                let o = out(nil, format.ext)
                if format.ext == "txt" {
                    try text.write(to: o, atomically: true, encoding: .utf8)
                } else {
                    try await MainActor.run {
                        try writeDocument(NSAttributedString(string: text, attributes: plainAttributes), to: o, ext: "docx")
                    }
                }
                return [.init(url: o)]
            default:
                let doc = try pdf(src)
                var made: [Produced] = []
                for i in 0..<doc.pageCount {
                    guard let page = doc.page(at: i) else { continue }
                    let o = out(doc.pageCount == 1 ? nil : "page \(i + 1)", format.ext)
                    try write(render(page, dpi: 200), to: o, ext: format.ext, props: nil)
                    made.append(.init(url: o))
                }
                return made
            }

        case .document:
            let o = out(nil, format.ext)
            try await MainActor.run { try writeDocument(try readDocument(src), to: o, ext: format.ext) }
            return [.init(url: o)]

        case .other:
            throw KilnError("Kiln doesn't know this kind of file yet.")
        }
    }

    // MARK: Images

    static func source(_ url: URL) throws -> CGImageSource {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(s) > 0 else {
            throw KilnError("This picture can't be opened.")
        }
        return s
    }

    /// The picture the right way up, optionally shrunk so its longest side is at most `maxPixels`.
    static func oriented(_ s: CGImageSource, maxPixels: Int? = nil) throws -> CGImage {
        let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any] ?? [:]
        let full = max(p[kCGImagePropertyPixelWidth] as? Int ?? 0, p[kCGImagePropertyPixelHeight] as? Int ?? 0, 1)
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixels ?? full, full),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(s, 0, opts as CFDictionary) else {
            throw KilnError("This picture can't be read.")
        }
        return img
    }

    /// The original's metadata (dates, camera) with orientation reset, since pixels are now upright.
    static func props(_ s: CGImageSource, quality: Double?) -> CFDictionary {
        var p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any] ?? [:]
        p[kCGImagePropertyOrientation] = 1
        if var tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            p[kCGImagePropertyTIFFDictionary] = tiff
        }
        for k in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight] { p[k] = nil }
        if let quality { p[kCGImageDestinationLossyCompressionQuality] = quality }
        return p as CFDictionary
    }

    static func writable(_ ext: String) -> Bool {
        ["jpg", "jpeg", "png", "heic", "heif", "avif", "gif", "tif", "tiff"].contains(ext)
    }

    static func hasAlpha(_ img: CGImage) -> Bool {
        [.first, .last, .premultipliedFirst, .premultipliedLast].contains(img.alphaInfo)
    }

    static func write(_ img: CGImage, to url: URL, ext: String, props: CFDictionary?) throws {
        let e = ext.lowercased()
        let type = UTType(filenameExtension: e) ?? .jpeg
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw KilnError("Can't save as \(e.uppercased()) on this Mac.")
        }
        let flat = ["jpg", "jpeg"].contains(e) && hasAlpha(img) ? flattened(img) : img
        CGImageDestinationAddImage(d, flat, props)
        guard CGImageDestinationFinalize(d) else { throw KilnError("Couldn't save the \(e.uppercased()).") }
    }

    /// JPG has no see-through parts, so put transparent pictures on white rather than black.
    static func flattened(_ img: CGImage) -> CGImage {
        let rect = CGRect(x: 0, y: 0, width: img.width, height: img.height)
        guard let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return img }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(img, in: rect)
        return ctx.makeImage() ?? img
    }

    static func rotated(_ img: CGImage) -> CGImage {
        let w = img.width, h = img.height
        guard let ctx = CGContext(data: nil, width: h, height: w, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: img.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return img }
        // Quarter turn clockwise.
        ctx.translateBy(x: 0, y: CGFloat(w))
        ctx.rotate(by: -.pi / 2)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? img
    }

    static func imagePage(_ url: URL) throws -> PDFPage {
        let img = try oriented(try source(url))
        let w = CGFloat(img.width), h = CGFloat(img.height)
        let long: CGFloat = 842   // A4's long side, in points
        let box = w >= h ? CGRect(x: 0, y: 0, width: long, height: long * h / w)
                         : CGRect(x: 0, y: 0, width: long * w / h, height: long)
        let ns = NSImage(cgImage: img, size: NSSize(width: w, height: h))
        guard let page = PDFPage(image: ns, options: [.mediaBox: box, .compressionQuality: 0.85]) else {
            throw KilnError("Couldn't put \(url.lastPathComponent) into a PDF.")
        }
        return page
    }

    static func removeBackground(_ src: URL, to out: URL) throws {
        let img = try oriented(try source(src))
        let req = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: img)
        try handler.perform([req])
        guard let result = req.results?.first, !result.allInstances.isEmpty else {
            throw KilnError("Couldn't find a person or object to keep in this photo.")
        }
        let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler,
                                                    croppedToInstancesExtent: false)
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let cg = CIContext().createCGImage(ci, from: ci.extent) else {
            throw KilnError("Couldn't make the cut-out.")
        }
        try write(cg, to: out, ext: "png", props: nil)
    }

    static func ocr(_ img: CGImage) throws -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        req.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: img).perform([req])
        return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    // MARK: PDFs

    static func pdf(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw KilnError("This PDF can't be opened.") }
        guard !doc.isLocked else { throw KilnError("This PDF has a password. Open it in Preview first.") }
        return doc
    }

    static func render(_ page: PDFPage, dpi: CGFloat) -> CGImage {
        let box = page.bounds(for: .mediaBox)
        let turned = page.rotation % 180 != 0
        let size = NSSize(width: (turned ? box.height : box.width) * dpi / 72,
                          height: (turned ? box.width : box.height) * dpi / 72)
        let ns = page.thumbnail(of: size, for: .mediaBox)
        var rect = CGRect(origin: .zero, size: ns.size)
        return ns.cgImage(forProposedRect: &rect, context: nil, hints: nil) ?? flattened(
            CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!)
    }

    /// Text layer if there is one; otherwise read the pages like a scan.
    static func pdfText(_ url: URL) throws -> String {
        let doc = try pdf(url)
        let s = doc.string ?? ""
        if s.unicodeScalars.filter(CharacterSet.letters.contains).count >= 10 * max(doc.pageCount, 1) / 2 { return s }
        var pages: [String] = []
        for i in 0..<doc.pageCount {
            if let p = doc.page(at: i) { pages.append(try ocr(render(p, dpi: 200))) }
        }
        return pages.joined(separator: "\n\n")
    }

    // MARK: Documents

    static let plainAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black,
    ]

    @MainActor
    static func readDocument(_ url: URL) throws -> NSAttributedString {
        let ext = url.pathExtension.lowercased()
        if ["txt", "text", "md", "markdown"].contains(ext) {
            var enc = String.Encoding.utf8
            let s = try (try? String(contentsOf: url, usedEncoding: &enc)) ?? String(contentsOf: url, encoding: .isoLatin1)
            return NSAttributedString(string: s, attributes: plainAttributes)
        }
        let type: NSAttributedString.DocumentType = switch ext {
        case "docx": .officeOpenXML
        case "doc": .docFormat
        case "rtf": .rtf
        case "rtfd": .rtfd
        case "odt": .openDocument
        case "webarchive": .webArchive
        default: .html
        }
        do {
            return try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil)
        } catch {
            throw KilnError("This document can't be opened. If it's a Pages file, export it from Pages first.")
        }
    }

    @MainActor
    static func writeDocument(_ text: NSAttributedString, to out: URL, ext: String) throws {
        let range = NSRange(location: 0, length: text.length)
        switch ext {
        case "pdf":
            try printPDF(text, to: out)
        case "txt":
            try text.string.write(to: out, atomically: true, encoding: .utf8)
        default:
            let type: NSAttributedString.DocumentType = ext == "rtf" ? .rtf : .officeOpenXML
            let data = try text.data(from: range, documentAttributes: [.documentType: type])
            try data.write(to: out)
        }
    }

    /// Lays the document out on pages the size this Mac prints on, and saves those pages as a PDF.
    @MainActor
    static func printPDF(_ text: NSAttributedString, to out: URL) throws {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = out
        for m in [\NSPrintInfo.leftMargin, \.rightMargin, \.topMargin, \.bottomMargin] { info[keyPath: m] = 56 }
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        view.textStorage?.setAttributedString(text)
        view.backgroundColor = .white
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        let used = view.layoutManager?.usedRect(for: view.textContainer!).height ?? 10
        view.setFrameSize(NSSize(width: width, height: max(used + 20, 10)))
        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run(), FileManager.default.fileExists(atPath: out.path) else {
            throw KilnError("Couldn't make the PDF.")
        }
    }

    // MARK: Video and audio

    static func videoExt(_ ext: String) -> String { ["mp4", "m4v", "mov"].contains(ext) ? ext : "mov" }

    static func fileType(_ url: URL) -> AVFileType {
        switch url.pathExtension.lowercased() {
        case "mp4": .mp4
        case "m4v": .m4v
        case "m4a": .m4a
        default: .mov
        }
    }

    static func export(_ asset: AVAsset, preset: String, to out: URL, timeRange: CMTimeRange? = nil,
                       composition: AVVideoComposition? = nil, filter: AVMetadataItemFilter? = nil) async throws {
        guard let s = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw KilnError("This can't be saved that way.")
        }
        if let timeRange { s.timeRange = timeRange }
        if let composition { s.videoComposition = composition }
        if let filter { s.metadataItemFilter = filter }
        s.shouldOptimizeForNetworkUse = true
        do {
            try await s.export(to: out, as: fileType(out))
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
    }

    /// Copies the picture and sound untouched when the format allows it (fast, no quality loss),
    /// otherwise re-encodes at the highest quality.
    static func exportKeepingQuality(_ asset: AVAsset, to out: URL, timeRange: CMTimeRange? = nil,
                                     filter: AVMetadataItemFilter? = nil) async throws {
        do {
            try await export(asset, preset: AVAssetExportPresetPassthrough, to: out, timeRange: timeRange, filter: filter)
        } catch {
            try await export(asset, preset: AVAssetExportPresetHighestQuality, to: out, timeRange: timeRange,
                             filter: filter)
        }
    }

    static func rebuilt(_ asset: AVURLAsset, keepAudio: Bool, rotate: Bool) async throws -> AVMutableComposition {
        let comp = AVMutableComposition()
        var sawVideo = false
        for track in try await asset.load(.tracks) {
            let type = track.mediaType
            guard type == .video || (type == .audio && keepAudio) else { continue }
            guard let ct = comp.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            let range = try await track.load(.timeRange)
            try ct.insertTimeRange(range, of: track, at: range.start)
            if type == .video {
                sawVideo = true
                var t = try await track.load(.preferredTransform)
                if rotate {
                    let r = CGRect(origin: .zero, size: try await track.load(.naturalSize)).applying(t)
                    t = t.concatenating(CGAffineTransform(translationX: -r.minX, y: -r.minY))
                        .concatenating(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: r.height, ty: 0))
                }
                ct.preferredTransform = t
            }
        }
        guard sawVideo else { throw KilnError("This file has no picture.") }
        return comp
    }

    static func cropVideo(_ src: URL, rect r: CGRect, shape: CGFloat?, to out: URL) async throws {
        let asset = AVURLAsset(url: src)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw KilnError("This file has no picture.")
        }
        let natural = try await track.load(.naturalSize)
        let t = try await track.load(.preferredTransform)
        let fps = try await track.load(.nominalFrameRate)
        let duration = try await asset.load(.duration)
        let shown = CGRect(origin: .zero, size: natural).applying(t)
        let W = abs(shown.width), H = abs(shown.height)
        func even(_ v: CGFloat) -> CGFloat { max(2, (v / 2).rounded(.down) * 2) }
        let p = shaped(r, shape, W, H)
        let crop = CGRect(x: p.minX.rounded(), y: p.minY.rounded(), width: even(p.width), height: even(p.height))

        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(t.concatenating(CGAffineTransform(translationX: -shown.minX - crop.minX,
                                                             y: -shown.minY - crop.minY)), at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layer]
        let comp = AVMutableVideoComposition()
        comp.renderSize = crop.size
        comp.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps > 0 ? fps.rounded() : 30))
        comp.instructions = [instruction]
        try await export(asset, preset: AVAssetExportPresetHighestQuality, to: out, composition: comp)
    }

    static func videoToGIF(_ asset: AVURLAsset, to out: URL) async throws {
        let seconds = try await asset.load(.duration).seconds
        guard seconds > 0 else { throw KilnError("This video has no length.") }
        let fps = min(12, 240 / seconds)
        let count = max(1, Int(seconds * fps))
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 480, height: 480)
        gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 24)
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 24)
        let times = (0..<count).map { CMTime(seconds: Double($0) / fps, preferredTimescale: 600) }
        guard let d = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw KilnError("Couldn't make the GIF.")
        }
        CGImageDestinationSetProperties(d, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frame = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        var added = 0
        for await result in gen.images(for: times) {
            if let img = try? result.image {
                CGImageDestinationAddImage(d, img, frame)
                added += 1
            }
        }
        guard added > 0, CGImageDestinationFinalize(d) else { throw KilnError("Couldn't make the GIF.") }
    }

    static func toPCM(_ src: URL, _ out: URL, bigEndian: Bool) throws {
        let input = try AVAudioFile(forReading: src)
        let fmt = input.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: fmt.sampleRate,
            AVNumberOfChannelsKey: fmt.channelCount, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: bigEndian,
        ]
        let output = try AVAudioFile(forWriting: out, settings: settings, commonFormat: fmt.commonFormat,
                                     interleaved: fmt.isInterleaved)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 1 << 16) else {
            throw KilnError("Couldn't read the sound.")
        }
        while input.framePosition < input.length {
            try input.read(into: buf)
            if buf.frameLength == 0 { break }
            try output.write(from: buf)
        }
    }

    // MARK: Helpers

    /// The crop box in pixels. When a shape was picked, every file keeps that shape even if it is
    /// taller or wider than the one shown on screen: the box shrinks around its own centre to fit.
    static func shaped(_ r: CGRect, _ shape: CGFloat?, _ W: CGFloat, _ H: CGFloat) -> CGRect {
        var w = r.width * W, h = r.height * H
        guard let shape, shape > 0 else { return CGRect(x: r.minX * W, y: r.minY * H, width: w, height: h) }
        if w / h > shape { w = h * shape } else { h = w / shape }
        let x = min(max(r.midX * W - w / 2, 0), W - w), y = min(max(r.midY * H - h / 2, 0), H - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// The same machinery as Preview's "Reduce File Size", tuned per size. Text stays sharp; only pictures shrink.
    static func shrinkFilter(_ size: Size) -> QuartzFilter {
        let (dpi, quality): (Double, Double) = switch size {
        case .light: (200, 0.8)
        case .email: (144, 0.7)
        case .tiny: (96, 0.55)
        }
        let settings: [String: Any] = [
            "Compression Quality": quality, "ImageCompression": "ImageJPEGCompress",
            "ImageScaleSettings": ["ImageResolution": dpi, "ImageScaleInterpolate": true,
                                   "ImageSizeMax": 3000, "ImageSizeMin": 0],
        ]
        return QuartzFilter(properties: [
            "Domains": ["Applications": true], "FilterType": 1, "Name": "Kiln",
            "FilterData": ["ColorSettings": ["ImageSettings": settings]],
        ])
    }

    /// A "smaller" copy that came out bigger is useless; drop it and say so plainly.
    static func notBigger(_ url: URL, than original: Int64) throws -> Produced {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        if original > 0, size >= original {
            try? FileManager.default.removeItem(at: url)
            throw KilnError("Already as small as it gets.")
        }
        return .init(url: url)
    }
}
