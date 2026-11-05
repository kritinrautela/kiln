import AppKit
import AVFoundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Made-up test files. Nothing personal is ever used.
struct Samples {
    let dir: URL
    var heic, jpg, rotatedJPG, alphaPNG, textPNG, subjectPNG, textPDF, photoPDF, docx, markdown, aiff, mov: URL
    var textPDFPages = 0

    static func make(in dir: URL) async throws -> Samples {
        func u(_ n: String) -> URL { dir.appendingPathComponent(n) }
        var s = Samples(dir: dir, heic: u("photo.heic"), jpg: u("tall.jpg"), rotatedJPG: u("sideways.jpg"),
                        alphaPNG: u("logo.png"), textPNG: u("words.png"), subjectPNG: u("subject.png"),
                        textPDF: u("letter.pdf"), photoPDF: u("scans.pdf"), docx: u("essay.docx"),
                        markdown: u("notes.md"), aiff: u("voice.aiff"), mov: u("clip.mov"))
        try write(picture(1200, 800), s.heic, nil)
        try write(picture(800, 1200), s.jpg, [kCGImagePropertyGPSDictionary: [
            kCGImagePropertyGPSLatitude: 31.95, kCGImagePropertyGPSLatitudeRef: "S",
            kCGImagePropertyGPSLongitude: 115.86, kCGImagePropertyGPSLongitudeRef: "E"]])
        try write(picture(900, 600), s.rotatedJPG, [kCGImagePropertyOrientation: 6])
        try write(circle(2400), s.alphaPNG, nil)
        try write(words("Hello from Kiln", 1200, 300), s.textPNG, nil)
        try write(circle(600), s.subjectPNG, nil)
        let essay = String(repeating: "Kiln turns one file into the one you need. Originals are never touched. ", count: 120)
        try await MainActor.run {
            try Engine.printPDF(NSAttributedString(string: essay, attributes: Engine.plainAttributes), to: s.textPDF)
            let data = try NSAttributedString(string: essay, attributes: Engine.plainAttributes)
                .data(from: NSRange(location: 0, length: (essay as NSString).length),
                      documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
            try data.write(to: s.docx)
        }
        s.textPDFPages = PDFDocument(url: s.textPDF)?.pageCount ?? 0
        let big = u("big noisy.jpg")
        try write(noise(3000, 2000), big, [kCGImageDestinationLossyCompressionQuality: 1.0])
        try await Engine.combine([big, big, big], into: s.photoPDF)
        try "# Notes\n\nKiln test notes.\n".write(to: s.markdown, atomically: true, encoding: .utf8)

        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", s.aiff.path, "Hello from Kiln. Testing one, two, three, four."]
        try say.run()
        say.waitUntilExit()
        try await movie(s.mov, audio: s.aiff, scratch: u("frames only.mov"))
        return s
    }

    static func ctx(_ w: Int, _ h: Int, alpha: Bool = false) -> CGContext {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue)!
    }

    static func picture(_ w: Int, _ h: Int) -> CGImage {
        let c = ctx(w, h)
        c.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        c.setFillColor(CGColor(red: 0.95, green: 0.6, blue: 0.1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: w / 3, height: h / 3))
        return c.makeImage()!
    }

    static func circle(_ side: Int) -> CGImage {
        let c = ctx(side, side, alpha: true)
        c.clear(CGRect(x: 0, y: 0, width: side, height: side))
        c.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.2, alpha: 1))
        c.fillEllipse(in: CGRect(x: side / 4, y: side / 4, width: side / 2, height: side / 2))
        return c.makeImage()!
    }

    static func noise(_ w: Int, _ h: Int) -> CGImage {
        let c = ctx(w, h)
        var g = SystemRandomNumberGenerator()
        for y in stride(from: 0, to: h, by: 4) {
            for x in stride(from: 0, to: w, by: 4) {
                c.setFillColor(CGColor(red: .random(in: 0...1, using: &g), green: .random(in: 0...1, using: &g),
                                       blue: .random(in: 0...1, using: &g), alpha: 1))
                c.fill(CGRect(x: x, y: y, width: 4, height: 4))
            }
        }
        return c.makeImage()!
    }

    static func words(_ text: String, _ w: Int, _ h: Int) -> CGImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill()
        (text as NSString).draw(at: NSPoint(x: 40, y: 100),
                                withAttributes: [.font: NSFont.systemFont(ofSize: 90, weight: .bold), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage!
    }

    static func write(_ img: CGImage, _ url: URL, _ props: [CFString: Any]?) throws {
        let type = UTType(filenameExtension: url.pathExtension)!
        let d = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, img, props as CFDictionary?)
        guard CGImageDestinationFinalize(d) else { throw KilnError("sample \(url.lastPathComponent)") }
    }

    /// 3 s of 640x360 video, then the voice added as sound and a location attached.
    static func movie(_ out: URL, audio: URL, scratch: URL) async throws {
        let w = try AVAssetWriter(outputURL: scratch, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 360])
        w.add(input)
        w.startWriting()
        w.startSession(atSourceTime: .zero)
        for i in 0..<90 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            guard let pb else { continue }
            CVPixelBufferLockBaseAddress(pb, [])
            let c = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: 640, height: 360, bitsPerComponent: 8,
                              bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            c.setFillColor(CGColor(gray: 0.15, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
            c.setFillColor(CGColor(red: 0.9, green: 0.5, blue: 0.1, alpha: 1)); c.fill(CGRect(x: i * 6, y: 140, width: 80, height: 80))
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished()
        await w.finishWriting()

        let comp = AVMutableComposition()
        let v = AVURLAsset(url: scratch), a = AVURLAsset(url: audio)
        let vt = try await v.loadTracks(withMediaType: .video)[0]
        let dur = try await v.load(.duration)
        try comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
            .insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: vt, at: .zero)
        let at = try await a.loadTracks(withMediaType: .audio)[0]
        let adur = try await a.load(.duration)
        try comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            .insertTimeRange(CMTimeRange(start: .zero, duration: min(dur, adur)), of: at, at: .zero)
        let s = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality)!
        let loc = AVMutableMetadataItem()
        loc.identifier = .quickTimeMetadataLocationISO6709
        loc.value = "-31.9505+115.8605/" as NSString
        s.metadata = [loc]
        try await s.export(to: out, as: .mov)
    }
}
