import SwiftUI

struct ChatView: View {
    @StateObject private var model = ChatViewModel()
    @State private var draft = ""
    @State private var showSettings = false
    @State private var showSidebar = false
    @State private var renameTarget: Chat?
    @State private var renameText = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            NavigationStack {
                VStack(spacing: 0) {
                    transcript
                    inputBar
                }
                .navigationTitle("Atman")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Chats", systemImage: "line.3.horizontal") {
                            inputFocused = false
                            withAnimation { showSidebar = true }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Settings", systemImage: "gearshape") { showSettings = true }
                    }
                }
            }

            if showSidebar {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation { showSidebar = false } }
                sidebar
                    .transition(.move(edge: .leading))
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .alert("Rename Chat", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Title", text: $renameText)
            Button("Save") {
                if let target = renameTarget {
                    model.renameChat(target.id, to: renameText)
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                model.newChat()
                withAnimation { showSidebar = false }
            } label: {
                Label("New Chat", systemImage: "square.and.pencil")
                    .font(.headline)
            }
            .padding()

            Divider()

            List {
                ForEach(model.chats) { chat in
                    Button {
                        if chat.id != model.currentChatID {
                            model.openChat(chat.id)
                        }
                        withAnimation { showSidebar = false }
                    } label: {
                        Text(chat.title)
                            .lineLimit(1)
                            .fontWeight(chat.id == model.currentChatID ? .semibold : .regular)
                    }
                    .contextMenu {
                        Button("Rename", systemImage: "pencil") {
                            renameText = chat.title
                            renameTarget = chat
                        }
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            model.deleteChat(chat.id)
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
        .frame(width: 290)
        .frame(maxHeight: .infinity)
        .background(Color(.systemBackground).ignoresSafeArea())
    }

    // MARK: - Transcript

    private var transcript: some View {
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

    /// Native Text renders inline markdown only (bold, italic, links) — no
    /// tables or lists. The system prompt steers away from wide tables; here
    /// we just tidy the block-level leftovers so lines read cleanly.
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

    // MARK: - Input

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

    private func submit() {
        model.send(draft)
        draft = ""
    }
}
