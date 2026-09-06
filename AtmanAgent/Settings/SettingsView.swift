import SwiftUI

struct SettingsView: View {
    @State private var apiKey = Keychain.loadAPIKey() ?? ""
    @State private var saved = false

    var body: some View {
        NavigationStack {
            Form {
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
                    Text("Stored in the Keychain. Chat runs on \(ClaudeClient.model), calling the API directly from this device.")
                }

                Section {
                    LabeledContent("Model", value: ClaudeClient.model)
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
}
