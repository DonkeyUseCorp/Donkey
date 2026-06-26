import Foundation

/// Revokes every Better Auth session for the signed-in user by calling the web app's
/// `/api/auth/revoke-sessions` endpoint. This is what makes sign-out symmetric: signing
/// out in the app tears down the browser's session too, and vice versa. The browser's own
/// sign-out calls the same endpoint.
protocol DonkeyRemoteSessionRevoking: Sendable {
    /// Best-effort revoke of all sessions for the user authenticated by `cookies`.
    /// Never throws: a network failure must not block the local sign-out.
    func revokeAllSessions(webBaseURL: URL, cookies: [HTTPCookie]) async
}

struct DonkeyRemoteSessionRevoker: DonkeyRemoteSessionRevoking {
    var urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func revokeAllSessions(webBaseURL: URL, cookies: [HTTPCookie]) async {
        guard !cookies.isEmpty, let url = revokeURL(webBaseURL: webBaseURL) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Send the captured session cookie explicitly rather than leaning on shared cookie
        // storage: sign-out clears that storage immediately after spawning this call, so a
        // storage-backed request could race and go out with no cookie at all.
        request.httpShouldHandleCookies = false
        for (field, value) in HTTPCookie.requestHeaderFields(with: cookies) {
            request.setValue(value, forHTTPHeaderField: field)
        }

        // `/revoke-sessions` reads the user from the session cookie and takes no body. The
        // result doesn't matter to the caller — a dead cookie 401s, which is the same as
        // "already signed out everywhere".
        _ = try? await urlSession.data(for: request)
    }

    private func revokeURL(webBaseURL: URL) -> URL? {
        var components = URLComponents(url: webBaseURL, resolvingAgainstBaseURL: false)
        let basePath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        components?.path = "/" + [basePath, "api/auth/revoke-sessions"]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        components?.query = nil
        components?.fragment = nil
        return components?.url
    }
}
