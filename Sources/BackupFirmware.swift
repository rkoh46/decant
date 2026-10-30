import SwiftUI

// MARK: - Backup & Restore

struct BackupPane: View {
    @EnvironmentObject var manager: DeviceManager
    @EnvironmentObject var backups: BackupService
    @AppStorage("backupRoot") private var backupRoot = BackupService.defaultRoot.path
    @AppStorage("backupEncrypt") private var encrypt = false
    @State private var password = ""
    @State private var restoring: BackupInfo?
    @State private var restoreConfirmed = false
    @State private var restorePassword = ""
    @State private var deleting: BackupInfo?
    @State private var badFolder = false
    let showLog: () -> Void

    private var root: URL { URL(fileURLWithPath: backupRoot) }
    private var udid: String { Lockdown.cachedUDID ?? "" }
    private var ready: Bool { manager.device != nil && Lockdown.available && !backups.running && !udid.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Back up this iPhone").font(.system(size: 15, weight: .medium))
                            Spacer()
                            if let d = manager.device {
                                Text("\(d.name ?? "iPhone") · iOS \(manager.info?.version ?? "–") · \(DeviceManager.gb((manager.storage?.capacity ?? 0) - (manager.storage?.free ?? 0))) used")
                                    .font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        row("Backups go to") {
                            Text(DeviceDashboard.shortPath(root)).lineLimit(1).truncationMode(.middle)
                            Button("Change…", action: chooseRoot).buttonStyle(.link)
                            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([root]) }.buttonStyle(.link)
                            if let free = DeviceManager.freeSpace(at: root) {
                                Text("\(DeviceManager.gb(free)) free").foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        row("Encryption") {
                            Toggle("Encrypt backup", isOn: $encrypt)
                            if encrypt {
                                SecureField("Backup password", text: $password).frame(width: 220)
                                Text("Needed for Health data, saved passwords and Wi-Fi settings").foregroundStyle(.secondary)
                            }
                        }
                        if backups.running {
                            HStack(spacing: 12) {
                                ProgressView(value: backups.progress ?? 0).frame(maxWidth: 360)
                                Text("\(backups.phase) \(backups.progress.map { "\(Int($0 * 100))%" } ?? "")").font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
                                Spacer()
                                Button("Stop") { backups.cancel() }
                            }
                        } else {
                            HStack {
                                Text(backups.phase).font(.system(size: 13)).foregroundStyle(.secondary)
                                Spacer()
                                Button("Restore from Folder…", action: restoreFromFolder).disabled(!ready)
                                Button("Back Up Now") {
                                    Task { await backups.backup(udid: udid, to: root, password: encrypt ? password : nil) }
                                }
                                .buttonStyle(.borderedProminent).disabled(!ready || (encrypt && password.isEmpty))
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Backups").font(.system(size: 13)).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(backups.backups.count)").font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Card {
                        if backups.backups.isEmpty {
                            Text("No backups in this folder yet").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 48)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(backups.backups.enumerated()), id: \.element.id) { i, b in
                                    backupRow(b, last: i == backups.backups.count - 1)
                                }
                            }
                            .padding(-8)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Finder backups").font(.system(size: 13)).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(backups.finderBackups.count)").font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Card {
                        if !backups.finderBackupsReadable {
                            VStack(spacing: 6) {
                                Text("Decant needs Full Disk Access to see backups made with Finder or iTunes").foregroundStyle(.secondary)
                                Button("Open Privacy Settings") {
                                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                                }.controlSize(.small)
                            }
                            .frame(maxWidth: .infinity, minHeight: 48)
                        } else if backups.finderBackups.isEmpty {
                            Text("No Finder or iTunes backups on this Mac").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 48)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(backups.finderBackups.enumerated()), id: \.element.id) { i, b in
                                    backupRow(b, last: i == backups.finderBackups.count - 1, canTrash: false)
                                }
                            }
                            .padding(-8)
                        }
                    }
                }
                Text("A restore replaces everything on the iPhone with the backup and reboots it. Decant asks twice and never restores on its own. Backups from another Mac work too: use Restore from Folder… and pick the backup's folder.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            Button("Move to Trash", role: .destructive) { if let d = deleting { backups.delete(d, root: root) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text(deleting.map { "\($0.deviceName), \($0.date.formatted(date: .abbreviated, time: .shortened)), \(DeviceManager.gb($0.size))" } ?? "") }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 112, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .frame(minHeight: 28)
    }

    private func restoreFromFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Use this backup"
        panel.message = "Choose an iPhone backup folder (Decant, Finder or iTunes)"
        guard panel.runModal() == .OK, let u = panel.url else { return }
        if let info = backups.info(for: u) { restoring = info } else { badFolder = true }
    }

    private func backupRow(_ b: BackupInfo, last: Bool, canTrash: Bool = true) -> some View {
        HStack(spacing: 12) {
            Image(systemName: b.encrypted ? "lock.fill" : "externaldrive").font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(b.deviceName) · iOS \(b.version)").font(.system(size: 13, weight: .medium))
                Text("\(b.date.formatted(date: .long, time: .shortened)) · \(DeviceManager.gb(b.size))\(b.encrypted ? " · encrypted" : "")")
                    .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([b.url]) }
            Button("Restore…") { restoring = b }.disabled(!ready)
            if canTrash {
                Button { deleting = b } label: { Image(systemName: "trash") }.disabled(backups.running)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .frame(height: 56)
        .overlay(alignment: .bottom) { if !last { Divider().padding(.leading, 44) } }
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
