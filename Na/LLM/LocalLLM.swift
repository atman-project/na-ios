import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// On-device Qwen3-4B via MLX. Downloads from Hugging Face on first load and
/// keeps one ChatSession per chat (KV cache reuse across turns). The tool
/// loop runs inside the library: it parses the model's tool calls and invokes
/// our `toolDispatch`, which executes against the embedded crrdb-mcp.
@MainActor
final class LocalLLM: ObservableObject {
    static let shared = LocalLLM()

    static let modelID = "mlx-community/Qwen3-4B-Instruct-2507-4bit"

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
        state = .loading(0)
        loadTask = Task {
            do {
                let container = try await #huggingFaceLoadModelContainer(
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
