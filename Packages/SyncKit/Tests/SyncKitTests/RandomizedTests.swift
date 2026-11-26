import Foundation
import Testing
@testable import SyncKit

/// Three Macs making random edits, deletions, scans, pulls, and relaunches
/// in a random order — each seed a different history, with clocks a few
/// minutes apart — then syncing until nothing changes.
///
/// Whatever happened, the Macs must settle on the same files, and no copy
/// anyone kept may be lost: each is on every Mac or in some Mac's Trash. A
/// copy someone replaced or deleted may come back when a concurrent change
/// to it elsewhere wins; that loses nothing.
struct RandomizedTests {
    /// The paths the Macs change: files at the top, in a folder and in a
    /// folder inside that, and those folders' names as files.
    private static let paths = ["a", "b", "d", "d/a", "d/b", "d/e", "d/e/a", "e"]

    /// The Macs' names.
    private static let names = ["studio", "laptop", "mini"]

    /// How many random steps each history has.
    private static let steps = 40

    /// One random history, `seed` choosing every step, converges with
    /// nothing kept lost.
    @Test(arguments: 0..<200)
    func randomHistoryConverges(seed: UInt64) async throws {
        var random = SplitMix64(seed: seed)
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        var macs = try Self.names.map { try TestMac(named: $0, in: directory) }
        var trashes = macs.map { [$0.trash] }
        let start = ago(10_000)
        let skews = Self.names.map { _ in TimeInterval(Int.random(in: -300...300, using: &random)) }
        var written: Set<String> = ["first a", "first d/a"]
        var replaced: Set<String> = []
        var history: [String] = []

        try macs[0].write("first a", to: "Notes/a", modified: start)
        try macs[0].write("first d/a", to: "Notes/d/a", modified: start)
        try await macs[0].engine.addItem(at: macs[0].url("Notes"))
        try await syncAll(macs)

        for step in 0..<Self.steps {
            let index = Int.random(in: 0..<macs.count, using: &random)
            let mac = macs[index]
            let name = Self.names[index]
            let path = Self.paths[Int.random(in: 0..<Self.paths.count, using: &random)]
            switch Int.random(in: 0..<100, using: &random) {
            case 0..<35:
                let ancestors = Self.ancestors(of: path)
                guard !ancestors.contains(where: { mac.exists("Notes/\($0)") && !FileScanner.isDirectory(mac.url("Notes/\($0)")) }),
                      !FileScanner.isDirectory(mac.url("Notes/\(path)")) else {
                    history.append("\(name) can't write \(path)")
                    continue
                }
                if let old = mac.read("Notes/\(path)") {
                    replaced.insert(old)
                }
                let contents = "\(name) \(step)"
                // Whole seconds apart on one Mac and a few milliseconds
                // apart between Macs, so no two writes share a size and
                // time, which a scan would take for an untouched file.
                let offset = TimeInterval(step) + skews[index] + TimeInterval(index) * 0.0105
                try mac.write(contents, to: "Notes/\(path)", modified: start.addingTimeInterval(offset))
                written.insert(contents)
                history.append("\(name) writes \(path): \(contents)")
            case 35..<50:
                guard mac.exists("Notes/\(path)") else {
                    history.append("\(name) has no \(path) to delete")
                    continue
                }
                if FileScanner.isDirectory(mac.url("Notes/\(path)")) {
                    replaced.formUnion(mac.tree("Notes/\(path)").values.filter { $0 != "/" })
                } else if let old = mac.read("Notes/\(path)") {
                    replaced.insert(old)
                }
                try mac.remove("Notes/\(path)")
                history.append("\(name) deletes \(path)")
            case 50..<65:
                await mac.engine.rescanAll()
                history.append("\(name) scans")
            case 65..<95:
                let other = (index + Int.random(in: 1..<macs.count, using: &random)) % macs.count
                let report = try await mac.pull(from: macs[other])
                history.append("\(name) pulls from \(Self.names[other]): \(report)")
            default:
                macs[index] = try TestMac(named: name, in: directory)
                trashes[index].append(macs[index].trash)
                history.append("\(name) relaunches")
            }
        }

        var converged = false
        for round in 0..<8 {
            var isQuiet = true
            for mac in macs {
                if await mac.engine.rescanAll() {
                    isQuiet = false
                }
            }
            for (index, mac) in macs.enumerated() {
                for (otherIndex, other) in macs.enumerated() where otherIndex != index {
                    let report = try await mac.pull(from: other)
                    if report != SyncReport() {
                        isQuiet = false
                        history.append("round \(round): \(Self.names[index]) pulls from \(Self.names[otherIndex]): \(report)")
                    }
                }
            }
            if isQuiet {
                converged = true
                break
            }
        }

        let tree = macs[0].tree("Notes")
        let files = Set(tree.values.filter { $0 != "/" })
        let trashed = Set(trashes.flatMap { $0.flatMap(\.all) })
        let lost = written.subtracting(replaced).subtracting(files).subtracting(trashed)
        let comment = Comment(rawValue: "seed \(seed), lost \(lost.sorted())\n" + history.joined(separator: "\n"))
        #expect(converged, comment)
        for mac in macs.dropFirst() {
            #expect(mac.tree("Notes") == tree, comment)
        }
        #expect(lost.isEmpty, comment)
        #expect(files.isSubset(of: written), comment)
    }

    /// The folders `path` is inside, outermost first.
    private static func ancestors(of path: String) -> [String] {
        let components = path.split(separator: "/").dropLast()
        return components.indices.map { components[...$0].joined(separator: "/") }
    }
}

/// A small, fast generator whose sequence is fixed by its seed, so a
/// failing history can be replayed.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    /// Creates a generator whose sequence `seed` fixes.
    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
