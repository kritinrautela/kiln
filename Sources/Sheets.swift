import AVFoundation
import AVKit
import ImageIO
import SwiftUI

// MARK: Crop

enum Aspect: String, CaseIterable, Identifiable {
    case free, square, portrait, story, wide
    var id: String { rawValue }
    var label: String {
        switch self {
        case .free: "Free"
        case .square: "Square"
        case .portrait: "4:5 Post"
        case .story: "9:16 Story"
        case .wide: "16:9 Wide"
        }
    }
    /// Width over height, in real pixels.
    var ratio: CGFloat? {
        switch self {
        case .free: nil
        case .square: 1
        case .portrait: 4.0 / 5.0
        case .story: 9.0 / 16.0
        case .wide: 16.0 / 9.0
        }
    }
}

struct CropSheet: View {
    let files: [DroppedFile]
    let done: (CGRect?, CGFloat?) -> Void
    @State private var preview: CGImage?
    @State private var rect = CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
    @State private var aspect: Aspect = .free

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Crop").font(.title2.weight(.semibold))
                Spacer()
                Picker("Shape", selection: $aspect) {
                    ForEach(Aspect.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            GeometryReader { geo in
                if let preview {
                    let size = fitted(CGSize(width: preview.width, height: preview.height), in: geo.size)
                    ZStack(alignment: .topLeading) {
                        Image(decorative: preview, scale: 1)
                            .resizable()
                            .frame(width: size.width, height: size.height)
                        CropOverlay(rect: $rect, ratio: normalizedRatio, size: size)
                    }
                    .frame(width: size.width, height: size.height)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Text(files.count > 1
                 ? "Drag the corners or the middle. The same crop is used for all \(files.count) files."
                 : "Drag the corners to resize, or the middle to move.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { done(nil, nil) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Crop") { done(rect, aspect.ratio) }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 640, height: 520)
        .task { preview = await Preview.image(files.first) }
        .onChange(of: aspect) { applyAspect() }
    }

    /// The chosen shape, expressed in the 0...1 space the crop box lives in.
    private var normalizedRatio: CGFloat? {
        guard let r = aspect.ratio, let p = preview, p.width > 0, p.height > 0 else { return nil }
        return r * CGFloat(p.height) / CGFloat(p.width)
    }

    private func applyAspect() {
        guard let rn = normalizedRatio else { return }
        var w: CGFloat = 1, h: CGFloat = 1
        if rn >= 1 { h = 1 / rn } else { w = rn }
        w *= 0.9
        h *= 0.9
        withAnimation(.easeOut(duration: 0.2)) {
            rect = CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
        }
    }

    private func fitted(_ image: CGSize, in box: CGSize) -> CGSize {
        let s = min(box.width / max(image.width, 1), box.height / max(image.height, 1))
        return CGSize(width: image.width * s, height: image.height * s)
    }
}

struct CropOverlay: View {
    @Binding var rect: CGRect
    let ratio: CGFloat?
    let size: CGSize
    @State private var start: CGRect?

    enum Corner: CaseIterable { case tl, tr, bl, br }

    var body: some View {
        let frame = CGRect(x: rect.minX * size.width, y: rect.minY * size.height,
                           width: rect.width * size.width, height: rect.height * size.height)
        ZStack(alignment: .topLeading) {
            Path { p in
                p.addRect(CGRect(origin: .zero, size: size))
                p.addRect(frame)
            }
            .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            Rectangle()
                .strokeBorder(.white, lineWidth: 2)
                .background(thirds(frame.size))
                .contentShape(.rect)
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
                .gesture(DragGesture().onChanged { move($0.translation) }.onEnded { _ in start = nil })
                .onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }

            ForEach(Corner.allCases, id: \.self) { c in
                RoundedRectangle(cornerRadius: 3)
                    .fill(.white)
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                    .frame(width: 14, height: 14)
                    .padding(8)
                    .contentShape(.rect)
                    .offset(x: (c == .tl || c == .bl ? frame.minX : frame.maxX) - 15,
                            y: (c == .tl || c == .tr ? frame.minY : frame.maxY) - 15)
                    .gesture(DragGesture().onChanged { resize(c, $0.translation) }.onEnded { _ in start = nil })
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .onChange(of: ratio) { _, r in if r != nil { start = nil } }
    }

    private func thirds(_ s: CGSize) -> some View {
        Path { p in
            for i in 1...2 {
                let x = s.width * CGFloat(i) / 3, y = s.height * CGFloat(i) / 3
                p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: s.height))
                p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: s.width, y: y))
            }
        }
        .stroke(.white.opacity(0.35), lineWidth: 1)
    }

    private func move(_ t: CGSize) {
        if start == nil { start = rect }
        guard let s = start else { return }
        let x = min(max(s.minX + t.width / size.width, 0), 1 - s.width)
        let y = min(max(s.minY + t.height / size.height, 0), 1 - s.height)
        rect = CGRect(x: x, y: y, width: s.width, height: s.height)
    }

    private func resize(_ c: Corner, _ t: CGSize) {
        if start == nil { start = rect }
        guard let s = start else { return }
        let dx = t.width / size.width, dy = t.height / size.height
        let minSide: CGFloat = 0.05
        var minX = s.minX, minY = s.minY, maxX = s.maxX, maxY = s.maxY
        switch c {
        case .tl: minX += dx; minY += dy
        case .tr: maxX += dx; minY += dy
        case .bl: minX += dx; maxY += dy
        case .br: maxX += dx; maxY += dy
        }
        minX = min(max(minX, 0), s.maxX - minSide)
        maxX = max(min(maxX, 1), s.minX + minSide)
        minY = min(max(minY, 0), s.maxY - minSide)
        maxY = max(min(maxY, 1), s.minY + minSide)

        if let rn = ratio {
            let left = c == .tl || c == .bl, top = c == .tl || c == .tr
            var w = maxX - minX
            var h = w / rn
            // Keep the opposite corner pinned; shrink if the shape would run off the picture.
            let room = top ? s.maxY : 1 - s.minY
            if h > room { h = room; w = h * rn }
            if left { minX = s.maxX - w } else { maxX = s.minX + w }
            if top { minY = s.maxY - h } else { maxY = s.minY + h }
        }
        rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

enum Preview {
    /// A still to crop on: the photo itself, or a video's first frame.
    static func image(_ file: DroppedFile?) async -> CGImage? {
        guard let file else { return nil }
        if file.kind == .video {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: file.url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 1600, height: 1600)
            return try? await gen.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)).image
        }
        guard let s = try? Engine.source(file.url) else { return nil }
        return try? Engine.oriented(s, maxPixels: 1600)
    }
}

// MARK: Trim

struct TrimSheet: View {
    let file: DroppedFile
    let done: (ClosedRange<Double>?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Trim \(file.name)")
                .font(.title2.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Text("Drag the yellow ends to where it should start and stop, then press Trim.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TrimPlayer(url: file.url, done: done)
                .clipShape(.rect(cornerRadius: 10))
        }
        .padding(24)
        .frame(width: 640, height: file.kind == .audio ? 240 : 500)
    }
}

/// The same trimming bar QuickTime uses.
struct TrimPlayer: NSViewRepresentable {
    let url: URL
    let done: (ClosedRange<Double>?) -> Void

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = AVPlayer(url: url)
        v.controlsStyle = .inline
        context.coordinator.begin(v, attempts: 0)
        return v
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    @MainActor
    final class Coordinator {
        let done: (ClosedRange<Double>?) -> Void
        init(done: @escaping (ClosedRange<Double>?) -> Void) { self.done = done }

        func begin(_ v: AVPlayerView, attempts: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak v] in
                guard let self, let v else { return }
                guard v.window != nil, v.canBeginTrimming else {
                    if attempts < 40 { self.begin(v, attempts: attempts + 1) } else { self.done(nil) }
                    return
                }
                v.beginTrimming { result in
                    guard result == .okButton, let item = v.player?.currentItem else { return self.done(nil) }
                    let total = item.duration.seconds
                    let s = item.reversePlaybackEndTime, e = item.forwardPlaybackEndTime
                    let start = s.isNumeric ? s.seconds : 0
                    let end = e.isNumeric ? e.seconds : total
                    v.player?.pause()
                    self.done(start...max(end, start + 0.1))
                }
            }
        }
    }
}
