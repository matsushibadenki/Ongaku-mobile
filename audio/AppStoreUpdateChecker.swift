import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class AppStoreUpdateChecker: ObservableObject {
    struct AvailableUpdate: Equatable {
        let version: String
        let storeURL: URL
    }

    @Published private(set) var availableUpdate: AvailableUpdate?
    @Published var isAlertPresented = false

    private static let appStoreID = "6761979714"
    private var hasCheckedThisLaunch = false

    func checkForUpdate() async {
        guard !hasCheckedThisLaunch else { return }
        hasCheckedThisLaunch = true

        let localVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let region = Locale.current.region?.identifier.lowercased() ?? "jp"
        let regions = region == "jp" ? [region] : [region, "jp"]

        for storefront in regions {
            let update: AvailableUpdate?
            do {
                update = try await fetchUpdate(localVersion: localVersion, storefront: storefront)
            } catch {
                continue
            }
            if let update {
                availableUpdate = update
                isAlertPresented = true
            }
            return
        }
    }

    func openAppStore() {
        guard let update = availableUpdate else { return }
        #if canImport(UIKit)
        UIApplication.shared.open(update.storeURL)
        #endif
    }

    nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        candidate.compare(current, options: .numeric) == .orderedDescending
    }

    private func fetchUpdate(localVersion: String, storefront: String) async throws -> AvailableUpdate? {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [
            URLQueryItem(name: "id", value: Self.appStoreID),
            URLQueryItem(name: "country", value: storefront)
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let lookup = try JSONDecoder().decode(LookupResponse.self, from: data)
        guard let result = lookup.results.first,
              Self.isVersion(result.version, newerThan: localVersion) else {
            return nil
        }
        let storeURL = URL(string: "itms-apps://apps.apple.com/app/id\(Self.appStoreID)")
            ?? result.trackViewURL
        return AvailableUpdate(version: result.version, storeURL: storeURL)
    }
}

private struct LookupResponse: Decodable {
    let results: [LookupResult]
}

private struct LookupResult: Decodable {
    let version: String
    let trackViewURL: URL

    enum CodingKeys: String, CodingKey {
        case version
        case trackViewURL = "trackViewUrl"
    }
}
