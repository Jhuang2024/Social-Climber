import Foundation
import AuthenticationServices
import CryptoKit
import UIKit

/// Optional, read-only Google Calendar integration: finds upcoming events
/// that mention known people so they can be turned into planned hangouts.
///
/// Bring-your-own OAuth client, same spirit as the BazaarLink AI key: you
/// create a free "iOS" OAuth Client ID in Google Cloud Console (Calendar
/// API enabled, bundle ID matching this app's) and paste it in Settings.
/// No client secret is needed: sign-in uses the standard PKCE flow for
/// native apps. Only a refresh token is stored, in the iOS Keychain;
/// nothing else about your Google account touches this device's disk.
@MainActor
@Observable
final class GoogleCalendarService: NSObject {
    static let shared = GoogleCalendarService()

    private static let scope = "https://www.googleapis.com/auth/calendar.readonly"
    private static let authEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    private static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    private static let clientIDDefaultsKey = "googleClientID"

    private(set) var isConnected: Bool
    private var accessToken: String?
    private var accessTokenExpiry: Date?
    private var activeSession: ASWebAuthenticationSession?

    override init() {
        isConnected = KeychainService.hasGoogleRefreshToken()
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
        guard let authURL = components.url else { throw GoogleCalendarError.invalidClientID }

        let callbackURL = try await runAuthSession(url: authURL, callbackScheme: scheme)
        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value else {
            throw GoogleCalendarError.authCanceled
        }

        let tokens = try await requestTokens(body: [
            "code": code,
            "client_id": clientID,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI,
        ])
        guard let refreshToken = tokens.refreshToken else {
            throw GoogleCalendarError.missingRefreshToken
        }
        try KeychainService.saveGoogleRefreshToken(refreshToken)
        accessToken = tokens.accessToken
        accessTokenExpiry = Date.now.addingTimeInterval(TimeInterval(tokens.expiresIn))
        isConnected = true
    }

    func disconnect() {
        try? KeychainService.saveGoogleRefreshToken("")
        accessToken = nil
        accessTokenExpiry = nil
        isConnected = false
    }

    // MARK: Events

    struct MatchedEvent: Identifiable {
        let id: String
        let title: String
        let date: Date
        let people: [Person]
    }

    /// Events in the next `days` days whose title or attendees mention a known person.
    /// Fails silently (returns `[]`) on any network/auth hiccup so the Upcoming
    /// feed never blocks on Google being unreachable.
    func upcomingEvents(matching people: [Person], days: Int = 30) async -> [MatchedEvent] {
        guard isConnected, let token = try? await validAccessToken() else { return [] }

        let start = Date.now
        guard let end = Calendar.current.date(byAdding: .day, value: days, to: start) else { return [] }

        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        let iso = ISO8601DateFormatter()
        components.queryItems = [
            URLQueryItem(name: "timeMin", value: iso.string(from: start)),
            URLQueryItem(name: "timeMax", value: iso.string(from: end)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: "250"),
        ]
        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(EventsResponse.self, from: data) else {
            return []
        }

        return decoded.items.compactMap { event -> MatchedEvent? in
            guard let date = event.startDate else { return nil }
            let haystack = (
                (event.summary ?? "") + " " +
                (event.attendees?.compactMap(\.displayName).joined(separator: " ") ?? "")
            ).lowercased()
            let matched = people.filter { person in
                !person.firstName.isEmpty && haystack.contains(person.firstName.lowercased())
            }
            guard !matched.isEmpty else { return nil }
            return MatchedEvent(id: event.id ?? UUID().uuidString, title: event.summary ?? "Event", date: date, people: matched)
        }
        .sorted { $0.date < $1.date }
    }

    // MARK: Tokens

    private func validAccessToken() async throws -> String {
        if let accessToken, let expiry = accessTokenExpiry, expiry > Date.now.addingTimeInterval(30) {
            return accessToken
        }
        guard let refreshToken = try KeychainService.googleRefreshToken(), !refreshToken.isEmpty else {
            throw GoogleCalendarError.notConnected
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
            throw GoogleCalendarError.tokenExchangeFailed
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private func clientIDOrThrow() throws -> String {
        let raw = UserDefaults.standard.string(forKey: Self.clientIDDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { throw GoogleCalendarError.missingClientID }
        guard let sanitized = Self.sanitizeClientID(raw) else { throw GoogleCalendarError.invalidClientID }
        return sanitized
    }

    /// Google Cloud Console sometimes renders the client ID as a clickable
    /// link, so pasting it can drag along a `http://` scheme and trailing
    /// `/` (e.g. `http://1234-abc.apps.googleusercontent.com/`). Left
    /// as-is, those stray characters end up inside the OAuth redirect
    /// scheme built from the client ID, which isn't a valid URL scheme.
    /// `ASWebAuthenticationSession` then throws an uncatchable
    /// Objective-C exception and crashes the app. Strip it down to the
    /// bare `<id>.apps.googleusercontent.com` before it's ever used.
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
                    continuation.resume(throwing: error ?? GoogleCalendarError.authCanceled)
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

    /// Google's iOS OAuth clients expect the redirect scheme to be the
    /// client ID's components in reverse-DNS order, e.g.
    /// `1234-abc.apps.googleusercontent.com` → `com.googleusercontent.apps.1234-abc`.
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

    private struct EventsResponse: Decodable {
        let items: [GoogleEvent]
    }

    private struct GoogleEvent: Decodable {
        let id: String?
        let summary: String?
        let start: EventDateTime?
        let attendees: [Attendee]?

        struct EventDateTime: Decodable {
            let date: String?
            let dateTime: String?
        }

        struct Attendee: Decodable {
            let displayName: String?
            let email: String?
        }

        var startDate: Date? {
            if let dateTime = start?.dateTime {
                return GoogleEvent.isoWithFractional.date(from: dateTime) ?? GoogleEvent.iso.date(from: dateTime)
            }
            if let date = start?.date {
                return GoogleEvent.dayFormatter.date(from: date)
            }
            return nil
        }

        private static let iso = ISO8601DateFormatter()
        private static let isoWithFractional: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()
        private static let dayFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            return formatter
        }()
    }
}

extension GoogleCalendarService: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        // A `UIWindow()` with no window scene attached crashes when
        // ASWebAuthenticationSession tries to present on it, so fall back
        // as far as "any window in any connected scene" before ever
        // constructing a scene-less window.
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

enum GoogleCalendarError: LocalizedError {
    case missingClientID
    case invalidClientID
    case authCanceled
    case tokenExchangeFailed
    case missingRefreshToken
    case notConnected

    var errorDescription: String? {
        switch self {
        case .missingClientID:
            "Add your Google OAuth Client ID in Settings first."
        case .invalidClientID:
            "That doesn't look like a Google Client ID. It should end in \".apps.googleusercontent.com\"."
        case .authCanceled:
            "Sign-in was canceled before it finished."
        case .tokenExchangeFailed:
            "Google didn't accept that sign-in. Double check the Client ID and try again."
        case .missingRefreshToken:
            "Google didn't return a long-lived token. Try disconnecting and reconnecting."
        case .notConnected:
            "Connect Google Calendar in Settings first."
        }
    }
}
