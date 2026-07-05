// OAuth 2.0 (PKCE + loopback) для Google Calendar API. Токены — в Keychain.
import AppKit
import CryptoKit
import Foundation
import Network
import Security

struct GoogleOAuthConfig: Codable {
    let client_id: String
    let client_secret: String

    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetRec/google_oauth.json")
    }

    static func load() -> GoogleOAuthConfig? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(GoogleOAuthConfig.self, from: data)
    }
}

struct OAuthTokens: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
}

final class GoogleAuth {
    static let shared = GoogleAuth()
    private let scope = "https://www.googleapis.com/auth/calendar.readonly"
    private let keychainService = "ru.dinya.meetrec.google"

    var isConnected: Bool {
        loadTokens() != nil && GoogleOAuthConfig.load() != nil
    }

    // MARK: - Подключение

    func connect() async throws {
        guard let config = GoogleOAuthConfig.load() else {
            throw MeetRecError("Нет файла google_oauth.json (Application Support/MeetRec). См. README.")
        }
        let verifier = Self.randomURLSafe(bytes: 48)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))

        let server = try LoopbackServer()
        defer { server.stop() }
        let port = try await server.start()
        let redirect = "http://127.0.0.1:\(port)"

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            .init(name: "client_id", value: config.client_id),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        await MainActor.run { NSWorkspace.shared.open(comps.url!) }

        // Ждём редиректа не дольше 5 минут.
        let code = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await server.waitForCode() }
            group.addTask {
                try await Task.sleep(nanoseconds: 300 * 1_000_000_000)
                throw MeetRecError("Время ожидания подтверждения истекло.")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }

        let tokens = try await exchangeCode(code, verifier: verifier, redirect: redirect, config: config)
        try saveTokens(tokens)
    }

    func disconnect() {
        deleteTokens()
    }

    /// Действующий access token; при необходимости обновляет его по refresh token.
    func validAccessToken() async throws -> String {
        guard var tokens = loadTokens(), let config = GoogleOAuthConfig.load() else {
            throw MeetRecError("Google Календарь не подключён.")
        }
        if Date() < tokens.expiresAt {
            return tokens.accessToken
        }
        let response = try await tokenRequest([
            "client_id": config.client_id,
            "client_secret": config.client_secret,
            "refresh_token": tokens.refreshToken,
            "grant_type": "refresh_token",
        ])
        tokens.accessToken = response.access_token
        tokens.expiresAt = Date().addingTimeInterval(TimeInterval(response.expires_in - 60))
        try saveTokens(tokens)
        return tokens.accessToken
    }

    // MARK: - Обмен кода и обновление

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int
    }

    private func exchangeCode(
        _ code: String, verifier: String, redirect: String, config: GoogleOAuthConfig
    ) async throws -> OAuthTokens {
        let response = try await tokenRequest([
            "code": code,
            "client_id": config.client_id,
            "client_secret": config.client_secret,
            "redirect_uri": redirect,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ])
        guard let refresh = response.refresh_token else {
            throw MeetRecError("Google не вернул refresh token — попробуйте подключить ещё раз.")
        }
        return OAuthTokens(
            accessToken: response.access_token,
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(TimeInterval(response.expires_in - 60)))
    }

    private func tokenRequest(_ params: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = params
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw MeetRecError("Ошибка авторизации Google: \(body.prefix(200))")
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    // MARK: - Keychain

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "oauth",
        ]
    }

    private func saveTokens(_ tokens: OAuthTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        SecItemDelete(baseQuery as CFDictionary)
        var add = baseQuery
        add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw MeetRecError("Не удалось сохранить токены в Keychain (код \(status)).")
        }
    }

    private func loadTokens() -> OAuthTokens? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(OAuthTokens.self, from: data)
    }

    private func deleteTokens() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    // MARK: - PKCE

    private static func randomURLSafe(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL<D: DataProtocol>(_ data: D) -> String {
        Data(data).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Мини-HTTP-сервер на 127.0.0.1 для приёма OAuth-редиректа.
private final class LoopbackServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "meetrec.oauth")
    private var codeContinuation: CheckedContinuation<String, Error>?

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            var resumed = false
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if !resumed, let port = self?.listener.port?.rawValue {
                        resumed = true
                        cont.resume(returning: port)
                    }
                case .failed(let error):
                    if !resumed {
                        resumed = true
                        cont.resume(throwing: error)
                    }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    func waitForCode() async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            queue.async { self.codeContinuation = cont }
        }
    }

    func stop() {
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var combined = buffer
            if let data { combined += data }
            if let text = String(data: combined, encoding: .utf8), text.contains("\r\n") {
                self.respond(connection, request: text)
            } else if error == nil, !isComplete, combined.count < 65_536 {
                self.receive(connection, buffer: combined)
            } else {
                connection.cancel()
            }
        }
    }

    private func respond(_ connection: NWConnection, request: String) {
        let firstLine = request.components(separatedBy: "\r\n")[0]
        let parts = firstLine.components(separatedBy: " ")
        var code: String?
        var oauthError: String?
        if parts.count >= 2, let comps = URLComponents(string: "http://127.0.0.1" + parts[1]) {
            code = comps.queryItems?.first { $0.name == "code" }?.value
            oauthError = comps.queryItems?.first { $0.name == "error" }?.value
        }

        // Посторонние запросы (например, favicon) — отвечаем и продолжаем ждать.
        guard code != nil || oauthError != nil else {
            send(connection, status: "404 Not Found", body: "")
            return
        }

        let message = code != nil
            ? "<h2>MeetRec подключён к Google Календарю</h2><p>Эту вкладку можно закрыть.</p>"
            : "<h2>Подключение не выполнено</h2><p>Вернитесь в MeetRec и попробуйте ещё раз.</p>"
        let body = "<html><head><meta charset='utf-8'><title>MeetRec</title></head>"
            + "<body style='font-family:-apple-system,sans-serif;text-align:center;padding-top:80px'>\(message)</body></html>"
        send(connection, status: "200 OK", body: body)

        if let cont = codeContinuation {
            codeContinuation = nil
            if let code {
                cont.resume(returning: code)
            } else {
                cont.resume(throwing: MeetRecError(
                    oauthError == "access_denied" ? "Доступ отклонён в браузере." : "Google вернул ошибку: \(oauthError ?? "?")"))
            }
        }
    }

    private func send(_ connection: NWConnection, status: String, body: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
