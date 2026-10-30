import SwiftUI

// MARK: - Backup & Restore

struct BackupPane: View {
    @EnvironmentObject var manager: DeviceManager
    @EnvironmentObject var backups: BackupService
    @AppStorage("backupRoot") private var backupRoot = BackupService.defaultRoot.path
    @AppStorage("backupEncrypt") private var encrypt = false
    @State private var password = ""
    @State private var selection: String? = "phone"
    @State private var restoring: BackupInfo?
    @State private var restoreConfirmed = false
    @State private var restorePassword = ""
    @State private var deleting: BackupInfo?
    @State private var badFolder = false
    let showLog: () -> Void

    private var root: URL { URL(fileURLWithPath: backupRoot) }
    private var udid: String { Lockdown.cachedUDID ?? "" }
    private var ready: Bool { manager.device != nil && Lockdown.available && !backups.running && !udid.isEmpty }
    private var selectedBackup: BackupInfo? { (backups.backups + backups.finderBackups).first { $0.id == selection } }
    private var latest: BackupInfo? { (backups.backups + backups.finderBackups).max { $0.date < $1.date } }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selection) {
                Section("Device") {
                    HStack(spacing: 8) {
                        Image(systemName: "iphone").font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 20)
                        Text(manager.device?.name ?? "This iPhone")
                        Spacer()
                    }
                    .frame(height: 24).tag("phone")
                }
                Section("Decant backups") {
                    if backups.backups.isEmpty {
                        Text("None yet").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    ForEach(backups.backups) { b in sidebarRow(b).tag(b.id) }
                }
                Section("Finder backups") {
                    if !backups.finderBackupsReadable {
                        Text("Needs Full Disk Access").font(.system(size: 12)).foregroundStyle(.secondary)
                    } else if backups.finderBackups.isEmpty {
                        Text("None on this Mac").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    ForEach(backups.finderBackups) { b in sidebarRow(b).tag(b.id) }
                }
            }
            .listStyle(.sidebar)
            .frame(width: 240)
            Divider()
            Group {
                if let b = selectedBackup { backupDetail(b) } else { phoneDetail }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear { backups.log = { [weak manager] in manager?.addLog($0) }; backups.scan(root) }
        .alert("Restore this backup?", isPresented: Binding(get: { restoring != nil && !restoreConfirmed }, set: { if !$0 { restoring = nil } })) {
            Button("Continue", role: .destructive) { restoreConfirmed = true }
            Button("Cancel", role: .cancel) { restoring = nil }
        } message: {
            if let r = restoring {
                Text("\(r.deviceName), iOS \(r.version), \(r.date.formatted(date: .abbreviated, time: .shortened)). Everything currently on the iPhone will be replaced.")
            }
        }
        .alert("Last check", isPresented: $restoreConfirmed) {
            if restoring?.encrypted == true { SecureField("Backup password", text: $restorePassword) }
            Button("Restore and Reboot", role: .destructive) {
                if let r = restoring { Task { await backups.restore(r, udid: udid, password: r.encrypted ? restorePassword : nil) } }
                restoring = nil; restorePassword = ""
            }
            .disabled(restoring?.encrypted == true && restorePassword.isEmpty)
            Button("Cancel", role: .cancel) { restoring = nil; restorePassword = "" }
        } message: {
            Text(restoring?.encrypted == true ? "This backup is encrypted. Enter its password to continue." : "The iPhone will restart when the restore finishes.")
        }
        .alert("That folder is not an iPhone backup", isPresented: $badFolder) {
            Button("OK") {}
        } message: { Text("Pick the backup folder itself (it contains Info.plist and Manifest.plist) or the folder that holds it.") }
        .alert("Move this backup to the Trash?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Move to Trash", role: .destructive) { if let d = deleting { backups.delete(d, root: root); selection = "phone" } }
            Button("Cancel", role: .cancel) {}
        } message: { Text(deleting.map { "\($0.deviceName), \($0.date.formatted(date: .abbreviated, time: .shortened)), \(DeviceManager.gb($0.size))" } ?? "") }
    }

    private func sidebarRow(_ b: BackupInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: b.encrypted ? "lock" : "externaldrive").font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(b.deviceName).lineLimit(1)
                Text(b.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            Text(DeviceManager.gb(b.size)).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
        }
        .frame(height: 32)
    }

    // MARK: Device page: status, destination, encryption, the primary action, and what a backup holds

    private var phoneDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(manager.device?.name ?? "No iPhone").font(.system(size: 20, weight: .semibold))
                    Text(latest.map { "Last backed up \($0.date.formatted(.relative(presentation: .named))) · \(DeviceManager.gb($0.size))" }
                         ?? (manager.device == nil ? manager.statusText : "Never backed up with this Mac"))
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 0) {
                    GridRow {
                        label("Backups go to")
                        HStack(spacing: 8) {
                            Text(DeviceDashboard.shortPath(root)).lineLimit(1).truncationMode(.middle)
                            Button("Change…", action: chooseRoot).buttonStyle(.link)
                            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([root]) }.buttonStyle(.link)
                        }
                    }
                    .frame(height: 32)
                    GridRow {
                        label("Free space")
                        Text(DeviceManager.freeSpace(at: root).map(DeviceManager.gb) ?? "–").monospacedDigit()
                    }
                    .frame(height: 32)
                    GridRow {
                        label("Size on iPhone")
                        Text(manager.storage.map { DeviceManager.gb($0.capacity - $0.free) + " used" } ?? "–").monospacedDigit()
                    }
                    .frame(height: 32)
                    GridRow {
                        label("Encryption")
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Encrypt backup", isOn: $encrypt)
                            if encrypt {
                                SecureField("Backup password", text: $password).frame(width: 240)
                            }
                            Text("Encrypted backups also hold Health data, saved passwords and Wi-Fi settings. The password is not recoverable.")
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 6)
                    }
                }
                .font(.system(size: 13))

                if backups.running {
                    HStack(spacing: 12) {
                        ProgressView(value: backups.progress ?? 0).frame(maxWidth: 360)
                        Text("\(backups.phase) \(backups.progress.map { "\(Int($0 * 100))%" } ?? "")").font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
                        Spacer()
                        Button("Stop") { backups.cancel() }
                    }
                } else {
                    HStack(spacing: 8) {
                        Button("Back Up Now") {
                            Task { await backups.backup(udid: udid, to: root, password: encrypt ? password : nil) }
                        }
                        .buttonStyle(.borderedProminent).disabled(!ready || (encrypt && password.isEmpty))
                        Button("Restore from Folder…", action: restoreFromFolder).disabled(!ready)
                        if !backups.phase.isEmpty { Text(backups.phase).font(.system(size: 13)).foregroundStyle(.secondary).padding(.leading, 8) }
                    }
                    .controlSize(.large)
                }

                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("What a backup holds").font(.system(size: 13, weight: .medium))
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                        GridRow { include("Messages, call history, notes, voice memos") ; include("App data and documents") }
                        GridRow { include("Home screen layout and settings") ; include("Photos and videos, unless iCloud Photos keeps them") }
                        GridRow { include("Health, passwords, Wi-Fi: encrypted backups only") ; include("Not included: apps themselves, Face ID, Apple Pay cards") }
                    }
                    .font(.system(size: 12))
                    Text("A restore replaces everything on the iPhone with the backup and reboots it. Decant asks twice and never restores on its own.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 4)
                }
                if !backups.finderBackupsReadable {
                    Divider()
                    HStack(spacing: 12) {
                        Text("Decant needs Full Disk Access to list backups made with Finder or iTunes.").font(.system(size: 12)).foregroundStyle(.secondary)
                        Button("Open Privacy Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                        }.controlSize(.small)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    private func include(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(.tertiary).frame(width: 4, height: 4).offset(y: -3)
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Backup page

    private func backupDetail(_ b: BackupInfo) -> some View {
        let isDecant = backups.backups.contains(b)
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(b.deviceName).font(.system(size: 20, weight: .semibold))
                    Text(b.date.formatted(date: .complete, time: .shortened)).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 0) {
                    detailRow("iOS version", b.version)
                    detailRow("Size", DeviceManager.gb(b.size))
                    detailRow("Encrypted", b.encrypted ? "Yes" : "No")
                    detailRow("Made with", isDecant ? "Decant" : "Finder or iTunes")
                    GridRow {
                        label("Location")
                        HStack(spacing: 8) {
                            Text(DeviceDashboard.shortPath(b.url)).lineLimit(1).truncationMode(.middle)
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([b.url]) }.buttonStyle(.link)
                        }
                    }
                    .frame(height: 32)
                }
                .font(.system(size: 13))
                HStack(spacing: 8) {
                    Button("Restore to iPhone…") { restoring = b }.disabled(!ready)
                    if isDecant { Button("Move to Trash…") { deleting = b }.disabled(backups.running) }
                }
                .controlSize(.large)
                Text(ready ? "Restoring puts this backup on \(manager.device?.name ?? "the connected iPhone") and reboots it."
                           : "Connect and unlock an iPhone to restore this backup.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    private func detailRow(_ k: String, _ v: String) -> some View {
        GridRow { label(k); Text(v).monospacedDigit() }.frame(height: 32)
    }

    private func label(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary).frame(width: 128, alignment: .leading)
    }

    private func restoreFromFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Use this backup"
        panel.message = "Choose an iPhone backup folder (Decant, Finder or iTunes)"
        guard panel.runModal() == .OK, let u = panel.url else { return }
        if let info = backups.info(for: u) { restoring = info } else { badFolder = true }
    }

    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.directoryURL = root
        if panel.runModal() == .OK, let u = panel.url { backupRoot = u.path; backups.scan(u) }
    }
}

// MARK: - Firmware

struct FirmwarePane: View {
    @EnvironmentObject var manager: DeviceManager
    @EnvironmentObject var firmware: FirmwareService
    @AppStorage("firmwareRoot") private var firmwareRoot = FirmwareService.defaultRoot.path
    @AppStorage("autoSaveBlobs") private var autoSaveBlobs = true
    @AppStorage("blobGenerator") private var generator = FirmwareService.generator
    @State private var restoreTarget: (fw: Firmware, erase: Bool, future: Bool)?
    @State private var confirmStep = 0
    @State private var revealECID = false
    let showLog: () -> Void

    private var root: URL { URL(fileURLWithPath: firmwareRoot) }
    private var ecid: String { manager.info?.ecid ?? "" }
    private var board: String { manager.info?.hardware ?? "" }
    private var model: String { manager.info?.model ?? "" }
    private var connected: Bool { manager.device != nil && !ecid.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                statusCard
                blobsSection
                firmwareSection
                recoveryRow
                Text("Signed versions can be restored or updated any time. An unsigned version needs a blob saved for it, and the phone's nonce set to the blob's generator (\(FirmwareService.generator)), which on A12 and newer chips only a jailbreak can do. Decant saves blobs with that generator so the restore is possible later.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 1000, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            firmware.log = { [weak manager] in manager?.addLog($0) }
            refresh()
        }
        .onChange(of: manager.info?.model) { _ in refresh() }
        .alert(firstTitle, isPresented: Binding(get: { restoreTarget != nil && confirmStep == 1 }, set: { if !$0 { restoreTarget = nil; confirmStep = 0 } })) {
            Button("Continue", role: .destructive) { confirmStep = 2 }
            Button("Cancel", role: .cancel) { restoreTarget = nil; confirmStep = 0 }
        } message: { Text(firstMessage) }
        .alert("Last check", isPresented: Binding(get: { restoreTarget != nil && confirmStep == 2 }, set: { if !$0 { restoreTarget = nil; confirmStep = 0 } })) {
            Button(restoreTarget?.erase == true ? "Erase and Restore" : "Update", role: .destructive) { runRestore() }
            Button("Cancel", role: .cancel) { restoreTarget = nil; confirmStep = 0 }
        } message: { Text("Keep the cable connected until the iPhone finishes and shows the Hello screen or your lock screen.") }
    }

    private func refresh() {
        guard !model.isEmpty else { return }
        Task {
            await firmware.loadSigning(productType: model)
            firmware.scanBlobs(root: root, ecid: ecid)
            await firmware.refreshMode()
            if autoSaveBlobs && !ecid.isEmpty && !board.isEmpty && Tools.has("decant-tss") && FirmwareService.validGenerator(generator) {
                await firmware.saveBlobs(ecid: ecid, productType: model, board: board, basebandSerial: manager.info?.basebandSerial ?? "", basebandCert: manager.info?.basebandCert ?? "", root: root, generator: generator)
            }
        }
    }

    private var statusCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(connected ? "iOS \(manager.info?.version ?? "–")" : "No iPhone connected").font(.system(size: 22, weight: .medium))
                    if connected { Text("\(manager.info?.marketingName ?? "") · \(model) · \(board)").font(.callout).foregroundStyle(.secondary) }
                    Spacer()
                }
                Grid(alignment: .leading, horizontalSpacing: 32, verticalSpacing: 0) {
                    GridRow {
                        infoRow("ECID") {
                            if connected {
                                Text(revealECID ? ecid : String(repeating: "•", count: max(ecid.count, 8))).monospaced()
                                Button { revealECID.toggle() } label: { Image(systemName: revealECID ? "eye.slash" : "eye").font(.system(size: 12)).foregroundStyle(.secondary) }.buttonStyle(.borderless)
                            } else { Text("–") }
                        }
                        infoRow("Mode") { Text(connected ? firmware.mode.rawValue : "–") }
                    }
                    GridRow {
                        infoRow("Signed now") { Text(firmware.firmwares.filter { firmware.isSigned($0) }.map { $0.version }.joined(separator: ", ")).lineLimit(1) }
                        infoRow("Blobs saved") { Text(connected ? "\(firmware.blobs.count)" : "–").monospacedDigit() }
                    }
                }
                HStack {
                    Toggle("Save blobs automatically when the iPhone connects", isOn: $autoSaveBlobs)
                    Spacer()
                    Text("Files go to \(DeviceDashboard.shortPath(root))").foregroundStyle(.secondary)
                    Button("Change…", action: chooseRoot).buttonStyle(.link)
                }
                .font(.system(size: 13))
                HStack(spacing: 8) {
                    Text("Generator").foregroundStyle(.secondary).frame(width: 112, alignment: .leading)
                    TextField("0x1111111111111111", text: $generator).textFieldStyle(.roundedBorder).monospaced().frame(width: 190)
                    if !FirmwareService.validGenerator(generator) {
                        Text("Needs 0x and 16 hex digits").foregroundStyle(Tone.warning)
                    } else if generator != FirmwareService.generator {
                        Button("Use the default") { generator = FirmwareService.generator }.buttonStyle(.link)
                    } else {
                        Text("The convention every guide and tool uses; a blob only works if the phone is set to the same value").foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .font(.system(size: 13))
                if firmware.running {
                    HStack(spacing: 12) {
                        ProgressView(value: firmware.progress ?? 0).frame(maxWidth: 360).opacity(firmware.progress == nil ? 0 : 1)
                            .overlay { if firmware.progress == nil { ProgressView().controlSize(.small) } }
                        Text(firmware.phase).font(.system(size: 13)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Stop") { firmware.cancel() }
                    }
                }
            }
        }
    }

    private func infoRow<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 112, alignment: .leading)
            content().fontWeight(.medium)
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .frame(height: 32)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var blobsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SHSH blobs").font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
                Button("Save Blobs Now") { Task { await firmware.saveBlobs(ecid: ecid, productType: model, board: board, basebandSerial: manager.info?.basebandSerial ?? "", basebandCert: manager.info?.basebandCert ?? "", root: root, generator: generator) } }
                    .controlSize(.small).disabled(!connected || firmware.running || !Tools.has("decant-tss") || !FirmwareService.validGenerator(generator))
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([FirmwareService.blobDir(root, ecid: ecid)]) }
                    .controlSize(.small).disabled(!connected)
            }
            Text("Saved blobs are never replaced or deleted by Decant: Save Blobs Now only adds versions that are missing, and each file is locked read-only on disk.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Card {
                if !Tools.has("decant-tss") {
                    Text("This build has no blob saver").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 48)
                } else if firmware.blobs.isEmpty {
                    Text(connected ? "No blobs saved for this iPhone yet" : "Connect an iPhone").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 48)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(firmware.blobs.enumerated()), id: \.element.id) { i, b in
                            HStack(spacing: 12) {
                                Image(systemName: "checkmark.seal").font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 24)
                                Text("iOS \(b.version) (\(b.build))").font(.system(size: 13, weight: .medium))
                                Text(b.generator.map { "generator \($0)" } ?? "no generator").font(.system(size: 12)).foregroundStyle(.secondary).monospaced()
                                Spacer()
                                Text(b.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8).frame(height: 40)
                            .overlay(alignment: .bottom) { if i < firmware.blobs.count - 1 { Divider().padding(.leading, 44) } }
                        }
                    }
                    .padding(-8)
                }
            }
        }
    }

    private var firmwareSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Firmware for \(manager.info?.marketingName ?? "this model")").font(.system(size: 13)).foregroundStyle(.secondary)
            Card {
                if firmware.firmwares.isEmpty {
                    Text(connected ? "Loading signing status…" : "Connect an iPhone").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 48)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(firmware.firmwares.prefix(12).enumerated()), id: \.element.id) { i, fw in
                            firmwareRow(fw, last: i == min(firmware.firmwares.count, 12) - 1)
                        }
                    }
                    .padding(-8)
                }
            }
        }
    }

    private func ipswPath(_ fw: Firmware) -> URL? {
        let u = FirmwareService.ipswDir(root).appendingPathComponent(fw.url.lastPathComponent)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    private func blob(for fw: Firmware) -> BlobInfo? { firmware.blobs.first { $0.build == fw.buildid } }

    private func firmwareRow(_ fw: Firmware, last: Bool) -> some View {
        let downloaded = ipswPath(fw) != nil
        let hasBlob = blob(for: fw) != nil
        let current = fw.version == manager.info?.version
        let signed = firmware.isSigned(fw)
        return HStack(spacing: 12) {
            Circle().fill(signed ? Tone.ready : Color(nsColor: .tertiaryLabelColor)).frame(width: 7, height: 7).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("iOS \(fw.version)").font(.system(size: 13, weight: .medium))
                    if current { Text("installed").font(.system(size: 11)).foregroundStyle(.secondary) }
                }
                Text("\(fw.buildid) · \(DeviceManager.gb(fw.filesize)) · \(fw.releasedate.prefix(10)) · \(signed ? "signed" : "unsigned")\(hasBlob ? " · blob saved" : "")")
                    .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            if downloaded {
                Text("downloaded").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Button("Download") { Task { _ = await firmware.downloadIPSW(fw, root: root) } }.disabled(firmware.running)
            }
            if signed {
                Button("Update…") { restoreTarget = (fw, false, false); confirmStep = 1 }.disabled(!connected || !downloaded || firmware.running || !Tools.has("idevicerestore"))
                Button("Restore…") { restoreTarget = (fw, true, false); confirmStep = 1 }.disabled(!connected || !downloaded || firmware.running || !Tools.has("idevicerestore"))
            } else {
                Button("Future Restore…") { restoreTarget = (fw, true, true); confirmStep = 1 }
                    .disabled(!connected || !downloaded || !hasBlob || firmware.running || !Tools.has("futurerestore"))
                    .help(hasBlob ? "Needs the phone's nonce set to the blob's generator" : "No blob saved for this version")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .frame(height: 56)
        .overlay(alignment: .bottom) { if !last { Divider().padding(.leading, 44) } }
    }

    private var recoveryRow: some View {
        HStack(spacing: 8) {
            Text("Recovery").font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 112, alignment: .leading)
            Text("Mode: \(connected || firmware.mode != .none ? firmware.mode.rawValue : "–")").font(.system(size: 13))
            Button("Enter Recovery…") { Task { if let u = Lockdown.firstUDID() { await firmware.enterRecovery(udid: u) } } }
                .disabled(!connected || firmware.running || !Tools.has("ideviceenterrecovery"))
            Button("Exit Recovery") { Task { await firmware.exitRecovery() } }
                .disabled(firmware.running || !Tools.has("irecovery"))
            Button("Check") { Task { await firmware.refreshMode() } }.disabled(firmware.running)
            Spacer()
            Button("Show Log", action: showLog)
        }
        .controlSize(.small)
    }

    private var firstTitle: String {
        guard let t = restoreTarget else { return "" }
        return t.future ? "Restore to unsigned iOS \(t.fw.version)?" : t.erase ? "Erase and restore to iOS \(t.fw.version)?" : "Update to iOS \(t.fw.version)?"
    }

    private var firstMessage: String {
        guard let t = restoreTarget else { return "" }
        if t.future { return "futurerestore will use your saved blob with the latest signed SEP and baseband. The phone's nonce must already match the blob's generator or it will fail with APNonce mismatch. All data is erased." }
        return t.erase ? "All data on the iPhone is erased. Make a backup first if you have not." : "Your data stays; the system is replaced with iOS \(t.fw.version)."
    }

    private func runRestore() {
        guard let t = restoreTarget, let ipsw = ipswPath(t.fw) else { restoreTarget = nil; confirmStep = 0; return }
        restoreTarget = nil; confirmStep = 0
        Task {
            if t.future, let b = blob(for: t.fw) { await firmware.futureRestore(blob: b.url, ipsw: ipsw, erase: true) }
            else { await firmware.restore(ipsw: ipsw, erase: t.erase) }
        }
    }

    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.directoryURL = root
        if panel.runModal() == .OK, let u = panel.url { firmwareRoot = u.path; firmware.scanBlobs(root: u, ecid: ecid) }
    }
}
