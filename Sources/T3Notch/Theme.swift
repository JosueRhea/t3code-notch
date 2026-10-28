import AppKit

/// T3 Code's color themes, as the notch wears them. The notch is always dark, so these are the
/// *dark* variants of T3's palettes (apps/web themePalette: accent, accentForeground, surfaceRaised,
/// canvas). Where a camera notch is, the shape stays black: nothing can recolor the hardware.
struct NotchTheme: Equatable {
    let id: String
    let label: String
    /// Primary buttons, Send, the glow under the open notch.
    let accent: NSColor
    /// Text on top of `accent`.
    let onAccent: NSColor
    /// Working / Connecting: the dots, activity line, running command, busy count. T3 keeps these
    /// sky blue in every theme; here they take the accent (a shade light enough for text on dark).
    /// The other statuses keep T3's colors so "needs you" still stands out.
    let working: NSColor
    /// T3's raised surface, tinting cards and secondary buttons. nil: plain translucent white.
    let surface: NSColor?
    /// T3's canvas, behind everything. nil: black.
    let background: NSColor?

    private static func hex(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    /// The notch's original look; also T3's default (no palette picked).
    static let classic = NotchTheme(id: "classic", label: "Classic",
                                    accent: NSColor(red: 1.0, green: 0.78, blue: 0.45, alpha: 1), onAccent: .black,
                                    working: NSColor(red: 0.49, green: 0.83, blue: 0.99, alpha: 1), // T3's sky
                                    surface: nil, background: nil)
    /// T3's built-in palettes, in T3's order.
    static let t3: [NotchTheme] = [
        .init(id: "t3-chat", label: "T3 Chat", accent: hex(0xA3004C), onAccent: hex(0xFBD0E8),
              working: hex(0xF391BC), surface: hex(0x2C2631), background: hex(0x1F1A24)),
        .init(id: "grove", label: "Grove", accent: hex(0x69D69A), onAccent: hex(0x241523),
              working: hex(0x69D69A), surface: hex(0x36413C), background: hex(0x1B2821)),
        .init(id: "ocean", label: "Ocean", accent: hex(0x70B9EE), onAccent: hex(0x241523),
              working: hex(0x70B9EE), surface: hex(0x333B45), background: hex(0x17212B)),
        .init(id: "ember", label: "Ember", accent: hex(0xF09A64), onAccent: hex(0x241523),
              working: hex(0xF09A64), surface: hex(0x433835), background: hex(0x291E1A)),
        .init(id: "iris", label: "Iris", accent: hex(0x9D7DF2), onAccent: hex(0x241523),
              working: hex(0xA98BF5), surface: hex(0x383443), background: hex(0x1D1929)),
    ]

    static func named(_ id: String?) -> NotchTheme? {
        guard let id else { return nil }
        return id == classic.id ? classic : t3.first { $0.id == id }
    }

    /// A background as bright on black as white at `alpha` (what the classic look uses),
    /// but in the theme's hue.
    func fill(_ alpha: CGFloat) -> NSColor {
        guard let s = surface?.usingColorSpace(.sRGB) else { return NSColor.white.withAlphaComponent(alpha) }
        let level = (s.redComponent + s.greenComponent + s.blueComponent) / 3
        return s.withAlphaComponent(min(1, alpha / max(level, 0.01)))
    }

    /// Shadow under the open notch: black for classic, a soft accent glow otherwise.
    var glowColor: CGColor { surface == nil ? NSColor.black.cgColor : accent.cgColor }
    var glowOpacity: Float { surface == nil ? 0.45 : 0.32 }
}

/// Which theme the notch wears: follow T3 Code, or a fixed pick from the menu.
enum ThemeChoice: Equatable {
    case matchT3
    case fixed(String)

    private static let key = "theme"
    static var saved: ThemeChoice {
        get {
            guard let raw = UserDefaults.standard.string(forKey: key), raw != "auto",
                  NotchTheme.named(raw) != nil else { return .matchT3 }
            return .fixed(raw)
        }
        set {
            switch newValue {
            case .matchT3: UserDefaults.standard.set("auto", forKey: key)
            case .fixed(let id): UserDefaults.standard.set(id, forKey: key)
            }
        }
    }
}

@MainActor
enum Theme {
    /// What every view paints with. Changing it posts `didChange` (panels rebuild).
    /// Only written on the main thread; readable from status colors, which aren't main-actor.
    nonisolated(unsafe) private(set) static var current = NotchTheme.classic
    /// T3 Code's palette, as last read from its storage.
    private(set) static var detected = NotchTheme.classic
    static let didChange = Notification.Name("T3NotchThemeDidChange")

    private static var timer: Timer?
    private static var lastStamp: T3ThemeReader.Stamp?
    private static let queue = DispatchQueue(label: "t3notch.theme", qos: .utility)

    /// Reads T3's theme once (so the first panels already match), then watches for changes.
    static func start() {
        let first = T3ThemeReader.read(since: nil, systemDark: systemDark)
        lastStamp = first.stamp
        if let id = first.id { detected = NotchTheme.named(id) ?? .classic }
        current = resolve()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated { poll() }
        }
        timer?.tolerance = 1
    }

    static func choose(_ choice: ThemeChoice) {
        ThemeChoice.saved = choice
        apply()
    }

    private static func poll() {
        guard ThemeChoice.saved == .matchT3 else { return }
        let since = lastStamp, dark = systemDark
        queue.async {
            // id nil: storage unchanged since the last read (or unreadable): keep what we have.
            let (id, stamp) = T3ThemeReader.read(since: since, systemDark: dark)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    lastStamp = stamp
                    guard let id else { return }
                    detected = NotchTheme.named(id) ?? .classic
                    apply()
                }
            }
        }
    }

    /// T3 set to follow macOS picks its light or dark palette half from this.
    private static var systemDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private static func resolve() -> NotchTheme {
        switch ThemeChoice.saved {
        case .matchT3: detected
        case .fixed(let id): NotchTheme.named(id) ?? detected
        }
    }

    private static func apply() {
        let next = resolve()
        guard next != current else { return }
        current = next
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}

/// T3 Code keeps its theme only in the web view's localStorage, a Chromium LevelDB under
/// Application Support. This reads it without opening the database (T3 holds the lock):
/// newest value wins across the write-ahead log and the sorted tables.
enum T3ThemeReader {
    static let themeKey = "t3code:theme"
    static let halvesKey = "t3code:theme-halves:v1"
    static let appearanceKey = "t3code:theme-appearance-mode"

    /// When storage was last read, and under which macOS appearance.
    struct Stamp: Equatable { let modified: Date; let systemDark: Bool }

    /// T3's palette id as the T3 window shows it now ("ember"; "system" etc. for no palette),
    /// "" when T3 never stored one, nil when nothing changed since `since` or it can't be read.
    static func read(since: Stamp?, systemDark: Bool) -> (id: String?, stamp: Stamp?) {
        guard let (dir, modified) = storageDirectory() else { return (nil, since) }
        let stamp = Stamp(modified: modified, systemDark: systemDark)
        if let since, since == stamp { return (nil, since) }
        let values = LevelDB.newest(in: dir, matching: [themeKey, halvesKey, appearanceKey].map(localStorageKeySuffix))
        func value(_ key: String) -> String? { values[localStorageKeySuffix(key)].flatMap(decodeValue) }
        let id = paletteId(theme: value(themeKey), halves: value(halvesKey), appearance: value(appearanceKey),
                           systemDark: systemDark)
        return (id, stamp)
    }

    /// T3 can pin a different palette for light and dark mode ("halves"); use the one on screen.
    static func paletteId(theme: String?, halves: String?, appearance: String?, systemDark: Bool) -> String {
        let dark = appearance == "dark" || (appearance != "light" && systemDark)
        if let data = halves?.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let half = obj[dark ? "dark" : "light"] as? String {
            return half
        }
        return theme ?? ""
    }

    /// Chromium's localStorage keys: "_" + origin + "\0" + 0x01 + latin-1 key.
    static func localStorageKeySuffix(_ key: String) -> Data {
        Data([0, 1]) + Data(key.utf8)
    }

    /// Values: 0x01 + latin-1, or 0x00 + UTF-16LE.
    static func decodeValue(_ d: Data) -> String? {
        guard let first = d.first else { return nil }
        let body = d.dropFirst()
        switch first {
        case 1: return String(data: body, encoding: .isoLatin1)
        case 0: return String(data: body, encoding: .utf16LittleEndian)
        default: return nil
        }
    }

    /// The T3 profile written most recently (the app has moved profiles between versions).
    private static func storageDirectory() -> (URL, Date)? {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return ["t3code-v2", "t3code"].compactMap { name -> (URL, Date)? in
            let dir = support.appendingPathComponent(name).appendingPathComponent("Local Storage/leveldb")
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
            let newest = files.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
            return newest.map { (dir, $0) }
        }.max { $0.1 < $1.1 }
    }
}

/// Just enough LevelDB to read a few keys: table files (.ldb, Snappy blocks) and the log (.log).
enum LevelDB {
    /// Newest live value of any user key ending in each of `suffixes`, keyed by suffix
    /// (localStorage keys are prefixed with an origin; T3 has used more than one).
    static func newest(in dir: URL, matching suffixes: [Data]) -> [Data: Data] {
        var best: [Data: (seq: UInt64, value: Data?)] = [:]
        func visit(_ key: Data, _ seq: UInt64, _ value: Data?) {
            guard let suffix = suffixes.first(where: { key.hasSuffix($0) }), seq >= best[suffix]?.seq ?? 0 else { return }
            best[suffix] = (seq, value)
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for url in files {
            guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { continue }
            switch url.pathExtension {
            case "ldb": readTable(data, visit)
            case "log": readLog(data, visit)
            default: break
            }
        }
        return best.compactMapValues(\.value)
    }

    // MARK: Log: 32 KiB blocks of fragmented records, each record a WriteBatch.

    static func readLog(_ data: Data, _ visit: (Data, UInt64, Data?) -> Void) {
        let bytes = [UInt8](data)
        var record: [UInt8] = []
        var block = 0
        while block < bytes.count {
            var p = block
            let end = min(block + 32768, bytes.count)
            while p + 7 <= end {
                let len = Int(bytes[p + 4]) | Int(bytes[p + 5]) << 8
                let type = bytes[p + 6]
                guard type != 0, p + 7 + len <= end else { break } // zero padding / torn write
                let fragment = bytes[(p + 7)..<(p + 7 + len)]
                switch type {
                case 1: readBatch(Array(fragment), visit); record = []
                case 2: record = Array(fragment)
                case 3: record += fragment
                case 4: record += fragment; readBatch(record, visit); record = []
                default: break
                }
                p += 7 + len
            }
            block += 32768
        }
    }

    private static func readBatch(_ b: [UInt8], _ visit: (Data, UInt64, Data?) -> Void) {
        guard b.count >= 12 else { return }
        var seq = b[0..<8].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        var r = Reader(bytes: b, at: 12)
        while r.p < b.count {
            let tag = b[r.p]; r.p += 1
            guard let key = r.slice() else { return }
            if tag == 1 {
                guard let value = r.slice() else { return }
                visit(Data(key), seq, Data(value))
            } else if tag == 0 {
                visit(Data(key), seq, nil)
            } else { return }
            seq += 1
        }
    }

    // MARK: Tables: footer → index block → data blocks; keys carry an 8-byte (seq << 8 | type) tag.

    static func readTable(_ data: Data, _ visit: (Data, UInt64, Data?) -> Void) {
        let bytes = [UInt8](data)
        guard bytes.count >= 48 else { return }
        var footer = Reader(bytes: bytes, at: bytes.count - 48)
        guard footer.varint() != nil, footer.varint() != nil, // metaindex handle
              let indexOffset = footer.varint(), let indexSize = footer.varint(),
              let index = block(bytes, Int(indexOffset), Int(indexSize)) else { return }
        for (_, handle) in entries(index) {
            var h = Reader(bytes: handle, at: 0)
            guard let offset = h.varint(), let size = h.varint(),
                  let data = block(bytes, Int(offset), Int(size)) else { continue }
            for (key, value) in entries(data) where key.count >= 8 {
                let tag = key.suffix(8).reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                visit(Data(key.dropLast(8)), tag >> 8, tag & 0xFF == 1 ? Data(value) : nil)
            }
        }
    }

    /// Block contents, Snappy-decompressed when its trailer says so.
    private static func block(_ bytes: [UInt8], _ offset: Int, _ size: Int) -> [UInt8]? {
        guard offset >= 0, size >= 0, offset + size + 1 <= bytes.count else { return nil }
        let raw = Array(bytes[offset..<(offset + size)])
        switch bytes[offset + size] {
        case 0: return raw
        case 1: return snappyDecompress(raw)
        default: return nil
        }
    }

    /// Prefix-compressed key/value entries, up to the restart array.
    private static func entries(_ b: [UInt8]) -> [([UInt8], [UInt8])] {
        guard b.count >= 4 else { return [] }
        let restarts = Int(b[b.count - 4]) | Int(b[b.count - 3]) << 8 | Int(b[b.count - 2]) << 16 | Int(b[b.count - 1]) << 24
        let end = b.count - 4 - 4 * restarts
        guard end >= 0 else { return [] }
        var out: [([UInt8], [UInt8])] = []
        var r = Reader(bytes: b, at: 0)
        var key: [UInt8] = []
        while r.p < end {
            guard let shared = r.varint(), let unshared = r.varint(), let valueLen = r.varint(),
                  Int(shared) <= key.count, r.p + Int(unshared) + Int(valueLen) <= end else { break }
            key = Array(key.prefix(Int(shared))) + b[r.p..<(r.p + Int(unshared))]
            r.p += Int(unshared)
            out.append((key, Array(b[r.p..<(r.p + Int(valueLen))])))
            r.p += Int(valueLen)
        }
        return out
    }

    static func snappyDecompress(_ src: [UInt8]) -> [UInt8]? {
        var r = Reader(bytes: src, at: 0)
        guard let length = r.varint(), length < 1 << 28 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(Int(length))
        while r.p < src.count {
            let tag = src[r.p]; r.p += 1
            var len: Int, offset: Int
            switch tag & 3 {
            case 0: // literal
                len = Int(tag >> 2)
                if len >= 60 {
                    let n = len - 59
                    guard r.p + n <= src.count else { return nil }
                    len = (0..<n).reduce(0) { $0 | Int(src[r.p + $1]) << (8 * $1) }
                    r.p += n
                }
                len += 1
                guard r.p + len <= src.count else { return nil }
                out += src[r.p..<(r.p + len)]
                r.p += len
                continue
            case 1:
                guard r.p < src.count else { return nil }
                len = 4 + Int(tag >> 2 & 7)
                offset = Int(tag >> 5) << 8 | Int(src[r.p]); r.p += 1
            case 2:
                guard r.p + 2 <= src.count else { return nil }
                len = Int(tag >> 2) + 1
                offset = Int(src[r.p]) | Int(src[r.p + 1]) << 8; r.p += 2
            default:
                guard r.p + 4 <= src.count else { return nil }
                len = Int(tag >> 2) + 1
                offset = (0..<4).reduce(0) { $0 | Int(src[r.p + $1]) << (8 * $1) }; r.p += 4
            }
            guard offset > 0, offset <= out.count else { return nil }
            let start = out.count - offset
            for i in 0..<len { out.append(out[start + i]) } // may overlap itself
        }
        return out.count == Int(length) ? out : nil
    }

    private struct Reader {
        let bytes: [UInt8]
        var p: Int
        init(bytes: [UInt8], at p: Int) { self.bytes = bytes; self.p = p }

        mutating func varint() -> UInt64? {
            var v: UInt64 = 0, shift: UInt64 = 0
            while p < bytes.count, shift < 64 {
                let b = bytes[p]; p += 1
                v |= UInt64(b & 0x7F) << shift
                if b < 0x80 { return v }
                shift += 7
            }
            return nil
        }

        mutating func slice() -> ArraySlice<UInt8>? {
            guard let n = varint(), p + Int(n) <= bytes.count else { return nil }
            defer { p += Int(n) }
            return bytes[p..<(p + Int(n))]
        }
    }
}

private extension Data {
    func hasSuffix(_ s: Data) -> Bool { count >= s.count && self.suffix(s.count) == s }
}
