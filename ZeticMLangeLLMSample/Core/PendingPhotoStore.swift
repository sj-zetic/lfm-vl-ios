import UIKit

/// Carries a photo and question across a relaunch.
///
/// The model retains vision context for the life of the process and offers no way
/// to clear it, so asking about a second photo requires a fresh process. Without
/// this the user must force-quit, reopen, re-pick the photo and retype the
/// question; with it they force-quit, reopen, and tap ask.
enum PendingPhotoStore {
    private static let questionKey = "pendingQuestion"

    private static var photoURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pending-photo.jpg")
    }

    struct Pending {
        let image: UIImage
        let question: String
    }

    /// Stores the photo the user tried to switch to, so the next launch opens on it.
    static func save(image: UIImage, question: String) {
        guard let data = image.jpegData(compressionQuality: 0.9) else { return }
        let directory = photoURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: photoURL, options: .atomic)
        UserDefaults.standard.set(question, forKey: questionKey)
        TraceLog.write("pending photo saved for next launch")
    }

    /// Returns and consumes anything saved by a previous run.
    static func take() -> Pending? {
        guard
            let data = try? Data(contentsOf: photoURL),
            let image = UIImage(data: data)
        else { return nil }

        let question = UserDefaults.standard.string(forKey: questionKey) ?? Constants.Prompt.defaultQuestion
        clear()
        TraceLog.write("restored pending photo from previous launch")
        return Pending(image: image, question: question)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: photoURL)
        UserDefaults.standard.removeObject(forKey: questionKey)
    }
}
