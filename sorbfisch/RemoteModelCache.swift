import Foundation

/// Persistent downloads, outside the purgeable caches directory. A completion
/// marker prevents incomplete downloads from being mistaken for offline models.
nonisolated struct RemoteModelCache {
    // This test branch always downloads the small, standard WhisperKit model.
    // The repository namespace keeps it separate from the custom model cache.
    static let repository = "argmaxinc/whisperkit-coreml"
    let root: URL

    static func applicationCache() throws -> RemoteModelCache {
        var root = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("WhisperModels", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
        return RemoteModelCache(root: root)
    }

    func modelFolder(for variant: String) -> URL {
        root.appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(Self.repository, isDirectory: true)
            .appendingPathComponent(variant, isDirectory: true)
    }

    func completedModel(for variant: String) -> URL? {
        let folder = modelFolder(for: variant)
        guard FileManager.default.fileExists(atPath: marker(in: folder).path),
              hasModelFiles(in: folder) else { return nil }
        return folder
    }

    func markComplete(_ folder: URL, variant: String) throws {
        guard folder.standardizedFileURL == modelFolder(for: variant).standardizedFileURL,
              hasModelFiles(in: folder) else { throw CacheError.incomplete }
        try Data("complete-v1".utf8).write(to: marker(in: folder), options: .atomic)
    }

    private func marker(in folder: URL) -> URL {
        folder.appendingPathComponent(".sorbfisch-download-complete")
    }

    private func hasModelFiles(in folder: URL) -> Bool {
        ["AudioEncoder", "TextDecoder", "MelSpectrogram"].allSatisfy { name in
            let model = folder.appendingPathComponent("\(name).mlmodelc", isDirectory: true)
            return ["coremldata.bin", "model.mil", "weights/weight.bin"].allSatisfy { file in
                let url = model.appendingPathComponent(file)
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
                return size > 0
            }
        }
    }

    private enum CacheError: LocalizedError {
        case incomplete
        var errorDescription: String? {
            "Das heruntergeladene Sprachmodell ist unvollständig. Bitte versuche es erneut."
        }
    }
}
