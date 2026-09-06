import SwiftUI
import UIKit

struct ChatView: View {
    @StateObject private var model = ChatViewModel()
    @State private var draft = ""
    @State private var showSettings = false
    @State private var showSidebar = false
    @State private var renameTarget: Chat?
    @State private var copiedID: UUID?
    @State private var isAtBottom = true
    @State private var renameText = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            NavigationStack {
                transcript
                    .safeAreaInset(edge: .bottom, spacing: 0) { inputBar }
                .navigationBarTitleDisplayMode(.inline)
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
            Text("Na 나")
                .font(.largeTitle.bold())
                .padding(.horizontal)
                .padding(.top, 12)

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
                    // Sentinel: tracks whether the view is scrolled to the bottom.
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                        .onAppear { isAtBottom = true }
                        .onDisappear { isAtBottom = false }
                }
                .padding()
            }
            .scrollDismissesKeyboard(.immediately)
            .onTapGesture { inputFocused = false }
            .onChange(of: model.items.count) {
                // Follow new messages only when already at the bottom.
                if isAtBottom {
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            .overlay(alignment: .bottom) {
                if !isAtBottom {
                    Button {
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                            .padding(11)
                            .background(.regularMaterial, in: Circle())
                            .overlay(Circle().strokeBorder(.quaternary, lineWidth: 0.5))
                    }
                    .padding(.bottom, 10)
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
        case .assistant(let id, let text):
            VStack(alignment: .leading, spacing: 14) {
                Text(Self.inlineMarkdown(text))
                    .lineSpacing(6)
                    .textSelection(.enabled)
                HStack(spacing: 14) {
                    Button {
                        UIPasteboard.general.string = text
                        copiedID = id
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            if copiedID == id { copiedID = nil }
                        }
                    } label: {
                        Image(systemName: copiedID == id ? "checkmark" : "doc.on.doc")
                    }
                    ShareLink(item: text) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
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
        Group {
            if model.isBusy {
                // While processing, the composer is replaced entirely.
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Working…")
                    if let since = model.busySince {
                        Text(since, style: .timer).monospacedDigit()
                    }
                    Spacer()
                    Button("Cancel", systemImage: "stop.circle.fill") { model.stop() }
                        .labelStyle(.titleAndIcon)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .padding(.vertical, 17)
                .modifier(ComposerBackground())
                .padding(.horizontal)
                .padding(.vertical, 8)
            } else {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Tell Atman something…", text: $draft, axis: .vertical)
                        .lineLimit(1...4)
                        .focused($inputFocused)
                        .onSubmit(submit)
                        .padding(.vertical, 15)
                    Button(action: submit) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 32))
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    // Matches the single-line row height (22pt line + 2×15pt
                    // padding), so bottom alignment reads as centered at one
                    // line and bottom-pinned when the field grows.
                    .frame(height: 52)
                }
                .padding(.leading, 18)
                .padding(.trailing, 8)
                .modifier(ComposerBackground())
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
        }
    }

    private func submit() {
        let text = draft
        draft = ""
        model.send(text)
    }
}

/// Liquid Glass on iOS 26+, plain fill on earlier systems.
private struct ComposerBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26))
        } else {
            content.background(
                Color(.secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 26))
        }
    }
}
