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
        let relativePath: String

        var isFolder: Bool { mimeType == "application/vnd.google-apps.folder" }
        var isZip: Bool {
            mimeType == "application/zip" || mimeType == "application/x-zip-compressed"
                || name.lowercased().hasSuffix(".zip")
        }

        func located(at relativePath: String) -> DriveFile {
            DriveFile(
                id: id,
                name: name,
                mimeType: mimeType,
                modifiedTime: modifiedTime,
                size: size,
                relativePath: relativePath
            )
        }
    }

    struct InstagramExportSource {
        let archives: [DriveFile]
        let looseFiles: [DriveFile]

        var isEmpty: Bool { archives.isEmpty && looseFiles.isEmpty }
    }

    /// Finds the latest Instagram export in either format Google Drive may
    /// receive from Meta: one or more zip archives, or an expanded folder
    /// tree containing the JSON files directly.
    func latestInstagramExport(folderName: String) async throws -> InstagramExportSource {
        let trimmedName = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            guard let folder = try await findFolder(named: trimmedName) else {
                throw GoogleDriveError.folderNotFound(trimmedName)
            }
            return try await exportSource(in: folder)
        }

        let candidates = try await listFiles(
            query: "(name contains 'instagram' or name contains 'meta') and trashed = false"
        )
        let archives = groupedArchives(from: candidates.filter { $0.isZip })
        if !archives.isEmpty {
            return InstagramExportSource(archives: archives, looseFiles: [])
        }

        // Meta can deliver an already-expanded directory instead of a zip.
        // With no explicit folder name, use the newest matching folder.
        if let folder = candidates
            .filter(\.isFolder)
            .sorted { ($0.modifiedTime ?? .distantPast) > ($1.modifiedTime ?? .distantPast) }
            .first {
            return try await exportSource(in: folder)
        }
        return InstagramExportSource(archives: [], looseFiles: [])
    }

    private func exportSource(in rootFolder: DriveFile) async throws -> InstagramExportSource {
        let descendants = try await relevantDescendants(in: rootFolder)
        let archives = groupedArchives(from: descendants.filter { $0.isZip })
        if !archives.isEmpty {
            return InstagramExportSource(archives: archives, looseFiles: [])
        }
        return InstagramExportSource(
            archives: [],
            looseFiles: descendants.filter { InstagramExportParser.isRelevantEntry($0.relativePath) }
        )
    }

    /// Recursively walks an expanded Meta export. Drive folders are not
    /// downloadable objects, so every relevant JSON file must be discovered
    /// and downloaded individually. Only relevant JSON and zip files are
    /// retained, keeping unrelated photos and media out of memory and disk.
    private func relevantDescendants(in rootFolder: DriveFile) async throws -> [DriveFile] {
        var queue: [(folderID: String, path: String)] = [(rootFolder.id, "")]
        var queueIndex = 0
        var visitedFolderIDs: Set<String> = []
        var results: [DriveFile] = []

        while queueIndex < queue.count {
            let next = queue[queueIndex]
            queueIndex += 1
            guard visitedFolderIDs.insert(next.folderID).inserted else { continue }
            let children = try await listFiles(
                query: "'\(next.folderID)' in parents and trashed = false"
            )
            for child in children {
                let path = next.path.isEmpty ? child.name : "\(next.path)/\(child.name)"
                let located = child.located(at: path)
                if child.isFolder {
                    queue.append((child.id, path))
                } else if child.isZip || InstagramExportParser.isRelevantEntry(path) {
                    results.append(located)
                }
            }
        }
        return results
    }

    private func groupedArchives(from candidates: [DriveFile]) -> [DriveFile] {
        let candidates = candidates.sorted {
            ($0.modifiedTime ?? .distantPast) > ($1.modifiedTime ?? .distantPast)
        }
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
        var files: [DriveFile] = []
        var pageToken: String?
        repeat {
            var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
            var queryItems = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "fields", value: "nextPageToken,files(id,name,mimeType,modifiedTime,size)"),
                URLQueryItem(name: "pageSize", value: "1000"),
                URLQueryItem(name: "orderBy", value: "modifiedTime desc"),
            ]
            if let pageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            components.queryItems = queryItems
            guard let url = components.url else { throw GoogleDriveError.requestFailed }

            let (data, _) = try await authorizedData(operation: "list files") { token in
                var request = URLRequest(url: url)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                return request
            }
            do {
                let decoded = try JSONDecoder().decode(FileListResponse.self, from: data)
                files.append(contentsOf: decoded.files.map { $0.asDriveFile })
                pageToken = decoded.nextPageToken
            } catch {
                throw GoogleDriveError.invalidResponse(operation: "list files", detail: error.localizedDescription)
            }
        } while pageToken != nil
        return files
    }

    /// Downloads either a zip or one JSON file from an expanded export.
    /// The caller is responsible for deleting the returned temporary file.
    func downloadToTemporaryFile(fileID: String, filename: String) async throws -> URL {
        guard var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(fileID)") else {
            throw GoogleDriveError.requestFailed
        }
        components.queryItems = [URLQueryItem(name: "alt", value: "media")]
        guard let url = components.url else { throw GoogleDriveError.requestFailed }

        let tempURL = try await authorizedDownload(operation: "download export") { token in
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return request
        }
        // Move it out of URLSession's temp location so it survives until the
        // caller is finished with it.
        let fileExtension = (filename as NSString).pathExtension
        let suffix = fileExtension.isEmpty ? "" : ".\(fileExtension)"
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("ig-export-\(UUID().uuidString)\(suffix)")
        try FileManager.default.moveItem(at: tempURL, to: destination)
        return destination
    }

    /// Performs an authenticated Drive request and retries once after a 401.
    /// A refresh token in Keychain only proves that OAuth completed; it does
    /// not prove that the Drive API is enabled or that the granted token still
    /// has the Drive scope. Preserve Google's response so Settings can report
    /// the actual configuration or authorization failure.
    private func authorizedData(
        operation: String,
        request: (String) -> URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        for attempt in 0...1 {
            let token = try await validAccessToken()
            do {
                let (data, response) = try await URLSession.shared.data(for: request(token))
                guard let http = response as? HTTPURLResponse else {
                    throw GoogleDriveError.invalidResponse(operation: operation, detail: "No HTTP response")
                }
                if (200..<300).contains(http.statusCode) { return (data, http) }
                if http.statusCode == 401, attempt == 0 {
                    clearCachedAccessToken()
                    continue
                }
                throw Self.apiError(operation: operation, statusCode: http.statusCode, data: data)
            } catch let error as GoogleDriveError {
                throw error
            } catch {
                throw GoogleDriveError.transport(operation: operation, detail: error.localizedDescription)
            }
        }
        throw GoogleDriveError.requestFailed
    }

    private func authorizedDownload(
        operation: String,
        request: (String) -> URLRequest
    ) async throws -> URL {
        for attempt in 0...1 {
            let token = try await validAccessToken()
            do {
                let (temporaryURL, response) = try await URLSession.shared.download(for: request(token))
                guard let http = response as? HTTPURLResponse else {
                    try? FileManager.default.removeItem(at: temporaryURL)
                    throw GoogleDriveError.invalidResponse(operation: operation, detail: "No HTTP response")
                }
                if (200..<300).contains(http.statusCode) { return temporaryURL }

                let data = (try? Data(contentsOf: temporaryURL)) ?? Data()
                try? FileManager.default.removeItem(at: temporaryURL)
                if http.statusCode == 401, attempt == 0 {
                    clearCachedAccessToken()
                    continue
                }
                throw Self.apiError(operation: operation, statusCode: http.statusCode, data: data)
            } catch let error as GoogleDriveError {
                throw error
            } catch {
                throw GoogleDriveError.transport(operation: operation, detail: error.localizedDescription)
            }
        }
        throw GoogleDriveError.requestFailed
    }

    private func clearCachedAccessToken() {
        accessToken = nil
        accessTokenExpiry = nil
    }

    nonisolated static func apiError(operation: String, statusCode: Int, data: Data) -> GoogleDriveError {
        let payload = try? JSONDecoder().decode(GoogleAPIErrorEnvelope.self, from: data)
        let reason = payload?.error.errors?.first?.reason
        let message = payload?.error.message
        return .apiRejected(
            operation: operation,
            statusCode: statusCode,
            reason: reason,
            message: message
        )
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
        let nextPageToken: String?
    }

    private struct GoogleAPIErrorEnvelope: Decodable {
        let error: GoogleAPIErrorBody
    }

    private struct GoogleAPIErrorBody: Decodable {
        let message: String?
        let errors: [GoogleAPIErrorItem]?
    }

    private struct GoogleAPIErrorItem: Decodable {
        let reason: String?
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
                size: size.flatMap { Int64($0) },
                relativePath: name
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
    case transport(operation: String, detail: String)
    case invalidResponse(operation: String, detail: String)
    case apiRejected(operation: String, statusCode: Int, reason: String?, message: String?)
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
        case .transport(let operation, let detail):
            "Google Drive could not \(operation): \(detail)"
        case .invalidResponse(let operation, let detail):
            "Google Drive returned an unreadable response while trying to \(operation): \(detail)"
        case .apiRejected(let operation, let statusCode, let reason, let message):
            Self.apiRejectionDescription(
                operation: operation,
                statusCode: statusCode,
                reason: reason,
                message: message
            )
        case .folderNotFound(let name):
            "No Drive folder named \"\(name)\" was found. Check the folder name in Settings."
        case .noExportFound:
            "No Instagram export data was found in Google Drive. The selected folder must contain either Meta's export zip or its expanded JSON folder tree."
        }
    }

    private static func apiRejectionDescription(
        operation: String,
        statusCode: Int,
        reason: String?,
        message: String?
    ) -> String {
        switch (statusCode, reason) {
        case (401, _), (_, "authError"), (_, "invalidCredentials"):
            return "Google Drive authorization expired or was revoked. Disconnect Google Drive, reconnect it, then sync again."
        case (403, "accessNotConfigured"), (403, "serviceDisabled"):
            return "Google Drive is authorized, but the Google Drive API is disabled for this OAuth project. Enable the Google Drive API in Google Cloud Console, wait a minute, then sync again."
        case (403, "insufficientPermissions"), (403, "insufficient_scope"):
            return "Google Drive is connected without read permission. Disconnect Google Drive and reconnect it to grant the Drive read-only scope."
        case (403, "rateLimitExceeded"), (403, "userRateLimitExceeded"):
            return "Google Drive's request limit was reached. Wait briefly, then sync again."
        case (404, _):
            return "Google Drive could not find the export while trying to \(operation). It may have been moved or deleted."
        default:
            let diagnosticReason = reason.map { " [\($0)]" } ?? ""
            let diagnosticMessage = message?.trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = diagnosticMessage.flatMap { $0.isEmpty ? nil : ": \($0)" } ?? ""
            return "Google Drive rejected \(operation) (HTTP \(statusCode))\(diagnosticReason)\(suffix)"
        }
    }
}
