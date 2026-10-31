// Ringtones: the iPhone keeps synced tones in /iTunes_Control/Ringtones and lists them in
// /iTunes_Control/iTunes/Ringtones.plist, both reachable over AFC. Decant cuts any audio file to a tone
// (AAC in an .m4r container, 30 or 40 seconds), uploads it and adds the plist entry; the phone shows it in
// Settings → Sounds & Haptics under its own Ringtones heading. No iTunes protocol involved.
import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

struct Ringtone: Identifiable, Hashable {
    let file: String        // name inside /iTunes_Control/Ringtones
    let name: String        // what Settings shows
    let duration: Double    // seconds
    let pid: Int
    var id: String { file }
}

@MainActor
final class RingtoneService: ObservableObject {
    @Published var tones: [Ringtone] = []
    @Published var loading = false
    @Published var running = false
    @Published var phase = ""
    @Published var loaded = false
    var log: (String) -> Void = { _ in }

    static let dir = "/iTunes_Control/Ringtones"
    static let plistPath = "/iTunes_Control/iTunes/Ringtones.plist"

    private func afc(_ commands: [String], udid: String) async -> [String] {
        var lines: [String] = []
        await Tools.stream("afcclient", ["-u", udid], input: commands.joined(separator: "\n") + "\nquit\n") { l in
            var s = l.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
            if let r = s.range(of: #"^afc:[^>]*> "#, options: .regularExpression) { s.removeSubrange(r) }
            if !s.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(s) }
        }
        return lines
    }
    private func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
    private static func failed(_ out: [String]) -> String? { out.first { $0.hasPrefix("Error") || $0.hasPrefix("ERROR") } }

    private func readPlist(udid: String) async -> [String: Any] {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("Decant-Ringtones-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = await afc(["get \(q(Self.plistPath)) \(q(tmp.path))"], udid: udid)
        guard let d = try? Data(contentsOf: tmp), let p = (try? PropertyListSerialization.propertyList(from: d, format: nil)) as? [String: Any] else { return [:] }
        return p
    }

    private func writePlist(_ p: [String: Any], udid: String) async -> Bool {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("Decant-Ringtones-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard let d = try? PropertyListSerialization.data(fromPropertyList: p, format: .xml, options: 0), (try? d.write(to: tmp)) != nil else { return false }
        let out = await afc(["mkdir \(q("/iTunes_Control/iTunes"))", "put \(q(tmp.path)) \(q(Self.plistPath))"], udid: udid)
        if let e = Self.failed(out) { log("Ringtones.plist: \(e)"); return false }
        return true
    }

    func load(udid: String) async {
        if Demo.on { tones = Demo.ringtones(); loaded = true; return }
        guard !udid.isEmpty else { return }
        loading = true; defer { loading = false; loaded = true }
        let p = await readPlist(udid: udid)
        let listed = p["Ringtones"] as? [String: Any] ?? [:]
        var out: [Ringtone] = []
        for (file, v) in listed {
            let d = v as? [String: Any] ?? [:]
            out.append(Ringtone(file: file, name: d["Name"] as? String ?? (file as NSString).deletingPathExtension,
                                duration: Double(d["Total Time"] as? Int ?? 0) / 1000, pid: d["PID"] as? Int ?? 0))
        }
        // Tones on disk the plist does not know about (another tool put them there) are still shown.
        for line in await afc(["ls -l \(q(Self.dir))"], udid: udid) {
            let parts = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 9, parts[0].hasPrefix("-") else { continue }
            let tail = parts[8].split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            let name = tail.count > 1 ? String(tail[1]) : ""
            if name.lowercased().hasSuffix(".m4r"), !out.contains(where: { $0.file == name }) {
                out.append(Ringtone(file: name, name: (name as NSString).deletingPathExtension, duration: 0, pid: 0))
            }
        }
        tones = out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Cut `length` seconds from `start` of any audio or video file into an AAC tone and put it on the phone.
    func add(source: URL, name: String, start: Double, length: Double, udid: String) async -> Bool {
        guard !running else { return false }
        running = true; phase = "Converting \(source.lastPathComponent)"
        defer { running = false }
        let guid = (0..<16).map { _ in "0123456789ABCDEF".randomElement()! }.map(String.init).joined()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(guid).m4a")
        let tone = FileManager.default.temporaryDirectory.appendingPathComponent("\(guid).m4r")
        defer { try? FileManager.default.removeItem(at: tmp); try? FileManager.default.removeItem(at: tone) }
        do {
            try await Self.export(source, to: tmp, start: start, length: length)
            try FileManager.default.moveItem(at: tmp, to: tone)
        } catch { log("Ringtone conversion failed: \(error.localizedDescription)"); phase = "Conversion failed"; return false }
        if Demo.on {
            tones.append(Ringtone(file: "\(guid).m4r", name: name, duration: length, pid: tones.count + 1)); phase = "Added \(name)"; return true
        }
        phase = "Uploading \(name)"
        let out = await afc(["mkdir \(q(Self.dir))", "put \(q(tone.path)) \(q("\(Self.dir)/\(guid).m4r"))"], udid: udid)
        if let e = Self.failed(out) { log("Ringtone upload: \(e)"); phase = "Upload failed"; return false }
        var p = await readPlist(udid: udid)
        var list = p["Ringtones"] as? [String: Any] ?? [:]
        let pid = Int.random(in: 1_000_000_000...Int(Int32.max))
        list["\(guid).m4r"] = ["GUID": guid, "Name": name, "PID": pid, "Protected Content": false, "Total Time": Int(length * 1000)]
        p["Ringtones"] = list
        guard await writePlist(p, udid: udid) else { phase = "Could not update the tone list"; return false }
        log("Ringtone added: \(name) (\(Int(length)) s)")
        phase = "Added \(name)"
        await load(udid: udid)
        return true
    }

    func remove(_ t: Ringtone, udid: String) async {
        guard !running else { return }
        running = true; phase = "Removing \(t.name)"
        defer { running = false }
        if Demo.on { tones.removeAll { $0 == t }; phase = ""; return }
        let out = await afc(["rm \(q("\(Self.dir)/\(t.file)"))"], udid: udid)
        if let e = Self.failed(out) { log("Remove ringtone: \(e)") }
        var p = await readPlist(udid: udid)
        var list = p["Ringtones"] as? [String: Any] ?? [:]
        list[t.file] = nil
        p["Ringtones"] = list
        _ = await writePlist(p, udid: udid)
        log("Ringtone removed: \(t.name)")
        phase = ""
        await load(udid: udid)
    }

    nonisolated static func duration(of url: URL) async -> Double {
        (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
    }

    nonisolated private static func export(_ source: URL, to out: URL, start: Double, length: Double) async throws {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(domain: "Decant", code: 1, userInfo: [NSLocalizedDescriptionKey: "This file has no audio that can be converted"])
        }
        session.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: length, preferredTimescale: 600))
        try await session.export(to: out, as: .m4a)
    }
}

// MARK: - Pane (Files tab → Ringtones)

struct RingtonesPane: View {
    @EnvironmentObject var manager: DeviceManager
    @StateObject private var service = RingtoneService()
    @State private var selection = Set<String>()
    @State private var adding: URL?
    @State private var confirmRemove = false
    @State private var dropTargeted = false

    private var udid: String { Lockdown.cachedUDID ?? "" }
    private var ready: Bool { manager.device != nil && Lockdown.available && !udid.isEmpty && Tools.has("afcclient") }
    private var selected: [Ringtone] { service.tones.filter { selection.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Ringtones").font(.system(size: 13, weight: .medium))
                Text("\(service.tones.count) \(service.tones.count == 1 ? "tone" : "tones")").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                if service.loading { ProgressView().controlSize(.mini) }
                Spacer()
                Button("Remove…") { confirmRemove = true }.disabled(selected.isEmpty || service.running)
                Button("Add Ringtone…", action: chooseAudio).buttonStyle(.borderedProminent).disabled(!ready || service.running)
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .frame(height: 40)
            Divider()
            if !ready {
                VStack(spacing: 8) {
                    Image(systemName: "bell").font(.system(size: 44, weight: .light)).foregroundStyle(.tertiary)
                    Text(manager.device == nil ? manager.statusText : "This build is missing the file service").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(service.tones, selection: $selection) {
                    TableColumn("Name") { t in
                        HStack(spacing: 8) {
                            Image(systemName: "bell").foregroundStyle(.secondary)
                            Text(t.name)
                        }
                    }
                    TableColumn("Length") { t in Text(t.duration > 0 ? ThumbCell.clock(t.duration) : "–").foregroundStyle(.secondary).monospacedDigit() }.width(80)
                    TableColumn("File") { t in Text(t.file).foregroundStyle(.secondary).font(.system(size: 12, design: .monospaced)) }.width(200)
                }
                .overlay {
                    if service.tones.isEmpty && service.loaded && !service.loading {
                        VStack(spacing: 8) {
                            Text("No custom ringtones on this iPhone").foregroundStyle(.secondary)
                            Text("Add one from any song, voice memo or video. Drop a file here or use Add Ringtone.").font(.system(size: 12)).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            Divider()
            Text("Tones go to Settings → Sounds & Haptics → Ringtone, under their own Ringtones heading, and can be set per contact. The phone shows a new tone right away; a removed one disappears once Settings is reopened.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16).padding(.vertical, 10)
            if service.running || !service.phase.isEmpty {
                Divider()
                HStack(spacing: 12) {
                    if service.running { ProgressView().controlSize(.small) }
                    Text(service.phase).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16).frame(height: 40).background(.bar)
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 2).padding(8)
                    .overlay(Text("Drop audio to make a ringtone").font(.headline))
                    .background(Color.accentColor.opacity(0.06))
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard ready, let p = providers.first else { return false }
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { Task { @MainActor in adding = url } }
            }
            return true
        }
        .sheet(item: $adding) { url in
            NewRingtoneSheet(source: url) { name, start, length in
                Task { _ = await service.add(source: url, name: name, start: start, length: length, udid: udid) }
            }
        }
        .alert("Remove \(selected.count == 1 ? (selected.first?.name ?? "this tone") : "\(selected.count) tones") from the iPhone?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { let s = selected; selection = []; Task { for t in s { await service.remove(t, udid: udid) } } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The tone is deleted from the phone. Keep the original audio file if you want it back.") }
        .onAppear { service.log = { [weak manager] in manager?.addLog($0) }; if ready, !service.loaded { Task { await service.load(udid: udid) } } }
        .onChange(of: manager.catalogComplete) { ok in if ok, ready { Task { await service.load(udid: udid) } } }
    }

    private func chooseAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie, .quickTimeMovie, .mp3, .mpeg4Audio, .wav, .aiff]
        panel.canChooseDirectories = false
        panel.prompt = "Choose"
        panel.message = "Pick a song, recording or video. The next step cuts it to ringtone length."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        adding = url
    }
}

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }

/// Choosing the part of the file that becomes the tone: name, start point and length, with a preview.
struct NewRingtoneSheet: View {
    let source: URL
    let add: (String, Double, Double) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var total: Double = 0
    @State private var start: Double = 0
    @State private var length: Double = 30
    @State private var player: AVPlayer?
    @State private var playing = false

    private var maxStart: Double { max(0, total - 1) }
    private var effectiveLength: Double { min(length, max(1, total - start)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New Ringtone").font(.system(size: 17, weight: .semibold))
                Text("\(source.lastPathComponent) · \(total > 0 ? ThumbCell.clock(total) : "reading…")").font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 16) {
                GridRow {
                    label("Name")
                    TextField("Name shown in Settings", text: $name).textFieldStyle(.roundedBorder).frame(width: 300)
                }
                GridRow {
                    label("Length")
                    Picker("", selection: $length) {
                        Text("30 seconds").tag(30.0)
                        Text("40 seconds").tag(40.0)
                        Text("Whole file").tag(3600.0)
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 300)
                }
                GridRow {
                    label("Start at")
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            Slider(value: $start, in: 0...max(maxStart, 0.001)).frame(width: 300).disabled(total == 0)
                            Text(ThumbCell.clock(start)).monospacedDigit().frame(width: 48, alignment: .leading)
                        }
                        // Where the tone sits in the file: a neutral track with the chosen stretch raised.
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3).fill(.quaternary)
                                if total > 0 {
                                    RoundedRectangle(cornerRadius: 3).fill(.tertiary)
                                        .frame(width: max(4, g.size.width * effectiveLength / total))
                                        .offset(x: g.size.width * start / total)
                                }
                            }
                        }
                        .frame(width: 300, height: 8)
                        Text("Tone: \(ThumbCell.clock(start)) to \(ThumbCell.clock(start + effectiveLength))").font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            .font(.system(size: 13))
            HStack(spacing: 8) {
                Button(playing ? "Stop" : "Preview", action: togglePreview).disabled(total == 0)
                Spacer()
                Button("Cancel") { stop(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add to iPhone") { stop(); add(name.trimmingCharacters(in: .whitespaces), start, effectiveLength); dismiss() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || total == 0)
            }
        }
        .padding(24)
        .frame(width: 480)
        .task {
            name = source.deletingPathExtension().lastPathComponent
            total = await RingtoneService.duration(of: source)
            if total > 0 && total < length { length = total < 30 ? 3600 : length }
        }
        .onChange(of: start) { _ in if playing { stop(); togglePreview() } }
        .onDisappear(perform: stop)
    }

    private func label(_ s: String) -> some View { Text(s).foregroundStyle(.secondary).frame(width: 64, alignment: .leading) }

    private func togglePreview() {
        if playing { stop(); return }
        let p = AVPlayer(url: source)
        p.seek(to: CMTime(seconds: start, preferredTimescale: 600))
        p.play(); player = p; playing = true
        let end = start + effectiveLength
        Task { @MainActor in
            while playing, let p = player, p.currentTime().seconds < end { try? await Task.sleep(nanoseconds: 100_000_000) }
            if playing { stop() }
        }
    }

    private func stop() { player?.pause(); player = nil; playing = false }
}
