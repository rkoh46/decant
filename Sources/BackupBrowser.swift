// Reads iPhone backups (Finder / iTunes / idevicebackup2 format) and exports what people actually
// want out of them: messages, contacts, calls, notes, voice memos, Safari history and WhatsApp.
// Engine only, no UI; everything here runs on background tasks. Encrypted backups (iOS 10.2+) are
// unlocked with the keybag algorithm every open-source backup tool implements: PBKDF2 → AES key
// unwrap (RFC 3394) of the class keys → per-file AES-256-CBC with a zero IV.
import Foundation
import SQLite3
import CommonCrypto
import Compression

// MARK: - Public types

struct BackupFile: Hashable {
    let fileID: String
    let domain: String
    let relativePath: String
    let size: Int
    let isDirectory: Bool
}

struct BackupSummary {
    var messages = 0, conversations = 0, contacts = 0, calls = 0, notes = 0, voiceMemos = 0, safariHistory = 0, whatsappChats = 0, whatsappMessages = 0
}

enum BackupExport: String, CaseIterable, Identifiable {
    case messages, contacts, calls, notes, voiceMemos, safari, whatsapp
    var id: String { rawValue }
    var title: String {
        switch self {
        case .messages: return "Messages"
        case .contacts: return "Contacts"
        case .calls: return "Call history"
        case .notes: return "Notes"
        case .voiceMemos: return "Voice memos"
        case .safari: return "Safari history"
        case .whatsapp: return "WhatsApp"
        }
    }
    var symbol: String {
        switch self {
        case .messages: return "message"
        case .contacts: return "person.crop.circle"
        case .calls: return "phone"
        case .notes: return "note.text"
        case .voiceMemos: return "waveform"
        case .safari: return "safari"
        case .whatsapp: return "bubble.left.and.bubble.right"
        }
    }
}

struct BackupError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Reader

final class BackupReader {
    let folder: URL
    let isEncrypted: Bool
    private(set) var isUnlocked: Bool

    private let manifestPlist: [String: Any]
    private var manifest: SQLiteDB?
    private var classKeys: [UInt32: Data] = [:]
    private let scratch: URL
    private var dbCopies: [String: URL?] = [:]      // "domain|path" → extracted copy (nil = absent in backup)
    private let lock = NSLock()

    init(folder: URL) throws {
        self.folder = folder
        let plistURL = folder.appendingPathComponent("Manifest.plist")
        let dbURL = folder.appendingPathComponent("Manifest.db")
        guard FileManager.default.fileExists(atPath: dbURL.path) else { throw BackupError("No Manifest.db in \(folder.lastPathComponent): not an iPhone backup") }
        guard let plistData = try? Data(contentsOf: plistURL),
              let plist = (try? PropertyListSerialization.propertyList(from: plistData, format: nil)) as? [String: Any] else {
            throw BackupError("No Manifest.plist in \(folder.lastPathComponent): not an iPhone backup")
        }
        manifestPlist = plist
        isEncrypted = (plist["IsEncrypted"] as? Bool) ?? false
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("BackupReader-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        if isEncrypted {
            isUnlocked = false
        } else {
            manifest = try SQLiteDB(path: dbURL.path, immutable: true)
            isUnlocked = true
        }
    }

    deinit { close() }

    func close() {
        lock.lock(); defer { lock.unlock() }
        manifest = nil
        try? FileManager.default.removeItem(at: scratch)
        dbCopies.removeAll()
    }

    // MARK: Unlocking

    func unlock(password: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard isEncrypted else { isUnlocked = true; return }
        guard let keybag = manifestPlist["BackupKeyBag"] as? Data,
              let manifestKey = manifestPlist["ManifestKey"] as? Data, manifestKey.count >= 44 else {
            throw BackupError("Manifest.plist has no keybag")
        }
        let bag = try Keybag(data: keybag)
        let passwordKey = try bag.passwordKey(password: password)
        var keys: [UInt32: Data] = [:]
        var attempted = 0
        for c in bag.classes where c.wrap & 2 != 0 {
            attempted += 1
            if let k = BackupCrypto.unwrap(kek: passwordKey, wrapped: c.wpky) { keys[c.clas] = k }
        }
        guard attempted > 0 else { throw BackupError("Keybag has no passcode-protected classes") }
        guard !keys.isEmpty else { throw BackupError("Wrong password") }
        let cls = manifestKey.readUInt32LE(at: 0)
        guard let classKey = keys[cls], let dbKey = BackupCrypto.unwrap(kek: classKey, wrapped: manifestKey.subdata(in: 4..<44)) else {
            throw BackupError("Wrong password")
        }
        let encrypted = try Data(contentsOf: folder.appendingPathComponent("Manifest.db"))
        var plain = BackupCrypto.aesCBCDecrypt(key: dbKey, data: encrypted, padding: true)
        if plain == nil { plain = BackupCrypto.aesCBCDecrypt(key: dbKey, data: encrypted, padding: false) }
        guard let decrypted = plain, decrypted.count > 100, decrypted.prefix(15) == Data("SQLite format 3".utf8) else {
            throw BackupError("Wrong password")
        }
        let copy = scratch.appendingPathComponent("Manifest.db")
        try decrypted.write(to: copy)
        manifest = try SQLiteDB(path: copy.path, immutable: false)
        classKeys = keys
        isUnlocked = true
    }

    private func db() throws -> SQLiteDB {
        guard isUnlocked, let m = manifest else { throw BackupError(isEncrypted ? "This backup is encrypted: unlock it first" : "Backup is closed") }
        return m
    }

    // MARK: Files

    private struct Record {
        let size: Int
        let modified: Date?
        let encryptionKey: Data?
        let protectionClass: UInt32
    }

    private func record(from blob: Data?) -> Record {
        guard let blob, let root = KeyedArchive.root(of: blob) else { return Record(size: 0, modified: nil, encryptionKey: nil, protectionClass: 0) }
        let size = (root["Size"] as? Int) ?? 0
        var modified: Date?
        if let m = root["LastModified"] as? Int, m > 0 { modified = Date(timeIntervalSince1970: TimeInterval(m)) }
        var key: Data?
        if let k = root["EncryptionKey"] as? [String: Any], let d = k["NS.data"] as? Data { key = d }
        else if let d = root["EncryptionKey"] as? Data { key = d }
        let cls = UInt32(truncatingIfNeeded: (root["ProtectionClass"] as? Int) ?? 0)
        return Record(size: size, modified: modified, encryptionKey: key, protectionClass: cls)
    }

    private func makeFile(_ row: SQLRow) -> BackupFile {
        let rec = record(from: row.data("file"))
        let flags = row.int("flags") ?? 1
        return BackupFile(fileID: row.string("fileID") ?? "", domain: row.string("domain") ?? "", relativePath: row.string("relativePath") ?? "", size: rec.size, isDirectory: flags == 2)
    }

    func files(domain: String, prefix: String? = nil) throws -> [BackupFile] {
        lock.lock(); defer { lock.unlock() }
        let m = try db()
        var sql = "SELECT fileID, domain, relativePath, flags, file FROM Files WHERE domain = ?"
        var binds: [SQLValue] = [.text(domain)]
        if let prefix {
            sql += " AND relativePath >= ? AND relativePath < ?"
            binds.append(.text(prefix)); binds.append(.text(prefix + "\u{FFFF}"))
        }
        sql += " ORDER BY relativePath"
        return try m.rows(sql, binds).map(makeFile)
    }

    func file(domain: String, path: String) throws -> BackupFile? {
        lock.lock(); defer { lock.unlock() }
        return try fileUnlocked(domain: domain, path: path)
    }

    private func fileUnlocked(domain: String, path: String) throws -> BackupFile? {
        let m = try db()
        return try m.rows("SELECT fileID, domain, relativePath, flags, file FROM Files WHERE domain = ? AND relativePath = ? LIMIT 1", [.text(domain), .text(path)]).first.map(makeFile)
    }

    private func blobURL(for fileID: String) -> URL? {
        guard fileID.count >= 2 else { return nil }
        let nested = folder.appendingPathComponent(String(fileID.prefix(2))).appendingPathComponent(fileID)
        if FileManager.default.fileExists(atPath: nested.path) { return nested }
        let flat = folder.appendingPathComponent(fileID)
        if FileManager.default.fileExists(atPath: flat.path) { return flat }
        return nil
    }

    private func recordFor(_ f: BackupFile) throws -> Record {
        let m = try db()
        guard let row = try m.rows("SELECT file FROM Files WHERE fileID = ? LIMIT 1", [.text(f.fileID)]).first else { throw BackupError("\(f.relativePath) is not in the manifest") }
        return record(from: row.data("file"))
    }

    func data(of f: BackupFile) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        return try dataUnlocked(of: f)
    }

    private func dataUnlocked(of f: BackupFile) throws -> Data {
        guard !f.isDirectory else { throw BackupError("\(f.relativePath) is a folder") }
        guard let url = blobURL(for: f.fileID) else { throw BackupError("\(f.relativePath) is missing from the backup folder") }
        let raw = try Data(contentsOf: url)
        guard isEncrypted else { return raw }
        let rec = try recordFor(f)
        guard let ek = rec.encryptionKey, ek.count >= 44 else { return raw }
        let cls = ek.readUInt32LE(at: 0)
        guard let classKey = classKeys[cls] else { throw BackupError("No key for protection class \(cls) (\(f.relativePath))") }
        guard let fileKey = BackupCrypto.unwrap(kek: classKey, wrapped: ek.subdata(in: 4..<44)) else { throw BackupError("Could not unwrap the key of \(f.relativePath)") }
        guard var plain = BackupCrypto.aesCBCDecrypt(key: fileKey, data: raw, padding: false) else { throw BackupError("Could not decrypt \(f.relativePath)") }
        if rec.size > 0 && plain.count > rec.size { plain = plain.prefix(rec.size) }
        return plain
    }

    func extract(_ f: BackupFile, to url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        try extractUnlocked(f, to: url)
    }

    private func extractUnlocked(_ f: BackupFile, to url: URL, modified: Date? = nil) throws {
        let data = try dataUnlocked(of: f)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        let mtime = modified ?? (try? recordFor(f))?.modified
        if let mtime { try? FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path) }
    }

    /// Copies a database (and its -wal/-shm siblings) out of the backup and opens the copy. nil when absent.
    private func database(domain: String, path: String) throws -> SQLiteDB? {
        let key = domain + "|" + path
        if let cached = dbCopies[key] {
            guard let url = cached else { return nil }
            return try SQLiteDB(path: url.path, immutable: false)
        }
        guard let f = try fileUnlocked(domain: domain, path: path), !f.isDirectory else { dbCopies[key] = .some(nil); return nil }
        let dir = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = (path as NSString).lastPathComponent
        let copy = dir.appendingPathComponent(name)
        try extractUnlocked(f, to: copy)
        for suffix in ["-wal", "-shm"] {
            if let sib = try fileUnlocked(domain: domain, path: path + suffix), !sib.isDirectory {
                try? extractUnlocked(sib, to: dir.appendingPathComponent(name + suffix))
            }
        }
        dbCopies[key] = copy
        return try SQLiteDB(path: copy.path, immutable: false)
    }

    // MARK: Summary

    func summary() throws -> BackupSummary {
        lock.lock(); defer { lock.unlock() }
        var s = BackupSummary()
        if let db = try database(domain: Self.homeDomain, path: "Library/SMS/sms.db") {
            s.messages = db.count("message")
            s.conversations = db.count("chat")
        }
        if let db = try database(domain: Self.homeDomain, path: "Library/AddressBook/AddressBook.sqlitedb") { s.contacts = db.count("ABPerson") }
        if let db = try database(domain: Self.homeDomain, path: "Library/CallHistoryDB/CallHistory.storedata") { s.calls = db.count("ZCALLRECORD") }
        if let db = try database(domain: Self.notesDomain, path: "NoteStore.sqlite") {
            s.notes = db.scalar("SELECT COUNT(*) FROM ZICCLOUDSYNCINGOBJECT WHERE ZNOTEDATA IS NOT NULL" + (db.hasColumn("ZICCLOUDSYNCINGOBJECT", "ZMARKEDFORDELETION") ? " AND (ZMARKEDFORDELETION IS NULL OR ZMARKEDFORDELETION = 0)" : ""))
        } else if let db = try database(domain: Self.homeDomain, path: "Library/Notes/notes.sqlite") {
            s.notes = db.count("ZNOTE")
        }
        s.voiceMemos = try voiceMemoFiles().count
        if let db = try database(domain: Self.homeDomain, path: "Library/Safari/History.db") { s.safariHistory = db.count("history_visits") }
        if let db = try database(domain: Self.whatsappDomain, path: "ChatStorage.sqlite") {
            s.whatsappChats = db.count("ZWACHATSESSION")
            s.whatsappMessages = db.count("ZWAMESSAGE")
        }
        return s
    }

    // MARK: Export

    static let homeDomain = "HomeDomain"
    static let mediaDomain = "MediaDomain"
    static let notesDomain = "AppDomainGroup-group.com.apple.notes"
    static let whatsappDomain = "AppDomainGroup-group.net.whatsapp.WhatsApp.shared"

    func export(_ kinds: [BackupExport], to folder: URL, progress: @escaping (String) -> Void) throws -> [BackupExport: Int] {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var counts: [BackupExport: Int] = [:]
        for kind in kinds {
            progress(kind.title)
            switch kind {
            case .messages: counts[kind] = try exportMessages(to: folder, progress: progress)
            case .contacts: counts[kind] = try exportContacts(to: folder, progress: progress)
            case .calls: counts[kind] = try exportCalls(to: folder)
            case .notes: counts[kind] = try exportNotes(to: folder, progress: progress)
            case .voiceMemos: counts[kind] = try exportVoiceMemos(to: folder, progress: progress)
            case .safari: counts[kind] = try exportSafari(to: folder)
            case .whatsapp: counts[kind] = try exportWhatsApp(to: folder, progress: progress)
            }
        }
        return counts
    }

    // MARK: Formatting helpers

    static func sanitize(_ name: String) -> String {
        var s = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        s = String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0) })
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        if s.count > 80 { s = String(s.prefix(80)).trimmingCharacters(in: .whitespaces) }
        return s.isEmpty ? "Untitled" : s
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
    private static func fmt(_ d: Date?) -> String { d.map { dateFormatter.string(from: $0) } ?? "" }
    private static func appleDate(_ v: Double?) -> Date? {
        guard let v, v != 0 else { return nil }
        return Date(timeIntervalSinceReferenceDate: v > 1e12 ? v / 1e9 : v)
    }
    private static func csv(_ fields: [String]) -> String {
        fields.map { f in
            let needs = f.contains(",") || f.contains("\"") || f.contains("\n") || f.contains("\r")
            return needs ? "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : f
        }.joined(separator: ",") + "\n"
    }
    private static func html(_ s: String) -> String {
        var o = ""
        o.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "&": o += "&amp;"
            case "<": o += "&lt;"
            case ">": o += "&gt;"
            case "\"": o += "&quot;"
            case "\n": o += "<br>"
            default: o.append(c)
            }
        }
        return o
    }
    private static func urlPath(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }

    /// Picks a file name nobody in the folder has used yet.
    private struct Namer {
        var used: Set<String> = []
        mutating func unique(_ base: String, ext: String) -> String {
            var name = base, n = 2
            while used.contains((name + ext).lowercased()) { name = "\(base) (\(n))"; n += 1 }
            used.insert((name + ext).lowercased())
            return name + ext
        }
    }

    private struct ChatLine {
        var date: Date?
        var sender: String
        var text: String
        var attachments: [(name: String, href: String)] = []
    }

    private func writeChat(title: String, lines: [ChatLine], to base: URL) throws {
        var txt = title + "\n" + String(repeating: "=", count: min(title.count, 60)) + "\n\n"
        var html = """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>\(Self.html(title))</title>
        <style>
        body{font-family:-apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif;font-size:14px;line-height:1.4;margin:0;padding:24px;background:#f5f5f7;color:#1d1d1f}
        h1{font-size:20px;margin:0 0 16px}
        .m{display:grid;grid-template-columns:130px 140px 1fr;gap:12px;padding:8px 12px;margin:4px 0;border-radius:10px;background:#fff}
        .m.me{background:#dcefff}
        .t{color:#6e6e73;font-variant-numeric:tabular-nums;white-space:nowrap}
        .s{font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
        .x{overflow-wrap:anywhere}
        .a{display:block;margin-top:4px;font-size:13px}
        @media (max-width:640px){.m{grid-template-columns:1fr}}
        </style></head><body>
        <h1>\(Self.html(title))</h1>

        """
        for l in lines {
            let t = Self.fmt(l.date)
            txt += "[\(t)] \(l.sender): \(l.text)"
            for a in l.attachments { txt += "\n    [attachment: \(a.href)]" }
            txt += "\n"
            html += "<div class=\"m\(l.sender == "Me" ? " me" : "")\"><div class=\"t\">\(Self.html(t))</div><div class=\"s\">\(Self.html(l.sender))</div><div class=\"x\">\(Self.html(l.text))"
            for a in l.attachments { html += "<a class=\"a\" href=\"\(Self.urlPath(a.href))\">\(Self.html(a.name))</a>" }
            html += "</div></div>\n"
        }
        html += "</body></html>\n"
        try html.write(to: base.appendingPathExtension("html"), atomically: true, encoding: .utf8)
        try txt.write(to: base.appendingPathExtension("txt"), atomically: true, encoding: .utf8)
    }

    // MARK: Messages

    private func exportMessages(to folder: URL, progress: (String) -> Void) throws -> Int {
        guard let db = try database(domain: Self.homeDomain, path: "Library/SMS/sms.db") else { return 0 }
        let out = folder.appendingPathComponent("Messages", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let attachmentsDir = out.appendingPathComponent("Attachments", isDirectory: true)

        var handles: [Int: String] = [:]
        for r in try db.rows("SELECT ROWID, id FROM handle") { if let id = r.int("ROWID") { handles[id] = r.string("id") ?? "" } }
        let hasChatHandles = db.hasTable("chat_handle_join")
        let hasAttachments = db.hasTable("attachment") && db.hasTable("message_attachment_join")
        let hasAttributed = db.hasColumn("message", "attributedBody")
        let hasService = db.hasColumn("message", "service")

        let chats = try db.rows("SELECT ROWID, chat_identifier, display_name FROM chat ORDER BY ROWID")
        var namer = Namer()
        var total = 0
        var copiedAttachments: [Int: String] = [:]
        for (i, chat) in chats.enumerated() {
            guard let chatID = chat.int("ROWID") else { continue }
            var name = chat.string("display_name") ?? ""
            if name.isEmpty, hasChatHandles {
                let ids = try db.rows("SELECT h.id FROM chat_handle_join j JOIN handle h ON h.ROWID = j.handle_id WHERE j.chat_id = \(chatID) ORDER BY h.id").compactMap { $0.string("id") }
                if !ids.isEmpty { name = ids.joined(separator: ", ") }
            }
            if name.isEmpty { name = chat.string("chat_identifier") ?? "Chat \(chatID)" }
            progress("Messages: \(name) (\(i + 1) of \(chats.count))")
            let cols = "m.ROWID, m.text, m.handle_id, m.date, m.is_from_me" + (hasAttributed ? ", m.attributedBody" : "") + (hasService ? ", m.service" : "")
            let msgs = try db.rows("SELECT \(cols) FROM message m JOIN chat_message_join j ON j.message_id = m.ROWID WHERE j.chat_id = \(chatID) ORDER BY m.date")
            if msgs.isEmpty { continue }
            var lines: [ChatLine] = []
            for m in msgs {
                guard let mid = m.int("ROWID") else { continue }
                var text = m.string("text") ?? ""
                if text.isEmpty, let body = m.data("attributedBody") { text = Self.textFromAttributedBody(body) }
                let fromMe = (m.int("is_from_me") ?? 0) != 0
                let sender = fromMe ? "Me" : (handles[m.int("handle_id") ?? -1] ?? "Unknown")
                var line = ChatLine(date: Self.appleDate(m.double("date")), sender: sender, text: text)
                if hasAttachments {
                    for a in try db.rows("SELECT a.ROWID, a.filename, a.transfer_name FROM attachment a JOIN message_attachment_join j ON j.attachment_id = a.ROWID WHERE j.message_id = \(mid)") {
                        guard let aid = a.int("ROWID") else { continue }
                        let filename = a.string("filename") ?? ""
                        let display = a.string("transfer_name") ?? (filename as NSString).lastPathComponent
                        if copiedAttachments[aid] == nil, !filename.isEmpty {
                            var rel = filename
                            if rel.hasPrefix("~/") { rel.removeFirst(2) }
                            if let r = rel.range(of: "/Library/") , rel.hasPrefix("/") { rel = String(rel[rel.index(after: r.lowerBound)...]) }
                            let target = "\(aid)_\(Self.sanitize((filename as NSString).lastPathComponent))"
                            if let f = try fileUnlocked(domain: Self.mediaDomain, path: rel) ?? fileUnlocked(domain: Self.homeDomain, path: rel), !f.isDirectory {
                                try? extractUnlocked(f, to: attachmentsDir.appendingPathComponent(target))
                                copiedAttachments[aid] = "Attachments/" + target
                            } else {
                                copiedAttachments[aid] = ""
                            }
                        }
                        let href = copiedAttachments[aid] ?? ""
                        line.attachments.append((name: display.isEmpty ? "attachment" : display, href: href.isEmpty ? "(missing: \(display))" : href))
                    }
                }
                lines.append(line)
            }
            total += lines.count
            let file = namer.unique(Self.sanitize(name), ext: "")
            try writeChat(title: name, lines: lines, to: out.appendingPathComponent(file))
        }
        return total
    }

    /// Pulls the plain text out of a typedstream-archived NSAttributedString (what newer iOS stores
    /// when `text` is NULL): the first length-prefixed string after the NSString class marker.
    static func textFromAttributedBody(_ data: Data) -> String {
        let bytes = [UInt8](data)
        let needle = Array("NSString".utf8)
        guard bytes.count >= needle.count, let start = (0...(bytes.count - needle.count)).first(where: { bytes[$0..<($0 + needle.count)].elementsEqual(needle) }) else { return "" }
        var i = start + needle.count
        while i < bytes.count, bytes[i] != 0x2B { i += 1 }
        i += 1
        guard i < bytes.count else { return "" }
        var length = Int(bytes[i]); i += 1
        if length == 0x81 {
            guard i + 1 < bytes.count else { return "" }
            length = Int(bytes[i]) | Int(bytes[i + 1]) << 8; i += 2
        } else if length == 0x82 {
            guard i + 3 < bytes.count else { return "" }
            length = Int(bytes[i]) | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2]) << 16 | Int(bytes[i + 3]) << 24; i += 4
        }
        guard length > 0, i + length <= bytes.count else { return "" }
        return String(decoding: bytes[i..<(i + length)], as: UTF8.self)
    }

    // MARK: Contacts

    private func exportContacts(to folder: URL, progress: (String) -> Void) throws -> Int {
        guard let db = try database(domain: Self.homeDomain, path: "Library/AddressBook/AddressBook.sqlitedb") else { return 0 }
        var labels: [Int: String] = [:]
        if db.hasTable("ABMultiValueLabel") {
            for r in try db.rows("SELECT ROWID, value FROM ABMultiValueLabel") { if let id = r.int("ROWID") { labels[id] = Self.cleanLabel(r.string("value") ?? "") } }
        }
        var entryKeys: [Int: String] = [:]
        if db.hasTable("ABMultiValueEntryKey") {
            for r in try db.rows("SELECT ROWID, value FROM ABMultiValueEntryKey") { if let id = r.int("ROWID") { entryKeys[id] = r.string("value") ?? "" } }
        }
        struct MV { let label: String; let value: String; let uid: Int }
        var multi: [Int: [Int: [MV]]] = [:]     // record → property → values
        for r in try db.rows("SELECT UID, record_id, property, label, value FROM ABMultiValue ORDER BY UID") {
            guard let rec = r.int("record_id"), let prop = r.int("property") else { continue }
            let label = r.int("label").flatMap { labels[$0] } ?? ""
            multi[rec, default: [:]][prop, default: []].append(MV(label: label, value: r.string("value") ?? "", uid: r.int("UID") ?? 0))
        }
        var entries: [Int: [String: String]] = [:]
        if db.hasTable("ABMultiValueEntry") {
            for r in try db.rows("SELECT parent_id, key, value FROM ABMultiValueEntry") {
                guard let p = r.int("parent_id"), let k = r.int("key") else { continue }
                entries[p, default: [:]][entryKeys[k] ?? "\(k)"] = r.string("value") ?? ""
            }
        }
        var photos: [Int: Data] = [:]
        if let img = try database(domain: Self.homeDomain, path: "Library/AddressBook/AddressBookImages.sqlitedb") {
            for table in ["ABFullSizeImage", "ABThumbnailImage"] where img.hasTable(table) {
                for r in try img.rows("SELECT record_id, data FROM \(table) WHERE data IS NOT NULL") {
                    if let id = r.int("record_id"), photos[id] == nil, let d = r.data("data"), !d.isEmpty { photos[id] = d }
                }
            }
        }

        let optional = ["Middle", "Organization", "Note", "Birthday", "JobTitle", "Department", "Nickname", "Prefix", "Suffix"]
        let cols = ["ROWID", "First", "Last"] + optional.map { db.hasColumn("ABPerson", $0) ? $0 : "NULL AS \($0)" }
        let people = try db.rows("SELECT \(cols.joined(separator: ", ")) FROM ABPerson ORDER BY ROWID")
        var vcf = ""
        var csv = Self.csv(["Name", "Phones", "Emails", "Organization"])
        var count = 0
        for (i, p) in people.enumerated() {
            guard let id = p.int("ROWID") else { continue }
            let first = p.string("First") ?? "", last = p.string("Last") ?? "", middle = p.string("Middle") ?? ""
            let org = p.string("Organization") ?? ""
            let fullName = [p.string("Prefix"), first.isEmpty ? nil : first, middle.isEmpty ? nil : middle, last.isEmpty ? nil : last, p.string("Suffix")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            let display = fullName.isEmpty ? (org.isEmpty ? "Unnamed" : org) : fullName
            if i % 50 == 0 { progress("Contacts: \(i + 1) of \(people.count)") }
            let props = multi[id] ?? [:]
            var card = "BEGIN:VCARD\r\nVERSION:3.0\r\n"
            card += "FN:" + Self.vEscape(display) + "\r\n"
            card += "N:" + [last, first, middle, p.string("Prefix") ?? "", p.string("Suffix") ?? ""].map(Self.vEscape).joined(separator: ";") + "\r\n"
            if !org.isEmpty { card += "ORG:" + Self.vEscape(org) + (p.string("Department").map { ";" + Self.vEscape($0) } ?? "") + "\r\n" }
            if let t = p.string("JobTitle"), !t.isEmpty { card += "TITLE:" + Self.vEscape(t) + "\r\n" }
            if let n = p.string("Nickname"), !n.isEmpty { card += "NICKNAME:" + Self.vEscape(n) + "\r\n" }
            if let b = Self.appleDate(p.double("Birthday")) {
                let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
                card += "BDAY:" + f.string(from: b) + "\r\n"
            }
            var phones: [String] = [], emails: [String] = []
            for v in props[3] ?? [] where !v.value.isEmpty {
                phones.append(v.value)
                card += "TEL" + Self.vType(v.label) + ":" + Self.vEscape(v.value) + "\r\n"
            }
            for v in props[4] ?? [] where !v.value.isEmpty {
                emails.append(v.value)
                card += "EMAIL" + Self.vType(v.label) + ":" + Self.vEscape(v.value) + "\r\n"
            }
            for v in props[5] ?? [] {
                let e = entries[v.uid] ?? [:]
                let parts = ["", "", e["Street"] ?? "", e["City"] ?? "", e["State"] ?? "", e["ZIP"] ?? "", e["Country"] ?? ""]
                if parts.contains(where: { !$0.isEmpty }) { card += "ADR" + Self.vType(v.label) + ":" + parts.map(Self.vEscape).joined(separator: ";") + "\r\n" }
            }
            for v in props[22] ?? [] where !v.value.isEmpty { card += "URL" + Self.vType(v.label) + ":" + Self.vEscape(v.value) + "\r\n" }
            if let note = p.string("Note"), !note.isEmpty { card += "NOTE:" + Self.vEscape(note) + "\r\n" }
            if let photo = photos[id] {
                let kind = photo.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "PNG" : "JPEG"
                card += Self.fold("PHOTO;ENCODING=b;TYPE=\(kind):" + photo.base64EncodedString()) + "\r\n"
            }
            card += "END:VCARD\r\n"
            vcf += card
            csv += Self.csv([display, phones.joined(separator: "; "), emails.joined(separator: "; "), org])
            count += 1
        }
        try vcf.write(to: folder.appendingPathComponent("Contacts.vcf"), atomically: true, encoding: .utf8)
        try csv.write(to: folder.appendingPathComponent("Contacts.csv"), atomically: true, encoding: .utf8)
        return count
    }

    private static func cleanLabel(_ s: String) -> String {
        var l = s
        if l.hasPrefix("_$!<") { l.removeFirst(4) }
        if l.hasSuffix(">!$_") { l.removeLast(4) }
        return l
    }
    private static func vType(_ label: String) -> String {
        guard !label.isEmpty else { return "" }
        let known = ["Mobile": "CELL", "iPhone": "CELL", "Home": "HOME", "Work": "WORK", "Main": "PREF", "HomeFAX": "FAX,HOME", "WorkFAX": "FAX,WORK", "Pager": "PAGER", "Other": "OTHER", "HomePage": "HOME"]
        if let t = known[label] { return ";TYPE=" + t }
        let safe = label.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" }.map(String.init).joined()
        return safe.isEmpty ? "" : ";TYPE=" + safe.uppercased()
    }
    private static func vEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;").replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: "\r\n", with: "\\n").replacingOccurrences(of: "\n", with: "\\n")
    }
    /// vCard 3.0 line folding: 75 octets per line, continuation lines start with one space.
    private static func fold(_ line: String) -> String {
        var out = "", current = 0
        for c in line {
            let n = String(c).utf8.count
            if current + n > 75 { out += "\r\n "; current = 1 }
            out.append(c); current += n
        }
        return out
    }

    // MARK: Calls

    private func exportCalls(to folder: URL) throws -> Int {
        guard let db = try database(domain: Self.homeDomain, path: "Library/CallHistoryDB/CallHistory.storedata") else { return 0 }
        let want = ["ZADDRESS", "ZDATE", "ZDURATION", "ZORIGINATED", "ZANSWERED", "ZCALLTYPE", "ZNAME"]
        let cols = want.map { db.hasColumn("ZCALLRECORD", $0) ? $0 : "NULL AS \($0)" }
        var csv = Self.csv(["Date", "Number/Address", "Name", "Direction", "Type", "Duration"])
        var n = 0
        for r in try db.rows("SELECT \(cols.joined(separator: ", ")) FROM ZCALLRECORD ORDER BY ZDATE DESC") {
            let outgoing = (r.int("ZORIGINATED") ?? 0) != 0
            let answered = (r.int("ZANSWERED") ?? 1) != 0
            let direction = outgoing ? "Outgoing" : (answered ? "Incoming" : "Missed")
            let type: String
            switch r.int("ZCALLTYPE") ?? 1 {
            case 1: type = "Phone"
            case 8: type = "FaceTime video"
            case 16: type = "FaceTime audio"
            case let t: type = "Other (\(t))"
            }
            let secs = Int((r.double("ZDURATION") ?? 0).rounded())
            let duration = String(format: "%d:%02d", secs / 60, secs % 60)
            var address = r.string("ZADDRESS") ?? ""
            if address.isEmpty, let d = r.data("ZADDRESS") { address = String(decoding: d, as: UTF8.self) }
            csv += Self.csv([Self.fmt(Self.appleDate(r.double("ZDATE"))), address, r.string("ZNAME") ?? "", direction, type, duration])
            n += 1
        }
        try csv.write(to: folder.appendingPathComponent("Call history.csv"), atomically: true, encoding: .utf8)
        return n
    }

    // MARK: Notes

    private func exportNotes(to folder: URL, progress: (String) -> Void) throws -> Int {
        struct Note { let title: String; let text: String; let modified: Date? }
        var notes: [Note] = []
        if let db = try database(domain: Self.notesDomain, path: "NoteStore.sqlite") {
            let deletion = db.hasColumn("ZICCLOUDSYNCINGOBJECT", "ZMARKEDFORDELETION") ? " AND (o.ZMARKEDFORDELETION IS NULL OR o.ZMARKEDFORDELETION = 0)" : ""
            let title = db.hasColumn("ZICCLOUDSYNCINGOBJECT", "ZTITLE1") ? "o.ZTITLE1" : "NULL"
            let snippet = db.hasColumn("ZICCLOUDSYNCINGOBJECT", "ZSNIPPET") ? "o.ZSNIPPET" : "NULL"
            let mod = db.hasColumn("ZICCLOUDSYNCINGOBJECT", "ZMODIFICATIONDATE1") ? "o.ZMODIFICATIONDATE1" : "NULL"
            let rows = try db.rows("SELECT \(title) AS title, \(snippet) AS snippet, \(mod) AS modified, d.ZDATA AS data FROM ZICCLOUDSYNCINGOBJECT o JOIN ZICNOTEDATA d ON d.Z_PK = o.ZNOTEDATA WHERE o.ZNOTEDATA IS NOT NULL\(deletion) ORDER BY o.Z_PK")
            for (i, r) in rows.enumerated() {
                if i % 20 == 0 { progress("Notes: \(i + 1) of \(rows.count)") }
                var text = ""
                if let z = r.data("data"), let raw = Gzip.decompress(z) { text = Self.noteText(fromProtobuf: raw) ?? "" }
                if text.isEmpty { text = r.string("snippet") ?? "" }
                var title = r.string("title") ?? ""
                if title.isEmpty { title = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Untitled" }
                notes.append(Note(title: title, text: text, modified: Self.appleDate(r.double("modified"))))
            }
        } else if let db = try database(domain: Self.homeDomain, path: "Library/Notes/notes.sqlite") {
            let rows = try db.rows("SELECT n.ZTITLE AS title, n.ZMODIFICATIONDATE AS modified, b.ZCONTENT AS body FROM ZNOTE n LEFT JOIN ZNOTEBODY b ON b.Z_PK = n.ZBODY ORDER BY n.Z_PK")
            for r in rows {
                let text = Self.stripHTML(r.string("body") ?? "")
                var title = r.string("title") ?? ""
                if title.isEmpty { title = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Untitled" }
                notes.append(Note(title: title, text: text, modified: Self.appleDate(r.double("modified"))))
            }
        } else {
            return 0
        }
        let out = folder.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var namer = Namer()
        var index = Self.csv(["Title", "Modified", "File"])
        for n in notes {
            let name = namer.unique(Self.sanitize(n.title), ext: ".txt")
            let url = out.appendingPathComponent(name)
            try n.text.write(to: url, atomically: true, encoding: .utf8)
            if let m = n.modified { try? FileManager.default.setAttributes([.modificationDate: m], ofItemAtPath: url.path) }
            index += Self.csv([n.title, Self.fmt(n.modified), name])
        }
        try index.write(to: out.appendingPathComponent("index.csv"), atomically: true, encoding: .utf8)
        return notes.count
    }

    /// Notes' protobuf: outer field 2 → field 3 → field 2 is the note text.
    static func noteText(fromProtobuf data: Data) -> String? {
        guard let doc = Protobuf.fields(of: data), let note = doc.first(where: { $0.number == 2 && $0.lengthDelimited != nil })?.lengthDelimited,
              let inner = Protobuf.fields(of: note), let body = inner.first(where: { $0.number == 3 && $0.lengthDelimited != nil })?.lengthDelimited,
              let text = Protobuf.fields(of: body)?.first(where: { $0.number == 2 && $0.lengthDelimited != nil })?.lengthDelimited else { return nil }
        return String(data: text, encoding: .utf8)
    }

    static func stripHTML(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "<br[^>]*>", with: "\n", options: .regularExpression)
        t = t.replacingOccurrences(of: "</(p|div|li|h[1-6])>", with: "\n", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (e, c) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] { t = t.replacingOccurrences(of: e, with: c) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Voice memos

    private func voiceMemoFiles() throws -> [BackupFile] {
        let m = try db()
        return try m.rows("SELECT fileID, domain, relativePath, flags, file FROM Files WHERE domain = ? AND relativePath LIKE 'Recordings/%' AND LOWER(relativePath) LIKE '%.m4a' AND flags = 1 ORDER BY relativePath", [.text(Self.mediaDomain)]).map(makeFile)
    }

    private func exportVoiceMemos(to folder: URL, progress: (String) -> Void) throws -> Int {
        let files = try voiceMemoFiles()
        guard !files.isEmpty else { return 0 }
        struct Label { let title: String; let date: Date? }
        var labels: [String: Label] = [:]
        if let db = try database(domain: Self.mediaDomain, path: "Recordings/CloudRecordings.db"), db.hasTable("ZCLOUDRECORDING") {
            let cols = ["ZCUSTOMLABEL", "ZENCRYPTEDTITLE", "ZPATH", "ZDATE"].map { db.hasColumn("ZCLOUDRECORDING", $0) ? $0 : "NULL AS \($0)" }
            for r in try db.rows("SELECT \(cols.joined(separator: ", ")) FROM ZCLOUDRECORDING") {
                guard let path = r.string("ZPATH") else { continue }
                let title = [r.string("ZCUSTOMLABEL"), r.string("ZENCRYPTEDTITLE")].compactMap { $0 }.first { !$0.isEmpty }
                labels[(path as NSString).lastPathComponent] = Label(title: title ?? "", date: Self.appleDate(r.double("ZDATE")))
            }
        }
        let out = folder.appendingPathComponent("Voice Memos", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var namer = Namer()
        var n = 0
        for (i, f) in files.enumerated() {
            let fileName = (f.relativePath as NSString).lastPathComponent
            let label = labels[fileName]
            let base = (label?.title.isEmpty == false) ? label!.title : (fileName as NSString).deletingPathExtension
            progress("Voice memos: \(base) (\(i + 1) of \(files.count))")
            let name = namer.unique(Self.sanitize(base), ext: ".m4a")
            try extractUnlocked(f, to: out.appendingPathComponent(name), modified: label?.date)
            n += 1
        }
        return n
    }

    // MARK: Safari

    private func exportSafari(to folder: URL) throws -> Int {
        var visits = 0
        if let db = try database(domain: Self.homeDomain, path: "Library/Safari/History.db") {
            let titleCol = db.hasColumn("history_visits", "title") ? "v.title" : "NULL"
            var csv = Self.csv(["Date", "Title", "URL"])
            for r in try db.rows("SELECT v.visit_time AS t, \(titleCol) AS title, i.url AS url FROM history_visits v JOIN history_items i ON i.id = v.history_item ORDER BY v.visit_time DESC") {
                csv += Self.csv([Self.fmt(Self.appleDate(r.double("t"))), r.string("title") ?? "", r.string("url") ?? ""])
                visits += 1
            }
            try csv.write(to: folder.appendingPathComponent("Safari history.csv"), atomically: true, encoding: .utf8)
        }
        if let db = try database(domain: Self.homeDomain, path: "Library/Safari/Bookmarks.db"), db.hasTable("bookmarks") {
            struct Mark { let id: Int; let title: String; let url: String; let parent: Int; let folder: Bool }
            var byParent: [Int: [Mark]] = [:]
            var all: Set<Int> = []
            for r in try db.rows("SELECT id, title, url, parent, type FROM bookmarks ORDER BY \(db.hasColumn("bookmarks", "order_index") ? "order_index" : "id")") {
                guard let id = r.int("id") else { continue }
                let m = Mark(id: id, title: r.string("title") ?? "", url: r.string("url") ?? "", parent: r.int("parent") ?? 0, folder: (r.int("type") ?? 0) == 1)
                all.insert(id)
                byParent[m.parent, default: []].append(m)
            }
            var out = "<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<!-- This is an automatically generated file. -->\n<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">\n<TITLE>Bookmarks</TITLE>\n<H1>Bookmarks</H1>\n<DL><p>\n"
            func emit(_ parent: Int, depth: Int, seen: inout Set<Int>) {
                let pad = String(repeating: "    ", count: depth)
                for m in byParent[parent] ?? [] where !seen.contains(m.id) {
                    seen.insert(m.id)
                    if m.folder {
                        out += "\(pad)<DT><H3>\(Self.html(m.title.isEmpty ? "Folder" : m.title))</H3>\n\(pad)<DL><p>\n"
                        emit(m.id, depth: depth + 1, seen: &seen)
                        out += "\(pad)</DL><p>\n"
                    } else if !m.url.isEmpty {
                        out += "\(pad)<DT><A HREF=\"\(Self.html(m.url))\">\(Self.html(m.title.isEmpty ? m.url : m.title))</A>\n"
                    }
                }
            }
            var seen: Set<Int> = []
            // Roots: entries whose parent is not itself a bookmark row (Safari uses 0 for the root).
            let roots = byParent.keys.filter { !all.contains($0) }.sorted()
            for root in roots { emit(root, depth: 1, seen: &seen) }
            out += "</DL><p>\n"
            try out.write(to: folder.appendingPathComponent("Safari bookmarks.html"), atomically: true, encoding: .utf8)
        }
        return visits
    }

    // MARK: WhatsApp

    private func exportWhatsApp(to folder: URL, progress: (String) -> Void) throws -> Int {
        guard let db = try database(domain: Self.whatsappDomain, path: "ChatStorage.sqlite") else { return 0 }
        let out = folder.appendingPathComponent("WhatsApp", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let mediaDir = out.appendingPathComponent("Media", isDirectory: true)
        var media: [Int: (path: String, title: String)] = [:]
        if db.hasTable("ZWAMEDIAITEM") {
            let titleCol = db.hasColumn("ZWAMEDIAITEM", "ZTITLE") ? "ZTITLE" : "NULL AS ZTITLE"
            for r in try db.rows("SELECT Z_PK, ZMEDIALOCALPATH, \(titleCol) FROM ZWAMEDIAITEM WHERE ZMEDIALOCALPATH IS NOT NULL") {
                if let id = r.int("Z_PK") { media[id] = (r.string("ZMEDIALOCALPATH") ?? "", r.string("ZTITLE") ?? "") }
            }
        }
        let sessionCols = ["ZPARTNERNAME", "ZCONTACTJID"].map { db.hasColumn("ZWACHATSESSION", $0) ? $0 : "NULL AS \($0)" }
        let msgCols = ["ZTEXT", "ZMESSAGEDATE", "ZISFROMME", "ZFROMJID", "ZPUSHNAME", "ZMEDIAITEM", "ZMESSAGETYPE"].map { db.hasColumn("ZWAMESSAGE", $0) ? $0 : "NULL AS \($0)" }
        let sessions = try db.rows("SELECT Z_PK, \(sessionCols.joined(separator: ", ")) FROM ZWACHATSESSION ORDER BY Z_PK")
        var namer = Namer()
        var copied: [Int: String] = [:]
        var total = 0
        for (i, s) in sessions.enumerated() {
            guard let sid = s.int("Z_PK") else { continue }
            let jid = s.string("ZCONTACTJID") ?? ""
            let partner = (s.string("ZPARTNERNAME")?.isEmpty == false) ? s.string("ZPARTNERNAME")! : (jid.split(separator: "@").first.map(String.init) ?? "Chat \(sid)")
            progress("WhatsApp: \(partner) (\(i + 1) of \(sessions.count))")
            let msgs = try db.rows("SELECT Z_PK, \(msgCols.joined(separator: ", ")) FROM ZWAMESSAGE WHERE ZCHATSESSION = \(sid) ORDER BY ZMESSAGEDATE, Z_PK")
            if msgs.isEmpty { continue }
            var lines: [ChatLine] = []
            for m in msgs {
                let fromMe = (m.int("ZISFROMME") ?? 0) != 0
                var sender = "Me"
                if !fromMe {
                    sender = m.string("ZPUSHNAME") ?? ""
                    if sender.isEmpty { sender = m.string("ZFROMJID")?.split(separator: "@").first.map(String.init) ?? partner }
                }
                var line = ChatLine(date: Self.appleDate(m.double("ZMESSAGEDATE")), sender: sender, text: m.string("ZTEXT") ?? "")
                if let mid = m.int("ZMEDIAITEM"), let item = media[mid], !item.path.isEmpty {
                    if copied[mid] == nil {
                        var href = ""
                        for candidate in ["Message/" + item.path, item.path] {
                            if let f = try fileUnlocked(domain: Self.whatsappDomain, path: candidate), !f.isDirectory {
                                let target = "\(mid)_\(Self.sanitize((item.path as NSString).lastPathComponent))"
                                try? extractUnlocked(f, to: mediaDir.appendingPathComponent(target))
                                href = "Media/" + target
                                break
                            }
                        }
                        copied[mid] = href
                    }
                    let href = copied[mid] ?? ""
                    let name = item.title.isEmpty ? (item.path as NSString).lastPathComponent : item.title
                    line.attachments.append((name: name, href: href.isEmpty ? "(missing: \(name))" : href))
                    if line.text.isEmpty && (m.int("ZMESSAGETYPE") ?? 0) != 0 { line.text = "[media]" }
                }
                lines.append(line)
            }
            total += lines.count
            let file = namer.unique(Self.sanitize(partner), ext: "")
            try writeChat(title: partner, lines: lines, to: out.appendingPathComponent(file))
        }
        return total
    }
}

// MARK: - Keybag

private struct Keybag {
    struct ClassKey { var uuid = Data(); var clas: UInt32 = 0; var wrap: UInt32 = 0; var ktyp: UInt32 = 0; var wpky = Data() }
    var header: [String: Data] = [:]
    var classes: [ClassKey] = []

    init(data: Data) throws {
        var i = 0
        var current: ClassKey?
        let bytes = [UInt8](data)
        while i + 8 <= bytes.count {
            let tag = String(decoding: bytes[i..<(i + 4)], as: UTF8.self)
            let len = Int(bytes[i + 4]) << 24 | Int(bytes[i + 5]) << 16 | Int(bytes[i + 6]) << 8 | Int(bytes[i + 7])
            i += 8
            guard i + len <= bytes.count else { throw BackupError("Corrupt keybag") }
            let value = Data(bytes[i..<(i + len)])
            i += len
            if tag == "UUID" {
                if let c = current { classes.append(c) }
                // The first UUID belongs to the header; every later one starts a class record.
                if header["UUID"] == nil { header["UUID"] = value; current = nil } else { current = ClassKey(uuid: value) }
                continue
            }
            if var c = current {
                switch tag {
                case "CLAS": c.clas = value.readUInt32BE(at: 0)
                case "WRAP": c.wrap = value.readUInt32BE(at: 0)
                case "KTYP": c.ktyp = value.readUInt32BE(at: 0)
                case "WPKY": c.wpky = value
                default: break
                }
                current = c
            } else {
                header[tag] = value
            }
        }
        if let c = current { classes.append(c) }
        classes = classes.filter { !$0.wpky.isEmpty }
    }

    func passwordKey(password: String) throws -> Data {
        guard let salt = header["SALT"], let iterData = header["ITER"], iterData.count >= 4 else { throw BackupError("Keybag has no salt") }
        let iter = iterData.readUInt32BE(at: 0)
        let pw = Data(password.utf8)
        if let dpsl = header["DPSL"], let dpic = header["DPIC"], dpic.count >= 4 {
            let k1 = try BackupCrypto.pbkdf2(password: pw, salt: dpsl, iterations: dpic.readUInt32BE(at: 0), sha256: true, length: 32)
            return try BackupCrypto.pbkdf2(password: k1, salt: salt, iterations: iter, sha256: false, length: 32)
        }
        return try BackupCrypto.pbkdf2(password: pw, salt: salt, iterations: iter, sha256: false, length: 32)
    }
}

// MARK: - Crypto primitives (CommonCrypto)

enum BackupCrypto {
    static func pbkdf2(password: Data, salt: Data, iterations: UInt32, sha256: Bool, length: Int) throws -> Data {
        var out = Data(count: length)
        let status = out.withUnsafeMutableBytes { outPtr -> Int32 in
            password.withUnsafeBytes { pwPtr -> Int32 in
                salt.withUnsafeBytes { saltPtr -> Int32 in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         pwPtr.bindMemory(to: Int8.self).baseAddress, password.count,
                                         saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                         CCPseudoRandomAlgorithm(sha256 ? kCCPRFHmacAlgSHA256 : kCCPRFHmacAlgSHA1),
                                         iterations,
                                         outPtr.bindMemory(to: UInt8.self).baseAddress, length)
                }
            }
        }
        guard status == kCCSuccess else { throw BackupError("Key derivation failed (\(status))") }
        return out
    }

    /// AES key unwrap, RFC 3394. nil when the integrity check fails (wrong KEK).
    static func unwrap(kek: Data, wrapped: Data) -> Data? {
        guard wrapped.count >= 16, wrapped.count % 8 == 0, [16, 24, 32].contains(kek.count) else { return nil }
        var outLen = CCSymmetricUnwrappedSize(CCWrappingAlgorithm(kCCWRAPAES), wrapped.count)
        var out = Data(count: outLen)
        let status = out.withUnsafeMutableBytes { outPtr -> Int32 in
            kek.withUnsafeBytes { kekPtr -> Int32 in
                wrapped.withUnsafeBytes { wPtr -> Int32 in
                    CCSymmetricKeyUnwrap(CCWrappingAlgorithm(kCCWRAPAES), CCrfc3394_iv, CCrfc3394_ivLen,
                                         kekPtr.bindMemory(to: UInt8.self).baseAddress, kek.count,
                                         wPtr.bindMemory(to: UInt8.self).baseAddress, wrapped.count,
                                         outPtr.bindMemory(to: UInt8.self).baseAddress, &outLen)
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return out.prefix(outLen)
    }

    /// AES-256-CBC with a zero IV. With `padding` the PKCS7 padding is checked and removed.
    static func aesCBCDecrypt(key: Data, data: Data, padding: Bool) -> Data? {
        guard [16, 24, 32].contains(key.count), !data.isEmpty else { return nil }
        if !padding && data.count % 16 != 0 { return nil }
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let status = out.withUnsafeMutableBytes { outPtr -> Int32 in
            key.withUnsafeBytes { keyPtr -> Int32 in
                data.withUnsafeBytes { inPtr -> Int32 in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(padding ? kCCOptionPKCS7Padding : 0),
                            keyPtr.baseAddress, key.count, nil,
                            inPtr.baseAddress, data.count,
                            outPtr.baseAddress, data.count + kCCBlockSizeAES128, &moved)
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return out.prefix(moved)
    }
}

// MARK: - Binary property lists and NSKeyedArchiver

/// A small bplist00 reader: Foundation hands keyed-archive UIDs back as opaque CF objects, so the
/// manifest's per-file records are read with this instead.
enum BPlist {
    struct UID: Hashable { let value: Int }

    static func parse(_ data: Data) -> Any? {
        let b = [UInt8](data)
        guard b.count > 40, b[0..<6].elementsEqual("bplist".utf8) else { return nil }
        let t = b.count - 32
        let offsetSize = Int(b[t + 6]), refSize = Int(b[t + 7])
        let numObjects = Int(readBE(b, t + 8, 8)), top = Int(readBE(b, t + 16, 8)), tableOffset = Int(readBE(b, t + 24, 8))
        guard offsetSize > 0, refSize > 0, numObjects > 0, tableOffset + numObjects * offsetSize <= b.count, top < numObjects else { return nil }
        var offsets: [Int] = []
        offsets.reserveCapacity(numObjects)
        for i in 0..<numObjects { offsets.append(Int(readBE(b, tableOffset + i * offsetSize, offsetSize))) }
        var p = Parser(b: b, offsets: offsets, refSize: refSize)
        return p.object(top, depth: 0)
    }

    private static func readBE(_ b: [UInt8], _ at: Int, _ n: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<n where at + i < b.count { v = v << 8 | UInt64(b[at + i]) }
        return v
    }

    private struct Parser {
        let b: [UInt8]; let offsets: [Int]; let refSize: Int

        mutating func object(_ index: Int, depth: Int) -> Any? {
            guard depth < 64, index < offsets.count else { return nil }
            var pos = offsets[index]
            guard pos < b.count else { return nil }
            let marker = b[pos]; pos += 1
            let type = marker >> 4, low = Int(marker & 0x0F)
            func count() -> Int? {
                if low != 0x0F { return low }
                guard pos < b.count, b[pos] >> 4 == 1 else { return nil }
                let n = 1 << Int(b[pos] & 0x0F); pos += 1
                guard pos + n <= b.count else { return nil }
                let v = Int(readBE(b, pos, n)); pos += n
                return v
            }
            switch type {
            case 0x0:
                switch marker { case 0x08: return false; case 0x09: return true; default: return NSNull() }
            case 0x1:
                let n = 1 << low
                guard pos + n <= b.count else { return nil }
                if n <= 8 { return Int(Int64(bitPattern: readBE(b, pos, n) << UInt64(64 - 8 * n)) >> Int64(64 - 8 * n)) }
                return Int(Int64(bitPattern: readBE(b, pos + n - 8, 8)))
            case 0x2:
                let n = 1 << low
                guard pos + n <= b.count else { return nil }
                if n == 4 { return Double(Float(bitPattern: UInt32(readBE(b, pos, 4)))) }
                if n == 8 { return Double(bitPattern: readBE(b, pos, 8)) }
                return nil
            case 0x3:
                guard pos + 8 <= b.count else { return nil }
                return Date(timeIntervalSinceReferenceDate: Double(bitPattern: readBE(b, pos, 8)))
            case 0x4:
                guard let n = count(), pos + n <= b.count else { return nil }
                return Data(b[pos..<(pos + n)])
            case 0x5:
                guard let n = count(), pos + n <= b.count else { return nil }
                return String(decoding: b[pos..<(pos + n)], as: UTF8.self)
            case 0x6:
                guard let n = count(), pos + 2 * n <= b.count else { return nil }
                var units: [UInt16] = []
                units.reserveCapacity(n)
                for i in 0..<n { units.append(UInt16(b[pos + 2 * i]) << 8 | UInt16(b[pos + 2 * i + 1])) }
                return String(decoding: units, as: UTF16.self)
            case 0x8:
                let n = low + 1
                guard pos + n <= b.count else { return nil }
                return UID(value: Int(readBE(b, pos, n)))
            case 0xA, 0xC:
                guard let n = count(), pos + n * refSize <= b.count else { return nil }
                var arr: [Any] = []
                for i in 0..<n { arr.append(object(Int(readBE(b, pos + i * refSize, refSize)), depth: depth + 1) ?? NSNull()) }
                return arr
            case 0xD:
                guard let n = count(), pos + 2 * n * refSize <= b.count else { return nil }
                var dict: [String: Any] = [:]
                for i in 0..<n {
                    let k = object(Int(readBE(b, pos + i * refSize, refSize)), depth: depth + 1)
                    let v = object(Int(readBE(b, pos + (n + i) * refSize, refSize)), depth: depth + 1)
                    if let k = k as? String { dict[k] = v ?? NSNull() }
                }
                return dict
            default:
                return nil
            }
        }
    }
}

enum KeyedArchive {
    /// The `$top.root` object of an NSKeyedArchiver plist, with UIDs one level down resolved.
    static func root(of data: Data) -> [String: Any]? {
        guard let plist = BPlist.parse(data) as? [String: Any],
              let objects = plist["$objects"] as? [Any],
              let top = plist["$top"] as? [String: Any],
              let rootUID = top["root"] as? BPlist.UID, rootUID.value < objects.count,
              let root = objects[rootUID.value] as? [String: Any] else { return nil }
        var out: [String: Any] = [:]
        for (k, v) in root {
            if let uid = v as? BPlist.UID, uid.value < objects.count { out[k] = objects[uid.value] } else { out[k] = v }
        }
        return out
    }
}

// MARK: - gzip and protobuf

enum Gzip {
    static func decompress(_ data: Data) -> Data? {
        let b = [UInt8](data)
        guard b.count > 18, b[0] == 0x1F, b[1] == 0x8B, b[2] == 8 else { return inflate(data) }
        let flags = b[3]
        var pos = 10
        if flags & 0x04 != 0 { guard pos + 2 <= b.count else { return nil }; let xlen = Int(b[pos]) | Int(b[pos + 1]) << 8; pos += 2 + xlen }
        if flags & 0x08 != 0 { while pos < b.count, b[pos] != 0 { pos += 1 }; pos += 1 }
        if flags & 0x10 != 0 { while pos < b.count, b[pos] != 0 { pos += 1 }; pos += 1 }
        if flags & 0x02 != 0 { pos += 2 }
        guard pos < b.count - 8 else { return nil }
        return inflate(data.subdata(in: pos..<(b.count - 8)))
    }

    /// Raw deflate.
    static func inflate(_ input: Data) -> Data? {
        guard !input.isEmpty else { return Data() }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(stream) }
        let bufSize = 64 * 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { dst.deallocate() }
        var out = Data()
        let ok: Bool = input.withUnsafeBytes { src in
            stream.pointee.src_ptr = src.bindMemory(to: UInt8.self).baseAddress!
            stream.pointee.src_size = input.count
            while true {
                stream.pointee.dst_ptr = dst
                stream.pointee.dst_size = bufSize
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                out.append(dst, count: bufSize - stream.pointee.dst_size)
                switch status {
                case COMPRESSION_STATUS_OK: continue
                case COMPRESSION_STATUS_END: return true
                default: return false
                }
            }
        }
        return ok ? out : nil
    }
}

enum Protobuf {
    struct Field { let number: Int; let varint: UInt64?; let lengthDelimited: Data? }

    static func fields(of data: Data) -> [Field]? {
        let b = [UInt8](data)
        var pos = 0
        var out: [Field] = []
        func varint() -> UInt64? {
            var v: UInt64 = 0, shift: UInt64 = 0
            while pos < b.count {
                let byte = b[pos]; pos += 1
                v |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return v }
                shift += 7
                if shift > 63 { return nil }
            }
            return nil
        }
        while pos < b.count {
            guard let key = varint() else { return nil }
            let number = Int(key >> 3), wire = key & 7
            switch wire {
            case 0: guard let v = varint() else { return nil }; out.append(Field(number: number, varint: v, lengthDelimited: nil))
            case 1: guard pos + 8 <= b.count else { return nil }; pos += 8; out.append(Field(number: number, varint: nil, lengthDelimited: nil))
            case 2:
                guard let len = varint(), pos + Int(len) <= b.count else { return nil }
                out.append(Field(number: number, varint: nil, lengthDelimited: Data(b[pos..<(pos + Int(len))])))
                pos += Int(len)
            case 5: guard pos + 4 <= b.count else { return nil }; pos += 4; out.append(Field(number: number, varint: nil, lengthDelimited: nil))
            default: return nil
            }
        }
        return out
    }
}

// MARK: - SQLite

enum SQLValue {
    case null, int(Int64), real(Double), text(String), blob(Data)
}

struct SQLRow {
    let values: [String: SQLValue]
    func int(_ c: String) -> Int? {
        switch values[c] { case .int(let v)?: return Int(v); case .real(let v)?: return Int(v); case .text(let s)?: return Int(s); default: return nil }
    }
    func double(_ c: String) -> Double? {
        switch values[c] { case .int(let v)?: return Double(v); case .real(let v)?: return v; case .text(let s)?: return Double(s); default: return nil }
    }
    func string(_ c: String) -> String? {
        switch values[c] { case .text(let s)?: return s; case .int(let v)?: return String(v); case .real(let v)?: return String(v); default: return nil }
    }
    func data(_ c: String) -> Data? {
        switch values[c] { case .blob(let d)?: return d; case .text(let s)?: return Data(s.utf8); default: return nil }
    }
}

final class SQLiteDB {
    private var db: OpaquePointer?

    init(path: String, immutable: Bool) throws {
        var flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        var target = path
        if immutable {
            flags |= SQLITE_OPEN_URI
            let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            target = "file:" + escaped + "?immutable=1"
        }
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(target, &handle, flags, nil)
        guard rc == SQLITE_OK, let h = handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "error \(rc)"
            if let handle { sqlite3_close_v2(handle) }
            throw BackupError("Could not open \((path as NSString).lastPathComponent): \(msg)")
        }
        db = h
    }

    deinit { if let db { sqlite3_close_v2(db) } }

    func rows(_ sql: String, _ binds: [SQLValue] = []) throws -> [SQLRow] {
        guard let db else { throw BackupError("Database closed") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw BackupError("SQL error: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, v) in binds.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case .null: sqlite3_bind_null(stmt, idx)
            case .int(let n): sqlite3_bind_int64(stmt, idx, n)
            case .real(let d): sqlite3_bind_double(stmt, idx, d)
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, transient)
            case .blob(let d): _ = d.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(d.count), transient) }
            }
        }
        let n = Int(sqlite3_column_count(stmt))
        let names = (0..<n).map { String(cString: sqlite3_column_name(stmt, Int32($0))) }
        var out: [SQLRow] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw BackupError("SQL error: \(String(cString: sqlite3_errmsg(db)))") }
            var values: [String: SQLValue] = [:]
            for i in 0..<n {
                let c = Int32(i)
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: values[names[i]] = .int(sqlite3_column_int64(stmt, c))
                case SQLITE_FLOAT: values[names[i]] = .real(sqlite3_column_double(stmt, c))
                case SQLITE_TEXT: values[names[i]] = .text(String(cString: sqlite3_column_text(stmt, c)))
                case SQLITE_BLOB:
                    let len = Int(sqlite3_column_bytes(stmt, c))
                    if let p = sqlite3_column_blob(stmt, c), len > 0 { values[names[i]] = .blob(Data(bytes: p, count: len)) } else { values[names[i]] = .blob(Data()) }
                default: values[names[i]] = .null
                }
            }
            out.append(SQLRow(values: values))
        }
        return out
    }

    func scalar(_ sql: String) -> Int {
        guard let row = try? rows(sql).first, let v = row.values.values.first else { return 0 }
        if case .int(let n) = v { return Int(n) }
        return 0
    }

    func count(_ table: String) -> Int {
        guard hasTable(table) else { return 0 }
        return scalar("SELECT COUNT(*) FROM \"\(table)\"")
    }

    func hasTable(_ name: String) -> Bool {
        (try? rows("SELECT 1 FROM sqlite_master WHERE type IN ('table','view') AND name = ?", [.text(name)]))?.isEmpty == false
    }

    func hasColumn(_ table: String, _ column: String) -> Bool {
        guard let cols = try? rows("PRAGMA table_info(\"\(table)\")") else { return false }
        return cols.contains { $0.string("name")?.caseInsensitiveCompare(column) == .orderedSame }
    }
}

// MARK: - Data helpers

private extension Data {
    func readUInt32LE(at offset: Int) -> UInt32 {
        guard count >= offset + 4 else { return 0 }
        let s = startIndex + offset
        return UInt32(self[s]) | UInt32(self[s + 1]) << 8 | UInt32(self[s + 2]) << 16 | UInt32(self[s + 3]) << 24
    }
    func readUInt32BE(at offset: Int) -> UInt32 {
        guard count >= offset + 4 else { return 0 }
        let s = startIndex + offset
        return UInt32(self[s]) << 24 | UInt32(self[s + 1]) << 16 | UInt32(self[s + 2]) << 8 | UInt32(self[s + 3])
    }
}
