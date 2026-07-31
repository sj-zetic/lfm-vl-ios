import Foundation

/// Per-area accounting of what the SDK leaves on disk.
///
/// The model is ~1.76 GB but the container was measured at ~9.7 GB, so every
/// claim about reclaimed space should come from a number rather than an estimate.
struct ModelStorageReport {
    struct Area: Identifiable {
        let id = UUID()
        let name: String
        let url: URL
        let bytes: Int64
    }

    let areas: [Area]

    var total: Int64 { areas.reduce(0) { $0 + $1.bytes } }

    static func current() -> ModelStorageReport {
        ModelStorageReport(areas: StorageLocations.all.map { location in
            Area(name: location.name, url: location.url, bytes: byteCount(of: location.url))
        })
    }

    var summary: String {
        let lines = areas
            .filter { $0.bytes > 0 }
            .sorted { $0.bytes > $1.bytes }
            .map { "  \(format($0.bytes))\t\($0.name)" }
        return (["total \(format(total))"] + lines).joined(separator: "\n")
    }

    func format(_ bytes: Int64) -> String { Self.format(bytes) }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Recursive size on disk. `.totalFileAllocatedSize` reflects what the
    /// filesystem actually charges, which is what Settings reports.
    static func byteCount(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard
            FileManager.default.fileExists(atPath: url.path),
            let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: Array(keys),
                options: []
            )
        else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard
                let values = try? fileURL.resourceValues(forKeys: keys),
                values.isRegularFile == true
            else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }
}

/// The directories ZeticMLange writes into, resolved once.
enum StorageLocations {
    struct Location {
        let name: String
        let url: URL
    }

    static var tmp: URL { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) }

    static var caches: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// CoreML artifacts compiled by the SDK. Measured at 3.59 GB across 7 copies.
    static var compiledCache: URL { caches.appendingPathComponent("zetic_coreml_compiled", isDirectory: true) }

    /// App-scoped cache — CoreML spill, measured at 1.36 GB.
    static var appCache: URL {
        caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.sjk.lfmvision", isDirectory: true)
    }

    /// The downloaded `.ztc` package — the one legitimately large item.
    static var modelCache: URL { applicationSupport.appendingPathComponent("ZeticMLangeCache", isDirectory: true) }

    /// Extracted `.mlpackage`s. In `Documents/`, so iOS never purges it and
    /// iCloud backs it up.
    static var extractedModels: URL { documents.appendingPathComponent("NativeLfmVL", isDirectory: true) }

    static var all: [Location] {
        [
            Location(name: "tmp/", url: tmp),
            Location(name: "Caches/zetic_coreml_compiled", url: compiledCache),
            Location(name: "Caches/<bundle>", url: appCache),
            Location(name: "Application Support/ZeticMLangeCache", url: modelCache),
            Location(name: "Documents/NativeLfmVL", url: extractedModels),
        ]
    }
}
