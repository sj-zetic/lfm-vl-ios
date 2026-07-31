import Foundation

/// Appends diagnostics to a file inside the app container.
///
/// `devicectl … --console` is the only way to read stdout from a device, but it
/// restarts the app on attach and SIGKILLs it when the session ends — which made
/// it impossible to capture a normal, user-driven session. Writing to a file
/// instead lets the app be used normally and the log pulled afterwards with:
///
///     xcrun devicectl device copy from --device <udid> \
///       --domain-type appDataContainer --domain-identifier com.sjk.lfmvision \
///       --source Documents/vlm-trace.log --destination ./vlm-trace.log
enum TraceLog {
    private static let queue = DispatchQueue(label: "com.sjk.lfmvision.tracelog")

    private static let fileURL: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("vlm-trace.log")
    }()

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Writes to both the file and stdout, so either capture method works.
    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        NSLog("[VLM] %@", message as NSString)

        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }

    /// Marks a new run so successive sessions are distinguishable in one file.
    static func startSession() {
        write("=== session start ===")
    }
}
