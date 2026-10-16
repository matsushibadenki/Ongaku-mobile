import AVFoundation

/// The worker hands ownership to the engine only after opening has finished.
/// It never accesses the file again; graph/scheduling mutations stay on MainActor.
nonisolated enum StreamingAudioFilePreparation {
    struct OpenedFile: @unchecked Sendable {
        let file: AVAudioFile
    }

    static func open(
        url: URL,
        opener: @escaping @Sendable (URL) throws -> AVAudioFile = { try AVAudioFile(forReading: $0) }
    ) async throws -> OpenedFile {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            try RemoteAudioReadiness.validate(url: url)
            let file = try opener(url)
            try Task.checkCancellation()
            return OpenedFile(file: file)
        }
        return try await withTaskCancellationHandler {
            let opened = try await worker.value
            try Task.checkCancellation()
            return opened
        } onCancel: {
            worker.cancel()
        }
    }
}
