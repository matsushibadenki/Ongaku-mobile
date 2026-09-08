import AuthenticationServices
import Combine
import CryptoKit
import Foundation
import Security
import UIKit

nonisolated enum GoogleOAuthConfiguration {
    static let clientID = "360009512347-155ldde91vo0b0dsm6asdeoi33n9mvd8.apps.googleusercontent.com"
    static let callbackScheme = "com.googleusercontent.apps.360009512347-155ldde91vo0b0dsm6asdeoi33n9mvd8"
    static let redirectURI = callbackScheme + ":/oauthredirect"
    static let scope = "openid email profile https://www.googleapis.com/auth/drive.readonly"
}

nonisolated enum GoogleOAuthError: LocalizedError {
    case invalidAuthorizationResponse
    case stateMismatch
    case missingAuthorizationCode
    case tokenRequestFailed(Int)
    case missingRefreshToken
    case notConnected
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidAuthorizationResponse:
            return L10n.tr("error.google_oauth.invalid_response")
        case .stateMismatch:
            return L10n.tr("error.google_oauth.state_mismatch")
        case .missingAuthorizationCode:
            return L10n.tr("error.google_oauth.missing_code")
        case .tokenRequestFailed(let status):
            return L10n.tr("error.google_oauth.token_failed", status)
        case .missingRefreshToken:
            return L10n.tr("error.google_oauth.missing_refresh_token")
        case .notConnected:
            return L10n.tr("error.google_oauth.not_connected")
        case .keychain(let status):
            return L10n.tr("error.google_oauth.keychain", status)
        }
    }
}

nonisolated private struct GoogleOAuthTokenResponse: Decodable, Sendable {
    let accessToken: String
    let expiresIn: TimeInterval
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
    }
}

actor GoogleOAuthTokenStore: GoogleOAuthAccessTokenProvider {
    static let shared = GoogleOAuthTokenStore()

    private let service = "littlebuddha.audio.google-oauth"
    private let account = "google-drive-refresh-token"
    private var cachedAccessToken: String?
    private var accessTokenExpiry = Date.distantPast

    func isConnected() -> Bool { (try? readRefreshToken()) != nil }

    func accessToken(forceRefresh: Bool) async throws -> String {
        if !forceRefresh, let cachedAccessToken,
           accessTokenExpiry.timeIntervalSinceNow > 60 {
            return cachedAccessToken
        }
        guard let refreshToken = try readRefreshToken() else {
            throw GoogleOAuthError.notConnected
        }
        let response = try await Self.requestToken([
            "client_id": GoogleOAuthConfiguration.clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ])
        cachedAccessToken = response.accessToken
        accessTokenExpiry = Date().addingTimeInterval(response.expiresIn)
        return response.accessToken
    }

    private func store(_ response: GoogleOAuthTokenResponse) throws {
        if let refreshToken = response.refreshToken {
            try saveRefreshToken(refreshToken)
        } else if (try readRefreshToken()) == nil {
            throw GoogleOAuthError.missingRefreshToken
        }
        cachedAccessToken = response.accessToken
        accessTokenExpiry = Date().addingTimeInterval(response.expiresIn)
    }

    func disconnect() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GoogleOAuthError.keychain(status)
        }
        cachedAccessToken = nil
        accessTokenExpiry = .distantPast
    }

    func exchangeAuthorizationCode(_ code: String, verifier: String) async throws {
        let response = try await Self.requestToken([
            "client_id": GoogleOAuthConfiguration.clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": GoogleOAuthConfiguration.redirectURI,
        ])
        try store(response)
    }

    private static func requestToken(_ parameters: [String: String]) async throws -> GoogleOAuthTokenResponse {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = parameters
            .sorted { $0.key < $1.key }
            .map { "\($0.key.formEncoded)=\($0.value.formEncoded)" }
            .joined(separator: "&")
            .data(using: .utf8)
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GoogleOAuthError.invalidAuthorizationResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GoogleOAuthError.tokenRequestFailed(http.statusCode)
        }
        return try JSONDecoder().decode(GoogleOAuthTokenResponse.self, from: data)
    }

    private func readRefreshToken() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let token = String(data: data, encoding: .utf8) else {
            throw GoogleOAuthError.keychain(status)
        }
        return token
    }

    private func saveRefreshToken(_ token: String) throws {
        try? disconnect()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(token.utf8),
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw GoogleOAuthError.keychain(status) }
    }
}

@MainActor
final class GoogleDriveConnectionController: NSObject, ObservableObject,
    ASWebAuthenticationPresentationContextProviding {
    @Published private(set) var isConnected = false
    @Published private(set) var isWorking = false
    @Published private(set) var trackCount = 0
    @Published var errorMessage: String?

    private var authenticationSession: ASWebAuthenticationSession?

    override init() {
        super.init()
        Task { await refreshConnectionState() }
    }

    func refreshConnectionState() async {
        isConnected = await GoogleOAuthTokenStore.shared.isConnected()
        trackCount = GoogleDriveLibraryStore.shared.files.count
    }

    func connectAndSync() async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            let verifier = Self.randomURLSafeString(byteCount: 48)
            let state = Self.randomURLSafeString(byteCount: 24)
            let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
            var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            components.queryItems = [
                .init(name: "client_id", value: GoogleOAuthConfiguration.clientID),
                .init(name: "redirect_uri", value: GoogleOAuthConfiguration.redirectURI),
                .init(name: "response_type", value: "code"),
                .init(name: "scope", value: GoogleOAuthConfiguration.scope),
                .init(name: "code_challenge", value: challenge),
                .init(name: "code_challenge_method", value: "S256"),
                .init(name: "access_type", value: "offline"),
                .init(name: "prompt", value: "consent"),
                .init(name: "state", value: state),
            ]
            let callback = try await authenticate(at: components.url!)
            guard let callbackComponents = URLComponents(url: callback, resolvingAgainstBaseURL: false) else {
                throw GoogleOAuthError.invalidAuthorizationResponse
            }
            let values = Dictionary(uniqueKeysWithValues: callbackComponents.queryItems?.map { ($0.name, $0.value ?? "") } ?? [])
            guard values["state"] == state else { throw GoogleOAuthError.stateMismatch }
            guard let code = values["code"], !code.isEmpty else {
                throw GoogleOAuthError.missingAuthorizationCode
            }
            try await GoogleOAuthTokenStore.shared.exchangeAuthorizationCode(code, verifier: verifier)
            isConnected = true
            return try await syncLibrary()
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return false
        } catch {
            errorMessage = error.localizedDescription
            await refreshConnectionState()
            return false
        }
    }

    func syncLibrary() async throws -> Bool {
        let client = GoogleDriveAudioClient(tokenProvider: GoogleOAuthTokenStore.shared)
        var files: [GoogleDriveAudioFile] = []
        var pageToken: String?
        repeat {
            let page = try await client.listAudioFiles(pageToken: pageToken)
            files.append(contentsOf: page.files)
            pageToken = page.nextPageToken
        } while pageToken != nil
        GoogleDriveLibraryStore.shared.replace(with: files)
        trackCount = files.count
        isConnected = true
        return true
    }

    func refreshLibrary() async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        do { return try await syncLibrary() }
        catch { errorMessage = error.localizedDescription; return false }
    }

    func disconnect() async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            try await GoogleOAuthTokenStore.shared.disconnect()
            GoogleDriveLibraryStore.shared.replace(with: [])
            isConnected = false
            trackCount = 0
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }

    private func authenticate(at url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: GoogleOAuthConfiguration.callbackScheme
            ) { [weak self] callback, error in
                self?.authenticationSession = nil
                if let error { continuation.resume(throwing: error) }
                else if let callback { continuation.resume(returning: callback) }
                else { continuation.resume(throwing: GoogleOAuthError.invalidAuthorizationResponse) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            authenticationSession = session
            guard session.start() else {
                authenticationSession = nil
                continuation.resume(throwing: GoogleOAuthError.invalidAuthorizationResponse)
                return
            }
        }
    }

    private static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded
    }
}

private extension String {
    nonisolated var formEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? self
    }
}

private extension CharacterSet {
    nonisolated static let urlQueryValueAllowed: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()
}

private extension Data {
    nonisolated var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
