import SwiftUI

struct ChatView: View {
    @StateObject private var model = ChatViewModel()
    @State private var draft = ""
    @State private var showSettings = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            if model.items.isEmpty {
                                emptyState
                            }
                            ForEach(model.items) { item in
                                row(for: item)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: model.items.count) {
                        if let last = model.items.last?.id {
                            withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                        }
                    }
                }
                inputBar
            }
            .navigationTitle("Atman")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { showSettings = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear", systemImage: "trash") { model.clearConversation() }
                        .disabled(model.items.isEmpty || model.isBusy)
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your data, by chatting.")
                .font(.headline)
            Text("Try: “Start tracking my car's fuel history” or “I filled up 43 liters for 68,000 won today”.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 32)
    }

    @ViewBuilder
    private func row(for item: ChatViewModel.Item) -> some View {
        switch item {
        case .user(_, let text):
            HStack {
                Spacer(minLength: 40)
                Text(text)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
            }
        case .assistant(_, let text):
            Text(Self.inlineMarkdown(text))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
                .textSelection(.enabled)
        case .tool(_, let name, let summary, let isError):
            HStack(spacing: 6) {
                Image(systemName: isError ? "exclamationmark.triangle" : "wrench.and.screwdriver")
                Text(name).fontWeight(.medium)
                if !summary.isEmpty {
                    Text(summary).lineLimit(1).foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .foregroundStyle(isError ? .red : .secondary)
            .padding(.leading, 4)
        case .error(_, let text):
            Text(text)
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
            if model.isBusy {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Working…")
                    if let since = model.busySince {
                        Text(since, style: .timer).monospacedDigit()
                    }
                    Spacer()
                    Button("Stop", systemImage: "stop.circle.fill") { model.stop() }
                        .labelStyle(.titleAndIcon)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.top, 8)
            }
            HStack(spacing: 8) {
                TextField("Tell Atman something…", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .focused($inputFocused)
                    .onSubmit(submit)
                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || model.isBusy)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    /// Native Text renders inline markdown only (bold, italic, links) — no
    /// tables or lists. The system prompt bans tables; here we just tidy the
    /// block-level leftovers so lines read cleanly.
    private static func inlineMarkdown(_ text: String) -> AttributedString {
        let tidied = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let l = String(line)
                if l.hasPrefix("- ") || l.hasPrefix("* ") {
                    return "•" + l.dropFirst(1)
                }
                return l
            }
            .joined(separator: "\n")
        return (try? AttributedString(
            markdown: tidied,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    private func submit() {
        model.send(draft)
        draft = ""
    }
}
