import Foundation

struct ClaudeAPIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Minimal raw-HTTP client for the Anthropic Messages API (there is no
/// official Swift SDK). The chat loop appends `content` blocks verbatim so
/// thinking blocks round-trip unchanged, as the API requires.
struct ClaudeClient {
    let apiKey: String
    static let model = "claude-opus-5"

    func createMessage(
        system: String, tools: [[String: Any]], messages: [[String: Any]]
    ) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        // Tool-use turns with adaptive thinking can run long.
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": 16000,
            "system": system,
            "tools": tools,
            "messages": messages,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClaudeAPIError(message: "no HTTP response")
        }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard http.statusCode == 200 else {
            let message = ((obj["error"] as? [String: Any])?["message"] as? String)
                ?? "HTTP \(http.statusCode)"
            throw ClaudeAPIError(message: message)
        }
        return obj
    }
}
