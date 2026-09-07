import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// On-device Qwen3.5-2B via MLX. Downloads from Hugging Face on first load and
/// keeps one ChatSession per chat (KV cache reuse across turns). The tool
/// loop runs inside the library: it parses the model's tool calls and invokes
/// our `toolDispatch`, which executes against the embedded crrdb-mcp.
@MainActor
final class LocalLLM: ObservableObject {
    static let shared = LocalLLM()

    static let modelID = "mlx-community/Qwen3.5-2B-4bit"

    enum State: Equatable {
        case idle
        case loading(Double)
        case ready
        case failed(String)
    }

    @Published var state: State = .idle
    /// Download byte counts (completed, total) while `.loading`; the snapshot
    /// Progress units are file bytes (verified in swift-huggingface).
    @Published var downloadBytes: (completed: Int64, total: Int64)?

    private var container: ModelContainer?
    private var sessions: [UUID: ChatSession] = [:]
    private var loadTask: Task<Void, Never>?
    private var progressPoll: Task<Void, Never>?

    func load() {
        if container != nil {
            state = .ready
            return
        }
        guard loadTask == nil else { return }
        // Cap MLX's Metal buffer cache so freed evaluation buffers return to
        // the OS instead of accumulating on top of the resident weights —
        // jetsam kills us long before the device is actually out of memory.
        MLX.Memory.cacheLimit = 20 * 1024 * 1024
        state = .loading(0)
        loadTask = Task {
            do {
                // Patch before loading when the files are already cached, so
                // the reload below only ever happens right after the very
                // first download.
                _ = Self.patchChatTemplate()
                var container: ModelContainer? = try await #huggingFaceLoadModelContainer(
                    configuration: ModelConfiguration(id: Self.modelID),
                    progressHandler: { progress in
                        // The handler fires once with a live NSProgress whose
                        // children update it internally — observe it, don't
                        // wait for further callbacks.
                        Task { @MainActor in
                            LocalLLM.shared.observe(progress)
                        }
                    }
                )
                if Self.patchChatTemplate() {
                    // The tokenizer above read the unpatched template. Release
                    // the container first so the weights aren't resident twice,
                    // then reload from the (now patched) cache — no download.
                    container = nil
                    container = try await #huggingFaceLoadModelContainer(
                        configuration: ModelConfiguration(id: Self.modelID))
                }
                self.stopProgressPoll()
                self.container = container
                self.state = .ready
                self.downloadBytes = nil
            } catch is CancellationError {
                self.stopProgressPoll()
                self.state = .idle
                self.downloadBytes = nil
            } catch {
                self.stopProgressPoll()
                self.state = Task.isCancelled ? .idle : .failed("\(error)")
                self.downloadBytes = nil
            }
            self.loadTask = nil
        }
    }

    /// Qwen3.5's chat template raises "No user query found in messages." on
    /// renders it considers tool-only continuations — an ecosystem-wide issue
    /// (Ollama, vLLM, LM Studio all hit it) that LM Studio fixes by editing
    /// the template. Neutralize the raise in the cached snapshot; returns
    /// true when a file was actually modified.
    private static func patchChatTemplate() -> Bool {
        guard let repo = Repo.ID(rawValue: modelID) else { return false }
        let snapshots = HubCache().snapshotsDirectory(repo: repo, kind: .model)
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil)
        else { return false }
        let needle = "raise_exception('No user query found in messages.')"
        var patched = false
        for dir in dirs {
            let file = dir.appendingPathComponent("chat_template.jinja")
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  text.contains(needle) else { continue }
            let fixed = text.replacingOccurrences(of: needle, with: "''")
            // The snapshot entry is a symlink into blobs/ — replace it with a
            // real file so the blob stays pristine.
            try? fm.removeItem(at: file)
            if (try? fixed.write(to: file, atomically: true, encoding: .utf8)) != nil {
                patched = true
            }
        }
        return patched
    }

    private func observe(_ progress: Progress) {
        guard loadTask != nil else { return }
        progressPoll?.cancel()
        progressPoll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.loadTask != nil else { break }
                self.state = .loading(progress.fractionCompleted)
                self.downloadBytes = (progress.completedUnitCount, progress.totalUnitCount)
                if progress.fractionCompleted >= 1 { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func stopProgressPoll() {
        progressPoll?.cancel()
        progressPoll = nil
    }

    func cancelLoad() {
        stopProgressPoll()
        loadTask?.cancel()
        loadTask = nil
        state = .idle
        downloadBytes = nil
    }

    func session(
        for chatID: UUID,
        toolDispatch: @Sendable @escaping (ToolCall) async throws -> String
    ) -> ChatSession? {
        guard let container else { return nil }
        if let existing = sessions[chatID] {
            return existing
        }
        var parameters = GenerateParameters()
        parameters.temperature = 0.2
        let session = ChatSession(
            container,
            instructions: AtmanTools.localSystemPrompt,
            generateParameters: parameters,
            tools: AtmanTools.toolSpecs,
            toolDispatch: toolDispatch)
        sessions[chatID] = session
        return session
    }

    func dropSession(for chatID: UUID) {
        sessions[chatID] = nil
    }
}
