import Foundation

/// GET-only, bounded retries and bounded response accumulation. Authentication
/// refresh belongs to the provider and is never retried here.
nonisolated struct RemoteAudioHTTP {
    var session: URLSession = .shared
    var sleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(for: .seconds(seconds))
    }
    func data(for request: URLRequest, maximumBytes: Int,
              validate: @Sendable (HTTPURLResponse) throws -> Void = { _ in }) async throws -> (Data, HTTPURLResponse) {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                let (stream, response) = try await session.bytes(for: request)
                defer { stream.task.cancel() }
                guard let http = response as? HTTPURLResponse else { throw RemoteAudioByteSourceError.invalidResponse(-1) }
                if [408,429,500,502,503,504].contains(http.statusCode), attempt < 2,
                   let delay = retryDelay(http, attempt: attempt) {
                    stream.task.cancel()
                    try await sleep(delay); continue
                }
                guard (200..<300).contains(http.statusCode) else { return (Data(), http) }
                try validate(http)
                guard response.expectedContentLength <= Int64(maximumBytes) else {
                    throw RemoteAudioByteSourceError.incompleteRange(expected: maximumBytes, actual: Int(clamping: response.expectedContentLength))
                }
                var data = Data(); data.reserveCapacity(min(maximumBytes, 64 * 1024))
                for try await byte in stream {
                    guard data.count < maximumBytes else {
                        throw RemoteAudioByteSourceError.incompleteRange(expected: maximumBytes, actual: data.count + 1)
                    }
                    if data.count.isMultiple(of: 16_384) { try Task.checkCancellation() }
                    data.append(byte)
                }
                try Task.checkCancellation()
                return (data, http)
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                let retryable = (error as? URLError).map {
                    [.timedOut,.networkConnectionLost,.notConnectedToInternet,.cannotConnectToHost,.dnsLookupFailed].contains($0.code)
                } ?? false
                guard retryable, attempt < 2 else { throw error }
                try await sleep(0.25 * pow(2, Double(attempt)))
            }
        }
        throw URLError(.cannotLoadFromNetwork)
    }
    private func retryDelay(_ response: HTTPURLResponse, attempt: Int) -> TimeInterval? {
        guard let header = response.value(forHTTPHeaderField: "Retry-After") else { return 0.25 * pow(2, Double(attempt)) }
        let delay: TimeInterval
        if let seconds = Double(header), seconds.isFinite { delay = seconds }
        else {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
            guard let date = formatter.date(from: header) else { return nil }
            delay = date.timeIntervalSinceNow
        }
        // Long server backoff is returned to the UI instead of silently ignored.
        guard delay <= 2 else { return nil }
        return max(0, delay)
    }
    static func validateRange(_ http: HTTPURLResponse, range: Range<Int64>, length: Int64) throws {
        let encoding = http.value(forHTTPHeaderField: "Content-Encoding")?.lowercased() ?? "identity"
        guard encoding == "identity" else { throw RemoteAudioByteSourceError.invalidContentRange }
        if http.statusCode == 200, range.lowerBound == 0, range.upperBound == length { return }
        guard http.statusCode == 206,
              http.value(forHTTPHeaderField: "Content-Range")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                == "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(length)" else {
            throw RemoteAudioByteSourceError.invalidContentRange
        }
    }
}
