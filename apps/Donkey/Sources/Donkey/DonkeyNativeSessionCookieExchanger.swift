import Foundation

struct DonkeyNativeCookieSession: Equatable, Sendable {
    var sessionID: String
    var userEmail: String?
    var userName: String?
}

enum DonkeyNativeSessionCookieExchangeError: Error, Equatable {
    case invalidURL
    case invalidResponse
    case httpStatus(Int, String)
    case missingSessionCookie
}

protocol DonkeyNativeSessionExchanging: Sendable {
    func exchange(
        code: String,
        webBaseURL: URL
    ) async throws -> DonkeyNativeCookieSession
}

struct DonkeyNativeSessionCookieExchanger: DonkeyNativeSessionExchanging {
    var urlSession: URLSession
    var cookieStorage: HTTPCookieStorage

    init(
        urlSession: URLSession = .shared,
        cookieStorage: HTTPCookieStorage = .shared
    ) {
        self.urlSession = urlSession
        self.cookieStorage = cookieStorage
    }

    func exchange(
        code: String,
        webBaseURL: URL
    ) async throws -> DonkeyNativeCookieSession {
        guard let url = exchangeURL(webBaseURL: webBaseURL) else {
            throw DonkeyNativeSessionCookieExchangeError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = true
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(VerifyOneTimeTokenRequest(token: code))

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DonkeyNativeSessionCookieExchangeError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw DonkeyNativeSessionCookieExchangeError.httpStatus(
                httpResponse.statusCode,
                String(data: data, encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            )
        }

        storeCookies(from: httpResponse, for: url)
        guard hasStoredSessionCookie(for: webBaseURL) else {
            throw DonkeyNativeSessionCookieExchangeError.missingSessionCookie
        }

        return try JSONDecoder().decode(VerifyOneTimeTokenResponse.self, from: data).nativeSession
    }

    private func exchangeURL(webBaseURL: URL) -> URL? {
        var components = URLComponents(
            url: webBaseURL,
            resolvingAgainstBaseURL: false
        )
        let basePath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        components?.path = "/" + [basePath, "api/auth/one-time-token/verify"]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        components?.query = nil
        components?.fragment = nil
        return components?.url
    }

    private func storeCookies(
        from response: HTTPURLResponse,
        for url: URL
    ) {
        let headerFields = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            guard let key = pair.key as? String else { return }
            result[key] = String(describing: pair.value)
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
        for cookie in cookies {
            cookieStorage.setCookie(cookie)
        }
    }

    private func hasStoredSessionCookie(for webBaseURL: URL) -> Bool {
        cookieStorage.cookies(for: webBaseURL)?.contains { cookie in
            cookie.name.contains("session_token")
        } ?? false
    }
}

private struct VerifyOneTimeTokenRequest: Encodable {
    var token: String
}

private struct VerifyOneTimeTokenResponse: Decodable {
    var session: Session
    var user: User

    var nativeSession: DonkeyNativeCookieSession {
        DonkeyNativeCookieSession(
            sessionID: session.id,
            userEmail: user.email,
            userName: user.name
        )
    }

    struct Session: Decodable {
        var id: String
    }

    struct User: Decodable {
        var email: String?
        var name: String?
    }
}
