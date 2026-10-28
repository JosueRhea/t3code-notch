import AppKit
import Testing
@testable import T3Notch

@Suite struct ThemeTests {
    @Test func snappyLiteralsAndOverlappingCopies() {
        // "abcd" literal, then copy-1 (len 8, offset 4): "abcdabcdabcd".
        let compressed: [UInt8] = [12, 0x0C, 0x61, 0x62, 0x63, 0x64, 0x11, 0x04]
        #expect(LevelDB.snappyDecompress(compressed).map { String(decoding: $0, as: UTF8.self) } == "abcdabcdabcd")
        #expect(LevelDB.snappyDecompress([12, 0x0C, 0x61]) == nil) // truncated
    }

    @Test func logBatchesNewestWins() {
        func batch(_ seq: UInt64, _ key: String, _ value: String) -> [UInt8] {
            var b = (0..<8).map { UInt8(seq >> (8 * $0) & 0xFF) } + [1, 0, 0, 0, 1]
            b += [UInt8(key.utf8.count)] + Array(key.utf8) + [UInt8(value.utf8.count)] + Array(value.utf8)
            return b
        }
        func record(_ payload: [UInt8]) -> [UInt8] {
            [0, 0, 0, 0, UInt8(payload.count & 0xFF), UInt8(payload.count >> 8), 1] + payload
        }
        let log = record(batch(7, "k", "old")) + record(batch(9, "k", "new"))
        var seen: [String: (UInt64, String)] = [:]
        LevelDB.readLog(Data(log)) { key, seq, value in
            let k = String(decoding: key, as: UTF8.self)
            if seq >= seen[k]?.0 ?? 0 { seen[k] = (seq, value.map { String(decoding: $0, as: UTF8.self) } ?? "") }
        }
        #expect(seen["k"]?.1 == "new")
    }

    @Test func localStorageValues() {
        #expect(T3ThemeReader.decodeValue(Data([1]) + Data("ember".utf8)) == "ember")
        #expect(T3ThemeReader.decodeValue(Data([0]) + "iris".data(using: .utf16LittleEndian)!) == "iris")
    }

    @Test func halvesFollowTheVisibleAppearance() {
        let halves = #"{"light":"ember","dark":"ocean"}"#
        #expect(T3ThemeReader.paletteId(theme: "grove", halves: nil, appearance: "light", systemDark: true) == "grove")
        #expect(T3ThemeReader.paletteId(theme: "grove", halves: halves, appearance: "light", systemDark: true) == "ember")
        #expect(T3ThemeReader.paletteId(theme: "grove", halves: halves, appearance: "system", systemDark: true) == "ocean")
        #expect(T3ThemeReader.paletteId(theme: nil, halves: nil, appearance: nil, systemDark: false) == "")
    }

    @Test func classicFillIsTranslucentWhite() {
        #expect(NotchTheme.classic.fill(0.1) == NSColor.white.withAlphaComponent(0.1))
        #expect(NotchTheme.named("ember")?.label == "Ember")
        #expect(NotchTheme.named("dracula") == nil)
    }
}

/// Reads this machine's real T3 storage: `T3NOTCH_LIVE=1 swift test --filter liveT3Theme`.
@Test(.enabled(if: ProcessInfo.processInfo.environment["T3NOTCH_LIVE"] != nil))
func liveT3Theme() {
    let (id, stamp) = T3ThemeReader.read(since: nil, systemDark: false)
    print("T3 theme:", id ?? "unreadable", "storage modified:", stamp?.modified as Any)
    #expect(id != nil)
}
