import Foundation

@MainActor
final class ChatViewModel: ObservableObject {

    enum Item: Identifiable {
        case user(id: UUID, text: String)
        case assistant(id: UUID, text: String)
        case tool(id: UUID, name: String, summary: String, isError: Bool)
        case error(id: UUID, text: String)

        var id: UUID {
            switch self {
            case .user(let id, _), .assistant(let id, _),
                 .tool(let id, _, _, _), .error(let id, _):
                return id
            }
        }
    }

    @Published var items: [Item] = []
    @Published var isBusy = false
    @Published var busySince: Date?

    private var currentTask: Task<Void, Never>?

    /// Full API conversation (content blocks preserved verbatim so thinking
    /// and tool_use blocks round-trip unchanged). In-memory for now; the data
    /// itself always lives in SQLite.
    private var apiMessages: [[String: Any]] = []

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isBusy else { return }
        currentTask = Task { await run(trimmed) }
    }

    func stop() {
        currentTask?.cancel()
    }

    func clearConversation() {
        items.removeAll()
        apiMessages.removeAll()
    }

    private func run(_ text: String) async {
        guard let apiKey = Keychain.loadAPIKey(), !apiKey.isEmpty else {
            items.append(.error(id: UUID(), text: "Set your Anthropic API key in Settings first."))
            return
        }
        isBusy = true
        busySince = Date()
        defer {
            isBusy = false
            busySince = nil
            currentTask = nil
        }

        items.append(.user(id: UUID(), text: text))
        apiMessages.append(["role": "user", "content": text])

        let client = ClaudeClient(apiKey: apiKey)
        do {
            var iterations = 0
            while iterations < 25 {
                iterations += 1
                let response = try await client.createMessage(
                    system: AtmanTools.systemPrompt,
                    tools: AtmanTools.definitions,
                    messages: apiMessages)

                let content = response["content"] as? [[String: Any]] ?? []
                apiMessages.append(["role": "assistant", "content": content])

                for block in content where (block["type"] as? String) == "text" {
                    if let t = block["text"] as? String,
                       !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        items.append(.assistant(id: UUID(), text: t))
                    }
                }

                let stopReason = response["stop_reason"] as? String
                if stopReason == "tool_use" {
                    var results: [[String: Any]] = []
                    for block in content where (block["type"] as? String) == "tool_use" {
                        let name = block["name"] as? String ?? ""
                        let input = block["input"] as? [String: Any] ?? [:]
                        let (json, isError) = Self.executeTool(name: name, input: input)
                        items.append(.tool(
                            id: UUID(), name: name,
                            summary: Self.summary(name: name, input: input),
                            isError: isError))
                        var result: [String: Any] = [
                            "type": "tool_result",
                            "tool_use_id": block["id"] as? String ?? "",
                            "content": json,
                        ]
                        if isError { result["is_error"] = true }
                        results.append(result)
                    }
                    apiMessages.append(["role": "user", "content": results])
                    continue
                }
                if stopReason == "refusal" {
                    items.append(.error(id: UUID(), text: "The model declined this request."))
                } else if stopReason == "max_tokens" {
                    items.append(.error(id: UUID(), text: "Response hit the output limit — ask it to continue."))
                }
                break
            }
        } catch is CancellationError {
            items.append(.error(id: UUID(), text: "Stopped."))
        } catch let error as URLError where error.code == .cancelled {
            items.append(.error(id: UUID(), text: "Stopped."))
        } catch {
            items.append(.error(id: UUID(), text: error.localizedDescription))
        }
    }

    /// Hand the tool call to the embedded crrdb-mcp library (same code the
    /// desktop MCP server runs) and return its JSON result verbatim.
    private static func executeTool(name: String, input: [String: Any]) -> (json: String, isError: Bool) {
        let inputJSON = (try? JSONSerialization.data(withJSONObject: input))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        do {
            let output = try Crrdb.shared.executeTool(name: name, inputJson: inputJSON)
            return (output.json, output.isError)
        } catch {
            return ("{\"error\": {\"kind\": \"ffi\", \"message\": \"\(error)\"}}", true)
        }
    }

    private static func summary(name: String, input: [String: Any]) -> String {
        switch name {
        case "query", "create_table", "alter_table":
            let sql = (input["sql"] as? String ?? "").replacingOccurrences(of: "\n", with: " ")
            return String(sql.prefix(120))
        case "sample_rows":
            return input["table"] as? String ?? ""
        case "commit_records":
            let n = (input["records"] as? [Any])?.count ?? 0
            return "\(n) record\(n == 1 ? "" : "s")"
        case "update_records", "delete_records":
            return input["table"] as? String ?? ""
        default:
            return ""
        }
    }
}
