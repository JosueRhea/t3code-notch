// Shared by the Mac notch and the iPhone Live Activity (Phone/project.yml compiles this file too),
// so both draw the same pixel logos. Foundation only.

/// Provider logos as pixel art, drawn by hand from T3 Code's provider logos (Resources/Logos);
/// colors are the logos' own. 7×7, except Claude's spark (9×9, so its rays stay round).
enum PixelArtData {
    struct Art {
        let rows: [String]
        let rgb: UInt32
    }

    static let arts: [String: Art] = [
        // Uneven rays, diagonals a pixel short of the corners: round like the real spark, not a box.
        "claudeAgent": Art(rows: ["....#....", ".#..#....", "..#.#.##.", "...###...", ".########",
                                  "...###...", ".##.#.#..", "....#..#.", "....#...."], rgb: 0xD97757),
        "codex": Art(rows: ["..###..", ".#.#.#.", "##.#.##", "#.###.#", "##.#.##", ".#.#.#.", "..###.."], rgb: 0xFFFFFF),
        "cursor": Art(rows: ["..###..", ".#####.", "#.###.#", "#..#..#", "#..#..#", ".#.#.#.", "..###.."], rgb: 0xEDECEC),
        "grok": Art(rows: ["..###.#", ".#...#.", "#...#.#", "#..#..#", "#.#...#", ".#...#.", "#.###.."], rgb: 0xF5F5F5),
        "muse": Art(rows: [".......", ".##.##.", "#..#..#", "#..#..#", "#..#..#", ".##.##.", "......."], rgb: 0x0081FB),
        "opencode": Art(rows: ["#######", "#.....#", "#.....#", "#.###.#", "#.###.#", "#.....#", "#######"], rgb: 0x9A9494),
        "pi": Art(rows: ["#######", ".#...#.", ".#...#.", ".#...#.", ".#...#.", ".#...##", "##....."], rgb: 0xF5F5F5),
    ]

    /// Unknown provider: a plain block (drawn in the working color).
    static let fallbackRows = [".......", ".#####.", ".#####.", ".#####.", ".#####.", ".#####.", "......."]
}
