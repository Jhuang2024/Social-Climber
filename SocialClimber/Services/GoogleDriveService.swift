import Foundation
import AuthenticationServices
import CryptoKit
import UIKit

/// Optional, read-only Google Drive integration used to pull Instagram
/// "Download Your Information" exports that Meta delivers to Drive on a
/// schedule.
///
/// Bring-your-own OAuth client, exactly like `GoogleCalendarService`: the
/// same OAuth Client ID pasted in Settings works for both: just enable the
/// Google Drive API on the same Google Cloud project. Sign-in uses the PKCE
/// flow for native apps; only a refresh token is stored, in the iOS
/// Keychain. Export files are downloaded to a temporary file, parsed, and
/// deleted; the raw export never persists on this device.
@MainActor
@Observable
final class GoogleDriveService: NSObject {
    static let shared = GoogleDriveService()

    private static let scope = "https://www.googleapis.com/auth/drive.readonly"
    private static let authEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    private static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    private static let clientIDDefaultsKey = "googleClientID"

    private(set) var isConnected: Bool
    private var accessToken: String?
    private var accessTokenExpiry: Date?
    private var activeSession: ASWebAuthenticationSession?

    override init() {
        isConnected = KeychainService.hasGoogleDriveRefreshToken()
        super.init()
    }

    // MARK: Connect / disconnect

    func connect() async throws {
        let clientID = try clientIDOrThrow()
        let verifier = Self.randomURLSafeString()
        let challenge = Self.codeChallenge(for: verifier)
        let scheme = Self.reversedClientIDScheme(clientID)
        let redirectURI = "\(scheme):/oauth2redirect"

        var components = URLComponents(url: Self.authEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        guard let authURL = components.url else { throw GoogleDriveError.invalidClientID }

        let callbackURL = try await runAuthSession(url: authURL, callbackScheme: scheme)
        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value else {
            throw GoogleDriveError.authCanceled
        }

        let tokens = try await requestTokens(body: [
            "code": code,
            "client_id": clientID,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI,
        ])
        guard let refreshToken = tokens.refreshToken else {
            throw GoogleDriveError.missingRefreshToken
        }
        try KeychainService.saveGoogleDriveRefreshToken(refreshToken)
        accessToken = tokens.accessToken
        accessTokenExpiry = Date.now.addingTimeInterval(TimeInterval(tokens.expiresIn))
        isConnected = true
    }

    func disconnect() {
        try? KeychainService.saveGoogleDriveRefreshToken("")
        accessToken = nil
        accessTokenExpiry = nil
        isConnected = false
    }

    // MARK: Files

    struct DriveFile: Identifiable {
        let id: String
        let name: String
        let mimeType: String
        let modifiedTime: Date?
        let size: Int64?

        var isFolder: Bool { mimeType == "application/vnd.google-apps.folder" }
        var isZip: Bool {
            mimeType == "application/zip" || mimeType == "application/x-zip-compressed"
                || name.lowercased().hasSuffix(".zip")
        }
    }

    /// The newest Instagram export zip(s): several, because Meta splits
    /// large exports into multiple parts uploaded together. When
    /// `folderName` is non-empty, only that folder is searched; otherwise
    /// the whole Drive is queried for Instagram-looking zip files.
    /// Parts are grouped by "uploaded within 48 hours of the newest one".
    func latestInstagramExportFiles(folderName: String) async throws -> [DriveFile] {
        var query: String
        if folderName.trimmingCharacters(in: .whitespaces).isEmpty {
            query = "(name contains 'instagram' or name contains 'meta') and trashed = false"
        } else {
            guard let folder = try await findFolder(named: folderName) else {
                throw GoogleDriveError.folderNotFound(folderName)
            }
            query = "'\(folder.id)' in parents and trashed = false"
        }

        let candidates = try await listFiles(query: query)
            .filter { $0.isZip }
            .sorted { ($0.modifiedTime ?? .distantPast) > ($1.modifiedTime ?? .distantPast) }

        guard let newest = candidates.first, let newestTime = newest.modifiedTime else {
            return Array(candidates.prefix(1))
        }
        // Multi-part exports share a name stem and land together; requiring
        // both the stem match and the time window keeps an older, unrelated
        // export (or a re-requested one from yesterday) from being merged
        // into this parse and poisoning the follower diff.
        let newestStem = Self.exportStem(newest.name)
        let group = candidates.filter {
            guard let time = $0.modifiedTime else { return false }
            return newestTime.timeIntervalSince(time) < 48 * 3600
                && Self.exportStem($0.name) == newestStem
        }
        return group.isEmpty ? [newest] : group
    }

    /// A zip's name with the extension and any trailing part number
    /// ("-part-2", "_3", " (1)") stripped, for grouping multi-part exports.
    private static func exportStem(_ name: String) -> String {
        var stem = name.lowercased()
        if let range = stem.range(of: ".zip") { stem = String(stem[..<range.lowerBound]) }
        stem = stem.replacingOccurrences(
            of: #"[-_. ()]*(part)?[-_. ()]*\d+$"#,
            with: "",
            options: .regularExpression
        )
        return stem
    }

    private func findFolder(named name: String) async throws -> DriveFile? {
        let escaped = name.replacingOccurrences(of: "'", with: "\\'")
        let query = "mimeType = 'application/vnd.google-apps.folder' and name = '\(escaped)' and trashed = false"
        return try await listFiles(query: query).first
    }

    private func listFiles(query: String) async throws -> [DriveFile] {
        let token = try await validAccessToken()
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "fields", value: "files(id,name,mimeType,modifiedTime,size)"),
            URLQueryItem(name: "pageSize", value: "100"),
            URLQueryItem(name: "orderBy", value: "modifiedTime desc"),
        ]
        guard let url = components.url else { throw GoogleDriveError.requestFailed }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw GoogleDriveError.requestFailed
        }
        let decoded = try JSONDecoder().decode(FileListResponse.self, from: data)
        return decoded.files.map { $0.asDriveFile }
    }

    /// Downloads a file's content to a temporary file on disk (exports can
    /// be large; never buffered whole in memory) and returns its URL. The
    /// caller is responsible for deleting it when done.
    func downloadToTemporaryFile(fileID: String) async throws -> URL {
        let token = try await validAccessToken()
        guard let url = URL(string: "https://www.googleapis.com/drive/v3/files/\(fileID)?alt=media") else {
            throw GoogleDriveError.requestFailed
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (tempURL, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: tempURL)
            throw GoogleDriveError.requestFailed
        }
        // Move it out of URLSession's temp location so it survives until the
        // caller is finished with it.
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("ig-export-\(UUID().uuidString).zip")
        try FileManager.default.moveItem(at: tempURL, to: destination)
        return destination
    }

    // MARK: Tokens

    private func validAccessToken() async throws -> String {
        if let accessToken, let expiry = accessTokenExpiry, expiry > Date.now.addingTimeInterval(30) {
            return accessToken
        }
        guard let refreshToken = try KeychainService.googleDriveRefreshToken(), !refreshToken.isEmpty else {
            throw GoogleDriveError.notConnected
        }
        let clientID = try clientIDOrThrow()
        let tokens = try await requestTokens(body: [
            "client_id": clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ])
        accessToken = tokens.accessToken
        accessTokenExpiry = Date.now.addingTimeInterval(TimeInterval(tokens.expiresIn))
        return tokens.accessToken
    }

    private func requestTokens(body: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw GoogleDriveError.tokenExchangeFailed
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private func clientIDOrThrow() throws -> String {
        let raw = UserDefaults.standard.string(forKey: Self.clientIDDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { throw GoogleDriveError.missingClientID }
        guard let sanitized = Self.sanitizeClientID(raw) else { throw GoogleDriveError.invalidClientID }
        return sanitized
    }

    /// Same paste-cleanup as `GoogleCalendarService.sanitizeClientID`: see
    /// the doc comment there for why this matters (a stray URL scheme in
    /// the pasted ID crashes ASWebAuthenticationSession).
    private static func sanitizeClientID(_ raw: String) -> String? {
        var value = raw
        if value.contains("://"), let url = URL(string: value), let host = url.host {
            value = host
        }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let suffix = ".apps.googleusercontent.com"
        guard value.hasSuffix(suffix), value.count > suffix.count else { return nil }
        return value
    }

    // MARK: Auth session

    private func runAuthSession(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] callbackURL, error in
                self?.activeSession = nil
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: error ?? GoogleDriveError.authCanceled)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            activeSession = session
            session.start()
        }
    }

    // MARK: PKCE helpers

    private static func randomURLSafeString(length: Int = 64) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return urlSafeBase64(Data(bytes))
    }

    private static func codeChallenge(for verifier: String) -> String {
        let hashed = SHA256.hash(data: Data(verifier.utf8))
        return urlSafeBase64(Data(hashed))
    }

    private static func urlSafeBase64(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func reversedClientIDScheme(_ clientID: String) -> String {
        clientID.split(separator: ".").reversed().joined(separator: ".")
    }

    private static func formEncode(_ params: [String: String]) -> Data {
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))
        return params.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }
        .joined(separator: "&")
        .data(using: .utf8) ?? Data()
    }

    // MARK: Wire types

    private struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: Int
        let refreshToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
        }
    }

    private struct FileListResponse: Decodable {
        let files: [WireFile]
    }

    private struct WireFile: Decodable {
        let id: String
        let name: String
        let mimeType: String
        let modifiedTime: String?
        let size: String?

        var asDriveFile: DriveFile {
            DriveFile(
                id: id,
                name: name,
                mimeType: mimeType,
                modifiedTime: modifiedTime.flatMap { Self.iso.date(from: $0) ?? Self.isoPlain.date(from: $0) },
                size: size.flatMap { Int64($0) }
            )
        }

        private static let iso: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()
        private static let isoPlain = ISO8601DateFormatter()
    }
}

extension GoogleDriveService: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let keyWindow = scenes.flatMap(\.windows).first(where: \.isKeyWindow) {
            return keyWindow
        }
        if let anyWindow = scenes.flatMap(\.windows).first {
            return anyWindow
        }
        if let scene = scenes.first {
            return UIWindow(windowScene: scene)
        }
        return ASPresentationAnchor()
    }
}

enum GoogleDriveError: LocalizedError {
    case missingClientID
    case invalidClientID
    case authCanceled
    case tokenExchangeFailed
    case missingRefreshToken
    case notConnected
    case requestFailed
    case folderNotFound(String)
    case noExportFound

    var errorDescription: String? {
        switch self {
        case .missingClientID:
            "Add your Google OAuth Client ID in Settings first."
        case .invalidClientID:
            "That doesn't look like a Google Client ID. It should end in \".apps.googleusercontent.com\"."
        case .authCanceled:
            "Sign-in was canceled before it finished."
        case .tokenExchangeFailed:
            "Google didn't accept that sign-in. Double check the Client ID and that the Drive API is enabled, then try again."
        case .missingRefreshToken:
            "Google didn't return a long-lived token. Try disconnecting and reconnecting."
        case .notConnected:
            "Connect Google Drive in Settings first."
        case .requestFailed:
            "Google Drive request failed. Check your connection and try again."
        case .folderNotFound(let name):
            "No Drive folder named \"\(name)\" was found. Check the folder name in Settings."
        case .noExportFound:
            "No Instagram export zip was found in Google Drive. Make sure Instagram's scheduled export to Drive has run at least once."
        }
    }
}
