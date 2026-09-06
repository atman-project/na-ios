import Foundation

/// A conversation. Chats are independent of sub-apps — one chat can touch any
/// number of sub-apps; the sidebar exists purely for conversation hygiene.
struct Chat: Identifiable {
    let id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
}

/// A pending file/photo attachment, converted to Anthropic content blocks
/// on send. Images are pre-downscaled JPEG; text files carry their contents.
struct Attachment: Identifiable {
    enum Kind {
        case image
        case pdf
        case text(String)
    }

    let id = UUID()
    let filename: String
    let kind: Kind
    let data: Data

    func contentBlock() -> [String: Any] {
        switch kind {
        case .image:
            return [
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": data.base64EncodedString(),
                ],
            ]
        case .pdf:
            return [
                "type": "document",
                "source": [
                    "type": "base64",
                    "media_type": "application/pdf",
                    "data": data.base64EncodedString(),
                ],
            ]
        case .text(let content):
            return ["type": "text", "text": "Attached file \(filename):\n\n\(content)"]
        }
    }
}

@MainActor
final class ChatViewModel: ObservableObject {

    enum Item: Identifiable, Codable {
        case user(id: UUID, text: String)
        case assistant(id: UUID, text: String)
        // `detail` is optional so chats persisted before it existed still decode.
        case tool(id: UUID, name: String, summary: String, detail: String?, isError: Bool)
        case attachment(id: UUID, label: String)
        case error(id: UUID, text: String)

        var id: UUID {
            switch self {
            case .user(let id, _), .assistant(let id, _),
                 .tool(let id, _, _, _, _), .attachment(let id, _),
                 .error(let id, _):
                return id
            }
        }
    }

    @Published var items: [Item] = []
    @Published var isBusy = false
    @Published var busySince: Date?
    @Published var chats: [Chat] = []
    @Published var currentChatID: UUID?

    /// Full API conversation of the current chat (content blocks preserved
    /// verbatim so thinking and tool_use blocks round-trip unchanged).
    private var apiMessages: [[String: Any]] = []
    private var currentTask: Task<Void, Never>?

    private static let chatsDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Chats", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init() {
        loadChatIndex()
        if let latest = chats.first {
            openChat(latest.id)
        } else {
            newChat()
        }
    }

    // MARK: - Chat management

    func newChat() {
        stop()
        let chat = Chat(id: UUID(), title: "New Chat", createdAt: Date(), updatedAt: Date())
        chats.insert(chat, at: 0)
        currentChatID = chat.id
        items = []
        apiMessages = []
        persistCurrent()
    }

    func openChat(_ id: UUID) {
        stop()
        currentChatID = id
        items = []
        apiMessages = []
        guard let data = try? Data(contentsOf: Self.fileURL(id)),
              let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        apiMessages = doc["apiMessages"] as? [[String: Any]] ?? []
        if let itemsObj = doc["items"],
           let itemsData = try? JSONSerialization.data(withJSONObject: itemsObj),
           let decoded = try? JSONDecoder().decode([Item].self, from: itemsData) {
            items = decoded
        }
    }

    func renameChat(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = chats.firstIndex(where: { $0.id == id }) else { return }
        chats[index].title = trimmed
        patchFileTitle(id, title: trimmed)
    }

    func deleteChat(_ id: UUID) {
        if id == currentChatID { stop() }
        try? FileManager.default.removeItem(at: Self.fileURL(id))
        chats.removeAll { $0.id == id }
        if currentChatID == id {
            if let next = chats.first {
                openChat(next.id)
            } else {
                newChat()
            }
        }
    }

    // MARK: - Sending

    func send(_ text: String, attachments: [Attachment] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty, !isBusy else { return }
        currentTask = Task { await run(trimmed, attachments: attachments) }
    }

    func stop() {
        currentTask?.cancel()
    }

    private func run(_ text: String, attachments: [Attachment] = []) async {
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

        // If the user switches chats mid-run (stop + open), the cancelled task
        // must not write into the newly opened chat.
        let chatID = currentChatID

        for attachment in attachments {
            items.append(.attachment(id: UUID(), label: attachment.filename))
        }
        items.append(.user(id: UUID(), text: text.isEmpty ? "(attachment)" : text))
        if attachments.isEmpty {
            apiMessages.append(["role": "user", "content": text])
        } else {
            var blocks: [[String: Any]] = attachments.map { $0.contentBlock() }
            blocks.append(["type": "text", "text": text.isEmpty ? "See the attachment." : text])
            apiMessages.append(["role": "user", "content": blocks])
        }
        persistCurrent()

        let client = ClaudeClient(apiKey: apiKey)
        do {
            var iterations = 0
            while iterations < 25 {
                iterations += 1
                let response = try await client.createMessage(
                    system: AtmanTools.systemPrompt,
                    tools: AtmanTools.definitions,
                    messages: apiMessages)
                guard currentChatID == chatID else { return }

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
                            detail: Self.detailText(input: input),
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
            guard currentChatID == chatID else { return }
            items.append(.error(id: UUID(), text: "Stopped."))
        } catch let error as URLError where error.code == .cancelled {
            guard currentChatID == chatID else { return }
            items.append(.error(id: UUID(), text: "Stopped."))
        } catch {
            guard currentChatID == chatID else { return }
            items.append(.error(id: UUID(), text: error.localizedDescription))
        }
        persistCurrent()
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

    /// Full tool input for the detail sheet: SQL shown plainly when present,
    /// everything else as pretty-printed JSON.
    private static func detailText(input: [String: Any]) -> String {
        var parts: [String] = []
        if let sql = input["sql"] as? String {
            parts.append(sql)
        }
        let rest = input.filter { $0.key != "sql" }
        if !rest.isEmpty,
           let data = try? JSONSerialization.data(
               withJSONObject: rest, options: [.prettyPrinted, .sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            parts.append(json)
        }
        return parts.joined(separator: "\n\n")
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

    // MARK: - Persistence (one JSON file per chat, in Application Support)

    private static func fileURL(_ id: UUID) -> URL {
        chatsDir.appendingPathComponent(id.uuidString + ".json")
    }

    private func loadChatIndex() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.chatsDir, includingPropertiesForKeys: nil)) ?? []
        chats = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> Chat? in
                guard let data = try? Data(contentsOf: url),
                      let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let idString = doc["id"] as? String,
                      let id = UUID(uuidString: idString) else { return nil }
                return Chat(
                    id: id,
                    title: doc["title"] as? String ?? "Chat",
                    createdAt: Date(timeIntervalSince1970: doc["createdAt"] as? Double ?? 0),
                    updatedAt: Date(timeIntervalSince1970: doc["updatedAt"] as? Double ?? 0))
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func persistCurrent() {
        guard let id = currentChatID,
              let index = chats.firstIndex(where: { $0.id == id }) else { return }
        chats[index].updatedAt = Date()
        // Auto-title from the first user message, until the user renames.
        if chats[index].title == "New Chat" {
            for item in items {
                if case .user(_, let text) = item {
                    chats[index].title = String(text.prefix(40))
                    break
                }
            }
        }
        chats.sort { $0.updatedAt > $1.updatedAt }
        guard let chat = chats.first(where: { $0.id == id }) else { return }

        var doc: [String: Any] = [
            "id": id.uuidString,
            "title": chat.title,
            "createdAt": chat.createdAt.timeIntervalSince1970,
            "updatedAt": chat.updatedAt.timeIntervalSince1970,
            "apiMessages": apiMessages,
        ]
        if let itemsData = try? JSONEncoder().encode(items),
           let itemsObj = try? JSONSerialization.jsonObject(with: itemsData) {
            doc["items"] = itemsObj
        }
        if let data = try? JSONSerialization.data(withJSONObject: doc) {
            try? data.write(to: Self.fileURL(id), options: .atomic)
        }
    }

    private func patchFileTitle(_ id: UUID, title: String) {
        let url = Self.fileURL(id)
        guard let data = try? Data(contentsOf: url),
              var doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        doc["title"] = title
        if let out = try? JSONSerialization.data(withJSONObject: doc) {
            try? out.write(to: url, options: .atomic)
        }
    }
}
