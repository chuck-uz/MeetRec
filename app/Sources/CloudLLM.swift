// Внешние модели по API-ключу: Claude, OpenAI, DeepSeek, OpenRouter.
// Альтернатива локальной llama-server: текст встречи уходит выбранному провайдеру.
// Ключи хранятся в Keychain, в настройках и логах их нет.
import Foundation
import Security

enum CloudProvider: String, CaseIterable, Identifiable, Sendable {
    case anthropic, openai, deepseek, openrouter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .anthropic: "Claude"
        case .openai: "OpenAI"
        case .deepseek: "DeepSeek"
        case .openrouter: "OpenRouter"
        }
    }

    /// Кому уходит текст — для предупреждения в настройках.
    var company: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openai: "OpenAI"
        case .deepseek: "DeepSeek"
        case .openrouter: "OpenRouter и выбранному там поставщику модели"
        }
    }

    var endpoint: URL {
        switch self {
        case .anthropic: URL(string: "https://api.anthropic.com/v1/messages")!
        case .openai: URL(string: "https://api.openai.com/v1/chat/completions")!
        case .deepseek: URL(string: "https://api.deepseek.com/chat/completions")!
        case .openrouter: URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        }
    }

    /// Где получить ключ.
    var keysPage: URL {
        switch self {
        case .anthropic: URL(string: "https://platform.claude.com/settings/keys")!
        case .openai: URL(string: "https://platform.openai.com/api-keys")!
        case .deepseek: URL(string: "https://platform.deepseek.com/api_keys")!
        case .openrouter: URL(string: "https://openrouter.ai/keys")!
        }
    }

    /// Подсказки для поля «Модель»; первая — по умолчанию. Можно вписать любую другую.
    var models: [String] {
        switch self {
        case .anthropic: ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]
        case .openai: ["gpt-5-mini", "gpt-5"]
        case .deepseek: ["deepseek-chat", "deepseek-reasoner"]
        case .openrouter: ["anthropic/claude-sonnet-4.5", "openai/gpt-5-mini", "deepseek/deepseek-chat"]
        }
    }

    var model: String {
        get {
            let saved = UserDefaults.standard.string(forKey: "cloudModel.\(rawValue)") ?? ""
            return saved.isEmpty ? models[0] : saved
        }
        nonmutating set {
            UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespaces), forKey: "cloudModel.\(rawValue)")
        }
    }

    // MARK: - Ключ в Keychain

    private var keychainQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "io.github.chuckuz.meetrec.llm",
            kSecAttrAccount as String: rawValue,
        ]
    }

    var apiKey: String? {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    var hasKey: Bool {
        SecItemCopyMatching(keychainQuery as CFDictionary, nil) == errSecSuccess
    }

    /// Пустая строка удаляет ключ.
    func setKey(_ key: String) throws {
        SecItemDelete(keychainQuery as CFDictionary)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var add = keychainQuery
        add[kSecValueData as String] = Data(trimmed.utf8)
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw MeetRecError("Не удалось сохранить ключ в Keychain (код \(status)).")
        }
    }
}

/// Единая точка вызова модели: локальная llama-server или внешний провайдер.
enum LLM {
    static let backendKey = "llmBackend"

    /// nil — локальная модель.
    static var provider: CloudProvider? {
        UserDefaults.standard.string(forKey: backendKey).flatMap(CloudProvider.init(rawValue:))
    }

    /// Итоги и чат доступны: либо хватает памяти для локальной модели, либо выбран провайдер с ключом.
    static var available: Bool {
        if let provider { return provider.hasKey }
        return Hardware.supportsChat
    }

    /// Модель готова отвечать сразу (для живого перевода субтитров — без скачиваний посреди встречи).
    static var ready: Bool {
        if let provider { return provider.hasKey }
        return Hardware.supportsChat && LLMRuntime.serverBinary() != nil
            && FileManager.default.fileExists(atPath: LLMRuntime.modelURL.path)
    }

    static var title: String {
        provider.map { "\($0.title) · \($0.model)" } ?? LLMSpec.current.title
    }

    /// Подпись под чатом: куда уходит текст.
    static var privacyNote: String {
        if let provider { return "\(title) · текст встречи отправляется в \(provider.company)" }
        return "\(title) · локально, данные не покидают Mac"
    }

    static func generate(
        turns: [ChatTurn],
        temperature: Double = 0.3,
        maxTokens: Int = 2048,
        onToken: @escaping @Sendable (String) -> Void,
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws {
        if let provider {
            try await CloudLLM.generate(provider: provider, turns: turns, temperature: temperature,
                                        maxTokens: maxTokens, onToken: onToken, onStatus: onStatus)
        } else {
            try await LLMRuntime.shared.generate(turns: turns, temperature: temperature, maxTokens: maxTokens,
                                                 onToken: onToken, onStatus: onStatus)
        }
    }

    static func complete(
        turns: [ChatTurn],
        temperature: Double = 0.3,
        maxTokens: Int = 2048,
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        if let provider {
            return try await CloudLLM.complete(provider: provider, turns: turns,
                                               temperature: temperature, maxTokens: maxTokens, onStatus: onStatus)
        }
        return try await LLMRuntime.shared.complete(turns: turns, temperature: temperature,
                                                    maxTokens: maxTokens, onStatus: onStatus)
    }
}

enum CloudLLM {
    private final class Buffer: @unchecked Sendable { var text = "" }

    static func complete(
        provider: CloudProvider, turns: [ChatTurn], temperature: Double, maxTokens: Int,
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let buffer = Buffer()
        try await generate(provider: provider, turns: turns, temperature: temperature, maxTokens: maxTokens,
                           onToken: { buffer.text += $0 }, onStatus: onStatus)
        return buffer.text
    }

    /// Короткий запрос: проверяет и ключ, и название модели.
    static func check(_ provider: CloudProvider) async throws {
        let reply = try await complete(
            provider: provider, turns: [ChatTurn(role: .user, text: "Ответь одним словом: готов?")],
            temperature: 0, maxTokens: 16, onStatus: { _ in })
        if reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw MeetRecError("\(provider.title) принял запрос, но вернул пустой ответ. Попробуйте другую модель.")
        }
    }

    static func generate(
        provider: CloudProvider, turns: [ChatTurn], temperature: Double, maxTokens: Int,
        onToken: @escaping @Sendable (String) -> Void,
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws {
        guard let key = provider.apiKey else {
            if provider.hasKey {
                throw MeetRecError("Не удалось прочитать ключ \(provider.title) из Связки ключей. Разрешите MeetRec доступ в появившемся окне macOS или сохраните ключ заново.")
            }
            throw MeetRecError("Не задан API-ключ \(provider.title). Добавьте его в «Настройки» → «Модель ИИ».")
        }
        onStatus("\(provider.title) думает…")
        var request = URLRequest(url: provider.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let model = provider.model
        let anthropic = provider == .anthropic
        var body: [String: Any] = ["model": model, "stream": true]

        if anthropic {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
            // Системные реплики — отдельным полем; temperature в этой версии API не принимается.
            let system = turns.filter { $0.role == .system }.map(\.text).joined(separator: "\n\n")
            if !system.isEmpty { body["system"] = system }
            body["messages"] = turns.filter { $0.role != .system }
                .map { ["role": $0.role.rawValue, "content": $0.text] }
            // Рассуждения модели входят в max_tokens, поэтому лимит с запасом:
            // длину ответа задаёт промпт.
            body["max_tokens"] = max(maxTokens, 16000)
            // Короткие задачи (перевод реплики) — с минимальными рассуждениями, чтобы не ждать.
            if maxTokens <= 512 { body["output_config"] = ["effort": "low"] }
            // Если модель отклонит запрос, API сам повторит его на запасной модели.
            if ["claude-opus-5-5", "claude-sonnet-5-5", "claude-fable-5-2"].contains(model) {
                request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
                body["fallbacks"] = "default"
            }
        } else {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            body["messages"] = turns.map { ["role": $0.role.rawValue, "content": $0.text] }
            // Модели OpenAI с рассуждениями не принимают temperature и max_tokens —
            // оставляем их значения по умолчанию.
            if provider != .openai {
                body["temperature"] = temperature
                // У моделей с рассуждениями (deepseek-reasoner и подобных) размышления входят
                // в лимит: при малом лимите на сам ответ ничего не остаётся. Длину задаёт промпт.
                body["max_tokens"] = max(maxTokens, 4096)
            }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var data = Data()
            for try await byte in bytes.prefix(4000) { data.append(byte) }
            throw failure(provider: provider, model: model, status: status, body: data)
        }

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" || Task.isCancelled { break }
            guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
            else { continue }
            if let error = object["error"] as? [String: Any] {
                throw MeetRecError("\(provider.title): \(error["message"] as? String ?? "ошибка во время ответа")")
            }
            if anthropic {
                let delta = object["delta"] as? [String: Any]
                switch object["type"] as? String {
                case "content_block_delta":
                    if delta?["type"] as? String == "text_delta", let text = delta?["text"] as? String, !text.isEmpty {
                        onToken(text)
                    }
                case "message_delta":
                    if delta?["stop_reason"] as? String == "refusal" {
                        throw MeetRecError("Claude отказался отвечать на этот запрос. Попробуйте переформулировать или выбрать другую модель.")
                    }
                default:
                    break
                }
            } else if let choice = (object["choices"] as? [[String: Any]])?.first,
                      let text = (choice["delta"] as? [String: Any])?["content"] as? String, !text.isEmpty {
                onToken(text)
            }
        }
    }

    private static func failure(provider: CloudProvider, model: String, status: Int, body: Data) -> MeetRecError {
        let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        let detail = ((object?["error"] as? [String: Any])?["message"] as? String)
            ?? (object?["message"] as? String) ?? ""
        Log.error("\(provider.title) (\(model)): HTTP \(status) \(detail)")
        let reason: String
        switch status {
        case 401, 403: reason = "ключ не принят. Проверьте его в «Настройки» → «Модель ИИ»."
        case 402: reason = "на счёте не хватает средств."
        case 404: reason = "модель «\(model)» не найдена. Проверьте название."
        case 429: reason = "превышен лимит запросов или закончился баланс. Попробуйте позже."
        case 500...: reason = "сервис временно недоступен. Попробуйте позже."
        default: reason = "запрос отклонён (код \(status))."
        }
        return MeetRecError("\(provider.title): \(reason)" + (detail.isEmpty ? "" : " \(detail)"))
    }
}
