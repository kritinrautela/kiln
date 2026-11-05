import AppKit
import QuickLookThumbnailing
import SwiftUI

struct ContentView: View {
    @Bindable var store: Store
    @State private var targeted = false
    @State private var cropping = false
    @State private var trimQueue: [DroppedFile] = []
    @State private var trims: [UUID: JobOptions] = [:]

    var body: some View {
        Group {
            if store.files.isEmpty {
                Home(targeted: targeted) { Pickers.open(into: store) }
            } else {
                Workspace(store: store, crop: { cropping = true }, trim: startTrim)
            }
        }
        .frame(minWidth: 540, minHeight: 600)
        .safeAreaInset(edge: .top, spacing: 0) {
            if let v = store.newVersion {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles").foregroundStyle(Color.ember)
                    Text("A new Kiln (\(v)) is ready.").font(.callout.weight(.medium))
                    Spacer()
                    Button("Download") { NSWorkspace.shared.open(Updates.page) }
                    Button("Later") { store.newVersion = nil }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
        .onDrop(of: Drops.types, isTargeted: $targeted) { providers in
            Drops.load(providers, into: store)
            return true
        }
        .overlay {
            if targeted && !store.files.isEmpty {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.ember, lineWidth: 3)
                    .background(Color.ember.opacity(0.06), in: .rect(cornerRadius: 14))
                    .overlay(Label("Add to the list", systemImage: "plus.circle.fill")
                        .font(.title3.weight(.semibold)).foregroundStyle(Color.ember))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.18), value: targeted)
        .sheet(isPresented: $cropping) {
            CropSheet(files: store.files.filter { Action.crop.applies(to: $0.kind) }) { rect, shape in
                cropping = false
                guard let rect else { return }
                var all: [UUID: JobOptions] = [:]
                for f in store.files { all[f.id] = JobOptions(crop: rect, shape: shape) }
                store.run(.crop, options: all)
            }
        }
        .sheet(item: Binding(get: { trimQueue.first }, set: { _ in })) { file in
            TrimSheet(file: file) { range in
                if let range { trims[file.id] = JobOptions(trim: range) }
                trimQueue.removeFirst()
                if trimQueue.isEmpty, !trims.isEmpty {
                    store.run(.trim, options: trims, only: Set(trims.keys))
                }
            }
            .id(file.id)
        }
    }

    private func startTrim() {
        trims = [:]
        trimQueue = store.files.filter { Action.trim.applies(to: $0.kind) }
    }
}

// MARK: Empty window

struct Home: View {
    let targeted: Bool
    let choose: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: targeted ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Color.ember)
                .contentTransition(.symbolEffect(.replace))
            VStack(spacing: 6) {
                Text("Drop files here")
                    .font(.largeTitle.weight(.semibold))
                Text("Photos, videos, music, PDFs and Word files.\nKiln makes a new copy. Your original stays exactly as it was.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("Choose Files…", action: choose)
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .padding(.top, 4)
            Text("You can also paste with ⌘V, or drop files on Kiln in the Dock.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(targeted ? Color.ember : Color.secondary.opacity(0.35),
                              style: StrokeStyle(lineWidth: targeted ? 3 : 1.5, dash: targeted ? [] : [7, 6]))
                .background(targeted ? Color.ember.opacity(0.07) : .clear, in: .rect(cornerRadius: 22))
                .padding(16)
        }
        .animation(.easeOut(duration: 0.18), value: targeted)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Drop files here, or choose files")
    }
}

// MARK: Files are in

struct Workspace: View {
    @Bindable var store: Store
    let crop: () -> Void
    let trim: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            FileStrip(store: store)
            Divider()
            ScrollView {
                Group {
                    if store.showingResults {
                        ResultsView(store: store)
                    } else {
                        ActionsView(store: store, crop: crop, trim: trim)
                    }
                }
                .padding(20)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

struct FileStrip: View {
    @Bindable var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(summary)
                    .font(.headline)
                Spacer()
                Button("Add More…") { Pickers.open(into: store) }
                Button("Clear") { store.clear() }
                    .disabled(store.working)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(store.files) { f in
                        FileTile(file: f, removable: !store.working) { store.remove(f) }
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.never)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
    }

    private var summary: String {
        let groups = Dictionary(grouping: store.files, by: \.kind)
        return FileKind.allCases.compactMap { k in
            guard let n = groups[k]?.count else { return nil }
            return "\(n) \(k.noun)\(n == 1 ? "" : "s")"
        }.joined(separator: ", ")
    }
}

struct FileTile: View {
    let file: DroppedFile
    let removable: Bool
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 5) {
            Thumb(url: file.url, fill: file.kind == .image || file.kind == .video, side: 64)
                .overlay(alignment: .topTrailing) {
                    if hovering && removable {
                        Button(action: remove) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.65))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 6, y: -6)
                        .accessibilityLabel("Remove \(file.name)")
                    }
                }
            Text(file.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 76)
            Text(byteString(file.size))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .onHover { hovering = $0 }
        .help(file.url.path)
    }
}

struct Thumb: View {
    let url: URL
    var fill = true
    var side: CGFloat = 56
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: fill ? .fill : .fit)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(6)
            }
        }
        .frame(width: side, height: side)
        .background(Color.secondary.opacity(0.08))
        .clipShape(.rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
        .task(id: url) {
            let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side), scale: 2,
                                                   representationTypes: .thumbnail)
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) {
                image = rep.nsImage
            }
        }
    }
}

// MARK: What to do

struct ActionsView: View {
    @Bindable var store: Store
    let crop: () -> Void
    let trim: () -> Void
    @State private var open: Action?
    @State private var formats: [FileKind: Format] = [:]
    @AppStorage("size") private var size: Size = .email          // remembered between uses
    @AppStorage("scale") private var scale = 0.5

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let s = store.suggestion {
                Button {
                    store.run(s.action, formats: s.formats, size: .email)
                } label: {
                    Label(s.label, systemImage: s.symbol)
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.extraLarge)
                .keyboardShortcut(.defaultAction)
            }

            if store.actions.isEmpty {
                Text("Kiln doesn't know what to do with these files yet. It works with photos, videos, music, PDFs and documents.")
                    .foregroundStyle(.secondary)
            } else {
                Text(store.suggestion == nil ? "What would you like to do?" : "Or choose something else")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    ForEach(Array(store.actions.enumerated()), id: \.element) { i, a in
                        if i > 0 { Divider().padding(.leading, 52) }
                        row(a)
                    }
                }
                .background(.background.secondary, in: .rect(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.07)))
            }
        }
        .onAppear(perform: defaultFormats)
        .onChange(of: store.files) { defaultFormats() }
    }

    /// Last time's choice for each kind of file, or the first one.
    private func defaultFormats() {
        for k in store.kinds where formats[k] == nil || !Format.choices(for: k).contains(formats[k]!) {
            let saved = UserDefaults.standard.string(forKey: "format.\(k.rawValue)")
            formats[k] = Format.choices(for: k).first { $0.ext == saved } ?? Format.choices(for: k).first
        }
    }

    private func remember() {
        for (k, f) in formats { UserDefaults.standard.set(f.ext, forKey: "format.\(k.rawValue)") }
    }

    private var expandable: Set<Action> { [.convert, .smaller, .resize] }

    @ViewBuilder
    private func row(_ a: Action) -> some View {
        let count = store.count(for: a)
        let mixed = count < store.files.count
        VStack(alignment: .leading, spacing: 0) {
            Button {
                switch a {
                case .convert, .smaller, .resize: withAnimation(.easeOut(duration: 0.2)) { open = open == a ? nil : a }
                case .crop: crop()
                case .trim: trim()
                default: store.run(a)
                }
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: a.symbol)
                        .font(.title3)
                        .foregroundStyle(Color.ember)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.title).font(.body.weight(.medium))
                        Text(mixed ? "\(a.hint) (\(count) of \(store.files.count) files)" : a.hint)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: expandable.contains(a) ? (open == a ? "chevron.up" : "chevron.down")
                          : (a == .crop || a == .trim ? "ellipsis" : "arrow.right"))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .contentShape(.rect)
            }
            .buttonStyle(RowStyle())

            if open == a {
                Group {
                    switch a {
                    case .convert: convertOptions
                    case .resize: resizeOptions
                    default: smallerOptions
                    }
                }
                .padding(.leading, 54)
                .padding(.trailing, 14)
                .padding(.bottom, 14)
                .transition(.opacity)
            }
        }
    }

    private var convertOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(FileKind.allCases.filter { store.kinds.contains($0) && !Format.choices(for: $0).isEmpty }, id: \.self) { k in
                VStack(alignment: .leading, spacing: 6) {
                    if store.kinds.count > 1 {
                        Text("\(k.plural) become").font(.callout).foregroundStyle(.secondary)
                    }
                    Picker("Format", selection: Binding(get: { formats[k] }, set: { formats[k] = $0 })) {
                        ForEach(Format.choices(for: k)) { f in Text(f.label).tag(Optional(f)) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            Button("Convert") {
                remember()
                store.run(.convert, formats: formats)
            }
                .buttonStyle(.glassProminent)
        }
    }

    private var resizeOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("How big", selection: $scale) {
                Text("¾ size").tag(0.75)
                Text("Half size").tag(0.5)
                Text("¼ size").tag(0.25)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Button("Resize") { store.run(.resize, scale: scale) }
                .buttonStyle(.glassProminent)
        }
    }

    private var smallerOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !store.kinds.isDisjoint(with: [.image, .video, .pdf]) {
                Picker("How small", selection: $size) {
                    ForEach(Size.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Button("Make Smaller") { store.run(.smaller, size: size) }
                .buttonStyle(.glassProminent)
        }
    }
}

struct RowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration)
    }

    private struct RowBody: View {
        let configuration: Configuration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .background(Color.primary.opacity(configuration.isPressed ? 0.09 : hovering ? 0.045 : 0))
                .onHover { hovering = $0 }
        }
    }
}

// MARK: Results

struct ResultsView: View {
    @Bindable var store: Store
    @State private var copied: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if store.working {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Working…").font(.title2.weight(.semibold))
                    HStack(spacing: 12) {
                        ProgressView(value: store.progress)
                        Button("Stop") { store.stop() }
                    }
                    Text(store.status).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: store.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.title)
                        .foregroundStyle(store.failures.isEmpty ? Color.green : Color.orange)
                    Text(store.status == "Stopped" ? "Stopped" : store.failures.isEmpty ? "Done" : store.results.isEmpty ? "That didn't work" : "Done, mostly")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    if store.results.count > 1 {
                        Button("Show All in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting(store.results.map(\.url))
                        }
                    }
                }
                if !store.results.isEmpty {
                    Text("New copies are saved \(where_). Drag them, or press Copy and paste, into Messages, WhatsApp or Mail.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 8) {
                ForEach(store.results) { r in resultRow(r) }
                ForEach(store.failures) { f in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.name).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                            Text(f.reason).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(Color.red.opacity(0.07), in: .rect(cornerRadius: 12))
                }
            }

            if !store.working {
                HStack {
                    Button("Do Something Else With These") { store.backToActions() }
                    Spacer()
                    Button("Start Over") { store.clear() }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 4)
            }
        }
    }

    private var where_: String {
        store.saveLocation == .downloads ? "in your Downloads folder" : "next to the originals"
    }

    private func resultRow(_ r: Result) -> some View {
        HStack(spacing: 12) {
            Thumb(url: r.url, fill: true, side: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.url.lastPathComponent).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text(sizeLine(r)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                if r.after > 25_000_000 {
                    Text("Too big for most email. Try Make smaller, or send it with AirDrop.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            if let text = r.text {
                Button(copied == r.id ? "Copied" : "Copy Text") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = r.id
                }
            }
            else {
                Button(copied == r.id ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([r.url as NSURL])
                    copied = r.id
                }
                .help("Copy the file, then paste it into Messages, WhatsApp or Mail")
            }
            Button("Open") { NSWorkspace.shared.open(r.url) }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([r.url])
            } label: {
                Image(systemName: "folder")
            }
            .help("Show in Finder")
            .accessibilityLabel("Show in Finder")
        }
        .padding(10)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
        .onDrag { NSItemProvider(contentsOf: r.url) ?? NSItemProvider() }
    }

    private func sizeLine(_ r: Result) -> String {
        guard r.saving, r.before > 0, r.after > 0, r.after < r.before else { return byteString(r.after) }
        let pct = Int((1 - Double(r.after) / Double(r.before)) * 100)
        return "\(byteString(r.before)) → \(byteString(r.after)), \(pct)% smaller"
    }
}

// MARK: Settings

struct SettingsView: View {
    @Bindable var store: Store

    var body: some View {
        Form {
            Picker("Save new copies", selection: Binding(get: { store.saveLocation }, set: { store.saveLocation = $0 })) {
                ForEach(SaveLocation.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.radioGroup)
            Text("Kiln never changes or deletes your originals, and nothing is uploaded anywhere.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 420)
    }
}
