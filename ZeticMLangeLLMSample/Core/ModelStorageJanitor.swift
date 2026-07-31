import Foundation
import OSLog
import ZeticMLange

/// Reclaims the disk the SDK leaves behind.
///
/// The SDK writes a fresh compiled copy of the model on every launch and never
/// evicts the old ones, and it leaves its intermediate `.mlmodelc` bundles in
/// `tmp/`. Measured on device: ~9.7 GB of container for a 1.76 GB model, growing
/// roughly 700 MB per launch. This runs *before* the model is initialised, so
/// nothing it touches is in use.
enum ModelStorageJanitor {
    private static let log = Logger(subsystem: "com.sjk.lfmvision", category: "Storage")

    struct Result {
        var prunedBytes: Int64 = 0
        var tmpBytes: Int64 = 0
        var compiledBytes: Int64 = 0
        var before: Int64 = 0
        var after: Int64 = 0

        var reclaimed: Int64 { max(0, before - after) }
    }

    /// Extraction directories to keep per model in `Documents/NativeLfmVL`.
    private static let extractionsToKeep = 1

    @discardableResult
    static func reclaim() -> Result {
        var result = Result()

        let before = ModelStorageReport.current()
        result.before = before.total
        log.notice("storage before cleanup:\n\(before.summary, privacy: .public)")

        // Deliberately narrow. `sweepAppCache()` and `pruneDownloadedArchives()`
        // stay disabled — they delete Apple's ANE cache and the live model archive
        // respectively, and both broke the app.
        //
        // `purgeCompiledArtifacts()` is enabled because leaving it off is worse:
        // the SDK adds ~1.5 GB of compiled artifacts per launch and never evicts
        // them (15 entries / 7.19 GB observed). That filled the device, which left
        // model extraction truncated and crashed the app with SIGSEGV mid-inference.
        // The entries are never reused — a new hash is compiled every launch — so
        // deleting them costs nothing beyond the recompile that happens anyway.
        result.prunedBytes = runSDKPrune()
        result.tmpBytes = sweepTemporaryArtifacts()
        result.compiledBytes = purgeCompiledArtifacts()
        excludeLargeDirectoriesFromBackup()

        let after = ModelStorageReport.current()
        result.after = after.total
        log.notice("""
            storage after cleanup:
            \(after.summary, privacy: .public)
            reclaimed \(ModelStorageReport.format(result.reclaimed), privacy: .public) \
            (sdk prune \(ModelStorageReport.format(result.prunedBytes), privacy: .public), \
            tmp \(ModelStorageReport.format(result.tmpBytes), privacy: .public), \
            compiled \(ModelStorageReport.format(result.compiledBytes), privacy: .public))
            """)

        return result
    }

    // MARK: - Steps

    /// The SDK's own supported cleanup. Runs first so we only hand-delete what it
    /// leaves behind.
    private static func runSDKPrune() -> Int64 {
        do {
            let pruned = try ModelCacheManager.shared.prune()
            log.notice("ModelCacheManager.prune reclaimed \(pruned.deletedBytes) bytes across \(pruned.deletedArtifacts) artifacts")
            return pruned.deletedBytes
        } catch {
            log.warning("ModelCacheManager.prune failed: \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }

    /// Empties our temp directory. Everything the SDK stages here is intermediate
    /// and nothing survives a launch by design, so this runs before model init
    /// rather than filtering by extension — the SDK also leaves opaque
    /// hash-named directories that an extension filter misses.
    private static func sweepTemporaryArtifacts() -> Int64 {
        removeContents(of: StorageLocations.tmp)
    }

    /// DISABLED — do not call. This broke the app.
    ///
    /// `Library/Caches/<bundle-id>` is not Zetic's. It holds
    /// `com.apple.e5rt.e5bundlecache` (Apple's Neural Engine bundle cache) and
    /// `Cache.db` (NSURLSession). Clearing it per launch forced a full ANE
    /// recompile on top of the CoreML compile, and — because the SDK caches
    /// backend-selection state, cf. `invalidateBackendSelectionCaches()` —
    /// triggered a fresh resolve and a 1.76 GB re-download. The artifact hash
    /// moved from `llmTargetModel-1d972ae5…` to `llmTargetModel-e4d2ba9d…`
    /// across janitor runs, which matches that theory.
    private static func sweepAppCache() -> Int64 {
        removeContents(of: StorageLocations.appCache)
    }

    /// Deletes every compiled artifact in Zetic's own compiled-model cache.
    ///
    /// Safe because the entries are never reused: retaining the four newest still
    /// produced a brand-new hash-named copy on the following launch, so the cache
    /// key is not stable across launches. Necessary because they accumulate at
    /// ~1.5 GB per launch with no eviction, and a full device leaves model
    /// extraction truncated — which crashes inference with SIGSEGV.
    private static func purgeCompiledArtifacts() -> Int64 {
        removeContents(of: StorageLocations.compiledCache)
    }

    /// Keeps only the newest extraction per model.
    ///
    /// Layout is `NativeLfmVL/<modelKey>/<archive>.ztc-<hash>/`, and a new hash
    /// directory appears per launch.
    private static func pruneExtractedModels() -> Int64 {
        let root = StorageLocations.extractedModels
        guard let models = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return 0 }

        var freed: Int64 = 0
        for model in models {
            guard let extractions = try? FileManager.default.contentsOfDirectory(
                at: model,
                includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }

            let sorted = extractions.sorted { modificationDate(of: $0) > modificationDate(of: $1) }
            for stale in sorted.dropFirst(extractionsToKeep) {
                freed += remove(stale)
            }
        }
        return freed
    }

    /// Keeps only the newest downloaded `.ztc` per model.
    ///
    /// Layout is `ZeticMLangeCache/artifacts/<modelKey>/<llmTargetModel-hash>/`.
    /// Re-downloads add a new hash directory instead of replacing the old one, so
    /// this grew to 4.92 GB — three copies of the same 1.64 GB archive — despite
    /// `cacheHandlingPolicy: .REMOVE_OVERLAPPING`. Only the newest is ever used,
    /// so pruning the rest costs nothing and does not trigger a re-download.
    private static func pruneDownloadedArchives() -> Int64 {
        let artifacts = StorageLocations.modelCache.appendingPathComponent("artifacts", isDirectory: true)
        guard let modelKeys = try? FileManager.default.contentsOfDirectory(
            at: artifacts,
            includingPropertiesForKeys: nil
        ) else { return 0 }

        var freed: Int64 = 0
        for modelKey in modelKeys {
            guard let versions = try? FileManager.default.contentsOfDirectory(
                at: modelKey,
                includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }

            let sorted = versions.sorted { modificationDate(of: $0) > modificationDate(of: $1) }
            for stale in sorted.dropFirst(1) {
                freed += remove(stale)
            }
        }
        return freed
    }

    /// Multi-gigabyte regenerable artifacts must not go to iCloud. The SDK writes
    /// extracted packages into `Documents/`, which is backed up and never purged
    /// by iOS.
    private static func excludeLargeDirectoriesFromBackup() {
        for url in [StorageLocations.extractedModels, StorageLocations.modelCache] {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            var mutable = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            do {
                try mutable.setResourceValues(values)
            } catch {
                log.warning("could not exclude \(url.lastPathComponent, privacy: .public) from backup: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Helpers

    /// Deletes everything inside `directory`, leaving the directory itself.
    private static func removeContents(of directory: URL) -> Int64 {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return 0 }
        return entries.reduce(0) { $0 + remove($1) }
    }

    private static func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// Deletes `url`, returning the bytes actually reclaimed.
    private static func remove(_ url: URL) -> Int64 {
        let size = ModelStorageReport.byteCount(of: url)
        do {
            try FileManager.default.removeItem(at: url)
            log.debug("removed \(url.lastPathComponent, privacy: .public) (\(size) bytes)")
            return size
        } catch {
            log.warning("could not remove \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }
}
