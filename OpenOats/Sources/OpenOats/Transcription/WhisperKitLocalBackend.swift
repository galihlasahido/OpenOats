import Foundation

/// Transcription backend that loads a WhisperKit CoreML model from a user-specified local folder.
/// @unchecked Sendable: whisperManager is written once in prepare() before any transcribe() calls.
final class WhisperKitLocalBackend: TranscriptionBackend, @unchecked Sendable {
    let displayName = "Whisper Local Model"
    private let modelFolder: String
    private var whisperManager: WhisperKitManager?

    init(modelFolder: String) {
        self.modelFolder = modelFolder
    }

    func checkStatus() -> BackendStatus {
        guard !modelFolder.isEmpty else {
            return .needsDownload(prompt: "Please select a folder containing WhisperKit CoreML model files in Settings.")
        }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: modelFolder, isDirectory: &isDir), isDir.boolValue else {
            return .needsDownload(prompt: "The selected model folder does not exist. Please choose a valid folder in Settings.")
        }
        return .ready
    }

    func clearModelCache() {
        // Local models are user-managed; do not delete them.
    }

    func prepare(onStatus: @Sendable (String) -> Void) async throws {
        onStatus("Loading local Whisper model...")
        let manager = WhisperKitManager(localModelFolder: modelFolder)
        try await manager.setup()
        self.whisperManager = manager
    }

    func transcribe(_ samples: [Float], locale: Locale) async throws -> String {
        guard let whisperManager else {
            throw TranscriptionBackendError.notPrepared
        }
        // Extract the language code from the locale (e.g. "id" from "id", "en" from "en-US")
        let languageCode = locale.language.languageCode?.identifier
        let language = (languageCode?.isEmpty ?? true) ? nil : languageCode
        return try await whisperManager.transcribe(samples, language: language)
    }
}
