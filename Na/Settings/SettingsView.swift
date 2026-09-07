import SwiftUI

struct SettingsView: View {
    @State private var apiKey = Keychain.loadAPIKey() ?? ""
    @State private var saved = false
    @AppStorage("llm.backend") private var backend = "claude"
    @ObservedObject private var localLLM = LocalLLM.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Model", selection: $backend) {
                        Text("Claude API").tag("claude")
                        Text("On-device (Qwen3.5-4B)").tag("local")
                    }
                    // Switching backends mid-download would strand the download;
                    // cancel it first.
                    .disabled(isDownloading)
                    if backend == "local" {
                        localModelRow
                    }
                } header: {
                    Text("Backend")
                } footer: {
                    if backend == "local" {
                        Text("Runs entirely on this device via MLX. Needs an 8GB-RAM iPhone (15 Pro / 16 or newer); the iOS Simulator is not supported. First use downloads ~2.3 GB (Wi-Fi recommended).")
                    }
                }

                if backend == "claude" {
                    Section {
                        SecureField("sk-ant-…", text: $apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button(saved ? "Saved" : "Save") {
                            Keychain.saveAPIKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
                            saved = true
                            Task {
                                try? await Task.sleep(for: .seconds(1.5))
                                saved = false
                            }
                        }
                    } header: {
                        Text("Anthropic API Key")
                    } footer: {
                        Text("Stored in the Keychain. The Claude backend runs on \(ClaudeClient.model), calling the API directly from this device.")
                    }
                }

                Section {
                    LabeledContent("Database") {
                        Text(Crrdb.databaseURL.lastPathComponent)
                    }
                } header: {
                    Text("About")
                } footer: {
                    Text("The database lives in this app's Documents folder and is visible in the Files app. It is managed by the embedded crrdb-mcp library — the same code desktop agents use via MCP.")
                }
            }
            .navigationTitle("Settings")
        }
    }

    private static func gib(_ bytes: Int64) -> String {
        String(format: "%.2f", Double(bytes) / 1_073_741_824)
    }

    private var isDownloading: Bool {
        if case .loading = localLLM.state { return true }
        return false
    }

    @ViewBuilder
    private var localModelRow: some View {
        switch localLLM.state {
        case .idle:
            Button("Download & Load Model") {
                localLLM.load()
            }
        case .loading(let progress):
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(progress < 1 ? "Downloading…" : "Loading…")
                        Spacer()
                        if let bytes = localLLM.downloadBytes, bytes.total > 0, progress < 1 {
                            Text("\(Int(min(progress, 1) * 100))% · \(Self.gib(bytes.total)) GiB")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        } else {
                            Text(min(progress, 1), format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.footnote)
                    ProgressView(value: min(progress, 1))
                }
                Button("Cancel", role: .destructive) {
                    localLLM.cancelLoad()
                }
                .buttonStyle(.borderless)
            }
        case .ready:
            Label("Model ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Text("Failed: \(message)")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                Button("Retry") {
                    localLLM.load()
                }
            }
        }
    }
}
