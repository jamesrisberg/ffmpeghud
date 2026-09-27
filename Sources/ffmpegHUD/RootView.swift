import ffmpegHUDKit
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @ObservedObject var model: AppModel
    var expand: () -> Void = {}
    var compact: () -> Void = {}
    var dismiss: () -> Void = {}

    var body: some View {
        Group {
            if model.isCompact {
                CompactTile(model: model, expand: expand)
            } else {
                FullView(model: model, compact: compact, dismiss: dismiss)
            }
        }
        .environment(\.colorScheme, .dark)
        .onDrop(of: [.fileURL], isTargeted: $model.isDropTargeted) { providers in
            DropHandler.handle(providers) { urls in
                model.drop(urls)
                if model.isCompact { expand() }
            }
        }
        .overlay {
            if model.isDropTargeted {
                RoundedRectangle(cornerRadius: model.isCompact ? 12 : 16, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
    }
}

enum DropHandler {
    static func handle(_ providers: [NSItemProvider], _ done: @escaping @MainActor ([URL]) -> Void) -> Bool {
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !files.isEmpty else { return false }
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [(Int, URL)] = []
        for (index, provider) in files.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { lock.lock(); urls.append((index, url)); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            // Keep the order the files were dragged in (a join depends on it).
            let ordered = urls.sorted { $0.0 < $1.0 }.map(\.1)
            MainActor.assumeIsolated { done(ordered) }
        }
        return true
    }
}

// MARK: - Full panel

struct FullView: View {
    @ObservedObject var model: AppModel
    var compact: () -> Void
    var dismiss: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Header(model: model, compact: compact, dismiss: dismiss)
            DropZone(model: model)
            HStack(alignment: .top, spacing: 12) {
                PresetList(model: model)
                    .frame(width: 186)
                PresetForm(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(maxHeight: .infinity)
            if !model.queue.jobs.isEmpty {
                JobsList(model: model)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }
}

struct Header: View {
    @ObservedObject var model: AppModel
    var compact: () -> Void
    var dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            FFmpegGlyph().frame(width: 18, height: 18)
            Text("ffmpegHUD").font(.system(size: 13, weight: .semibold))
            if !model.queue.hasFFmpeg {
                Text("ffmpeg not found: brew install ffmpeg")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
            Spacer(minLength: 8)
            if let message = model.message {
                Text(message.text)
                    .font(.system(size: 11))
                    .foregroundStyle(message.isError ? Color.orange : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Button(action: compact) { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Compact tile")
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Hide (Esc)")
        }
    }
}

// MARK: - Drop zone

struct DropZone: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            if let input = model.primaryInput {
                Image(systemName: model.primaryInfo.map { $0.hasVideo ? "film" : "waveform" } ?? "doc")
                    .font(.system(size: 22))
                    .foregroundStyle(Color(red: 0.36, green: 0.8, blue: 0.45))
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(input.lastPathComponent)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1).truncationMode(.middle)
                        if model.inputs.count > 1 {
                            Text("+\(model.inputs.count - 1) more")
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(Color.white.opacity(0.14)))
                        }
                    }
                    switch model.primaryProbe {
                    case .probing?, nil:
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Reading…").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    case .ready(let info)?:
                        Text(info.summary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    case .failed(let why)?:
                        Text(why).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Button { model.clearInput() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Clear")
            } else {
                Spacer()
                Image(systemName: "square.and.arrow.down").font(.system(size: 18)).foregroundStyle(.secondary)
                Text("Drop video or audio here").font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 58)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(model.primaryInput == nil ? 0.03 : 0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.22),
                              style: StrokeStyle(lineWidth: 1, dash: model.primaryInput == nil ? [5, 4] : []))
        )
    }
}

// MARK: - Presets

struct PresetList: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 11))
                TextField("Search presets", text: $model.search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit { if let first = model.visiblePresets.first { model.select(first.id) } }
                if !model.search.isEmpty {
                    Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 7).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.08)))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    let presets = model.visiblePresets
                    if presets.isEmpty {
                        Text("No matches").font(.callout).foregroundStyle(.secondary).padding(.top, 20)
                    }
                    ForEach(presets) { preset in
                        PresetRow(preset: preset, selected: preset.id == model.selectedID,
                                  recent: model.recents.contains(preset.id),
                                  dimmed: preset.needsVideo && model.primaryInfo.map { !$0.hasVideo } == true)
                            .onTapGesture { model.select(preset.id) }
                    }
                }
            }
        }
    }
}

struct PresetRow: View {
    let preset: Preset
    let selected: Bool
    let recent: Bool
    let dimmed: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: preset.symbol).frame(width: 18).foregroundStyle(selected ? .white : .secondary)
            Text(preset.title).font(.system(size: 12, weight: selected ? .semibold : .regular)).lineLimit(1)
            Spacer(minLength: 0)
            if recent {
                Image(systemName: "clock").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
        .opacity(dimmed ? 0.45 : 1)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.55) : Color.clear))
        .contentShape(Rectangle())
    }
}

struct PresetForm: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let preset = model.preset
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.title).font(.system(size: 14, weight: .semibold))
                Text(preset.summary).font(.system(size: 11)).foregroundStyle(.secondary)
                if preset.needsVideo, let info = model.primaryInfo, !info.hasVideo {
                    Text("Needs a video stream; this file is audio only.")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                }
            }
            if !preset.fields.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
                    ForEach(preset.fields.filter { preset.isVisible($0, values: model.values) }) { field in
                        GridRow {
                            Text(field.label).font(.system(size: 12)).foregroundStyle(.secondary)
                                .gridColumnAlignment(.trailing)
                            FieldControl(model: model, field: field)
                        }
                    }
                }
            }
            CommandPreview(model: model)
            Spacer(minLength: 0)
            HStack {
                if case .success(let command) = model.preview, !model.inputs.isEmpty {
                    Label(Self.abbreviate(command.output), systemImage: "arrow.turn.down.right")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .help(command.output)
                }
                Spacer()
                Button {
                    model.run()
                } label: {
                    Label(model.inputs.count > 1 && !preset.multiInput ? "Run ×\(model.inputs.count)" : "Run",
                          systemImage: "play.fill")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(RunButtonStyle())
                .disabled(!model.canRun)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Run (⌘↩)")
            }
        }
    }

    static func abbreviate(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
}

struct FieldControl: View {
    @ObservedObject var model: AppModel
    let field: PresetField

    var body: some View {
        let binding = Binding(get: { model.values[field.id] }, set: { model.setValue($0, for: field.id) })
        switch field.kind {
        case .select:
            Picker("", selection: binding) {
                ForEach(field.options) { option in
                    let available = model.isAvailable(option)
                    Text(available ? option.label : "\(option.label) (not in this ffmpeg)")
                        .tag(option.value)
                        .selectionDisabled(!available)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 260, alignment: .leading)
        case .text:
            TextField(field.placeholder ?? "", text: binding)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .frame(maxWidth: 200)
        }
    }
}

struct CommandPreview: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            switch model.preview {
            case .success(let command):
                Text(command.display)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.primary.opacity(model.inputs.isEmpty ? 0.5 : 0.85))
                    .textSelection(.enabled)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command.display, forType: .string)
                    model.show("Command copied")
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Copy the command")
            case .failure(let error):
                Label(error.description, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.28)))
    }
}

// MARK: - Jobs

struct JobsList: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Jobs").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if model.queue.jobs.contains(where: { !$0.isActive }) {
                    Button("Clear finished") { model.queue.clearFinished() }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(model.queue.jobs) { job in
                        JobRow(model: model, job: job)
                    }
                }
            }
            .frame(maxHeight: 132)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct JobRow: View {
    @ObservedObject var model: AppModel
    let job: Job

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                stateIcon.frame(width: 16)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(job.presetTitle).font(.system(size: 11, weight: .semibold))
                        Text("\(job.inputName) → \(job.outputName)")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    if job.state == .running {
                        if let fraction = job.fraction {
                            ProgressView(value: fraction).progressViewStyle(.linear).controlSize(.small)
                        } else {
                            ProgressView().progressViewStyle(.linear).controlSize(.small)
                        }
                    }
                }
                Spacer(minLength: 4)
                Text(status).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary).fixedSize()
                actions
            }
            if job.state == .failed, model.expandedErrors.contains(job.id) {
                Text(job.error ?? "")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.3)))
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.05)))
    }

    private var stateIcon: some View {
        let (symbol, color): (String, Color) = switch job.state {
        case .queued: ("clock", .secondary)
        case .running: ("gearshape.2", .primary)
        case .succeeded: ("checkmark.circle.fill", .green)
        case .failed: ("exclamationmark.triangle.fill", .orange)
        case .cancelled: ("xmark.circle", .secondary)
        }
        return Image(systemName: symbol).foregroundStyle(color)
    }

    private var status: String {
        switch job.state {
        case .queued: return "Waiting"
        case .running:
            if let fraction = job.fraction { return "\(Int((fraction * 100).rounded(.down)))%" }
            return job.written > 0 ? TimeFormat.clock(job.written) : "Starting"
        case .succeeded: return job.trashedOriginal ? "Done · original trashed" : "Done"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    @ViewBuilder private var actions: some View {
        switch job.state {
        case .queued, .running:
            Button { model.queue.cancel(job.id) } label: { Image(systemName: "xmark.circle") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Cancel")
        case .succeeded:
            Button { model.reveal(job) } label: { Image(systemName: "magnifyingglass.circle") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Reveal in Finder")
        case .failed:
            Button { model.toggleErrors(job.id) } label: {
                Image(systemName: model.expandedErrors.contains(job.id) ? "chevron.up.circle" : "chevron.down.circle")
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("Show what ffmpeg said")
        case .cancelled:
            EmptyView()
        }
    }
}

// MARK: - Compact tile

/// The 44 pt drop tile: the ffmpeg glyph, a badge with the running jobs, and a ring for
/// their overall progress. Drop a file on it or click it to open the panel.
struct CompactTile: View {
    @ObservedObject var model: AppModel
    var expand: () -> Void

    var body: some View {
        let running = model.queue.jobs.filter { $0.state == .running }
        let fractions = running.compactMap(\.fraction)
        ZStack {
            FFmpegGlyph().frame(width: 24, height: 24)
            if !fractions.isEmpty {
                Circle()
                    .trim(from: 0, to: fractions.reduce(0, +) / Double(fractions.count))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(4)
            }
        }
        .frame(width: 44, height: 44)
        .overlay(alignment: .topTrailing) {
            if !running.isEmpty {
                Text("\(running.count)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 14, minHeight: 14)
                    .background(Circle().fill(Color.orange))
                    .offset(x: -1, y: 1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: expand)
        .help(running.isEmpty ? "ffmpegHUD: drop a file" : "\(running.count) running")
    }
}

/// A stand-in for the ffmpeg mark: a green tile with a white stepped zig-zag.
struct FFmpegGlyph: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: s * 0.22, style: .continuous)
                    .fill(Color(red: 0.05, green: 0.55, blue: 0.24))
                Path { p in
                    let steps = 3
                    let inset = s * 0.2
                    let span = s - inset * 2
                    let step = span / CGFloat(steps)
                    p.move(to: CGPoint(x: inset, y: s - inset))
                    for i in 0..<steps {
                        let x = inset + CGFloat(i) * step
                        let y = s - inset - CGFloat(i) * step
                        p.addLine(to: CGPoint(x: x, y: y - step))
                        p.addLine(to: CGPoint(x: x + step, y: y - step))
                    }
                }
                .stroke(Color.white, style: StrokeStyle(lineWidth: max(1.5, s * 0.09), lineCap: .round, lineJoin: .round))
            }
            .frame(width: s, height: s)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// A non-activating panel always draws as inactive, which greys out `.borderedProminent`;
/// this keeps Run green whenever it can run.
struct RunButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.45))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isEnabled ? Color(red: 0.12, green: 0.62, blue: 0.3) : Color.white.opacity(0.1))
                    .opacity(configuration.isPressed ? 0.75 : 1)
            )
    }
}
