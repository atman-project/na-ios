import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ChatView: View {
    @StateObject private var model = ChatViewModel()
    @State private var draft = ""
    @State private var showSettings = false
    @State private var showSidebar = false
    @State private var renameTarget: Chat?
    @State private var copiedID: UUID?
    @State private var isAtBottom = true
    @State private var pendingAttachments: [Attachment] = []
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var showCamera = false
    @State private var photoItem: PhotosPickerItem?
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
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                if let attachment = Self.attachment(from: image, name: "camera.jpg") {
                    pendingAttachments.append(attachment)
                }
            }
            .ignoresSafeArea()
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) {
            Task { await loadPhoto() }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.pdf, .image, .plainText, .json, .commaSeparatedText]
        ) { result in
            handleFile(result)
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
            .onTapGesture {
                inputFocused = false
                // End any active text selection (and its edit menu) right away;
                // otherwise the menu lingers until the system gets around to it.
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
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
                    .contextMenu {
                        Button("Copy", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = text
                        }
                        ShareLink(item: text) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
            }
        case .assistant(let id, let text):
            VStack(alignment: .leading, spacing: 14) {
                SelectableMessageText(text: text)
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
        case .attachment(_, let label):
            HStack {
                Spacer(minLength: 40)
                Label(label, systemImage: "paperclip")
                    .font(.caption)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
            }
        case .error(_, let text):
            Text(text)
                .font(.footnote)
                .foregroundStyle(.red)
        }
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
                VStack(spacing: 0) {
                    if !pendingAttachments.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(pendingAttachments) { attachment in
                                    HStack(spacing: 4) {
                                        Image(systemName: "paperclip")
                                        Text(attachment.filename).lineLimit(1)
                                        Button {
                                            pendingAttachments.removeAll { $0.id == attachment.id }
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                        }
                                    }
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color(.tertiarySystemFill), in: Capsule())
                                }
                            }
                        }
                        .padding(.top, 12)
                    }
                    composerRow
                }
                .modifier(ComposerBackground())
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
        }
    }

    private var composerRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Menu {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button("Camera", systemImage: "camera") { showCamera = true }
                }
                Button("Photo Library", systemImage: "photo.on.rectangle") { showPhotoPicker = true }
                Button("Choose File", systemImage: "folder") { showFileImporter = true }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
            }
            .frame(height: 52)
            TextField("Tell Atman something…", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .focused($inputFocused)
                .onSubmit(submit)
                .padding(.vertical, 15)
            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
            }
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty && pendingAttachments.isEmpty)
            // Matches the single-line row height (22pt line + 2×15pt padding),
            // so bottom alignment reads as centered at one line and
            // bottom-pinned when the field grows.
            .frame(height: 52)
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
    }

    private func submit() {
        let text = draft
        let attachments = pendingAttachments
        draft = ""
        pendingAttachments = []
        model.send(text, attachments: attachments)
    }

    private func loadPhoto() async {
        guard let item = photoItem else { return }
        photoItem = nil
        guard let data = try? await item.loadTransferable(type: Data.self),
              let attachment = Self.imageAttachment(from: data, name: "photo.jpg") else { return }
        pendingAttachments.append(attachment)
    }

    private func handleFile(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        let name = url.lastPathComponent
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .pdf) == true {
            pendingAttachments.append(Attachment(filename: name, kind: .pdf, data: data))
        } else if type?.conforms(to: .image) == true {
            if let attachment = Self.imageAttachment(from: data, name: name) {
                pendingAttachments.append(attachment)
            }
        } else if let text = String(data: data, encoding: .utf8) {
            pendingAttachments.append(
                Attachment(filename: name, kind: .text(String(text.prefix(100_000))), data: Data()))
        }
    }

    /// Downscale to Claude's preferred max edge and re-encode as JPEG.
    private static func imageAttachment(from data: Data, name: String) -> Attachment? {
        guard let image = UIImage(data: data) else { return nil }
        return attachment(from: image, name: name)
    }

    private static func attachment(from image: UIImage, name: String) -> Attachment? {
        let maxEdge: CGFloat = 1568
        let scale = min(1, maxEdge / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let jpeg = resized.jpegData(compressionQuality: 0.8) else { return nil }
        return Attachment(filename: name, kind: .image, data: jpeg)
    }
}

/// Liquid Glass on iOS 26+, plain fill on earlier systems.
///
/// The `#if compiler` guard keeps the file compilable on pre-Xcode-26
/// toolchains (e.g. CI runners), where the `glassEffect` symbol does not
/// exist in the SDK; `#available` alone only guards at runtime.
private struct ComposerBackground: ViewModifier {
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26))
        } else {
            fallback(content: content)
        }
        #else
        fallback(content)
        #endif
    }

    private func fallback(content: Content) -> some View {
        content.background(
            Color(.secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 26))
    }
}

/// Minimal camera capture (SwiftUI has no native camera view).
private struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(_ parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.onCapture(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}




/// Assistant message body rendered with UITextView so long-press starts
/// in-place text selection (handles + system edit bar), like ChatGPT.
/// SwiftUI's Text cannot offer partial in-place selection.
private struct SelectableMessageText: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.attributedText = MessageMarkdown.render(text)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        view.attributedText = MessageMarkdown.render(text)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, uiView: UITextView, context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width > 0, width.isFinite else { return nil }
        let size = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: size.height)
    }
}

/// Inline markdown (bold, italic, code, links) → NSAttributedString for
/// UITextView. Tidies "- " bullets to "•" like the old SwiftUI renderer.
private enum MessageMarkdown {
    static func render(_ text: String) -> NSAttributedString {
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

        let parsed = (try? AttributedString(
            markdown: tidied,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)

        let body = UIFont.preferredFont(forTextStyle: .body)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 6

        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let piece = String(parsed.characters[run.range])
            var font = body
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) {
                    font = .systemFont(ofSize: body.pointSize, weight: .semibold)
                } else if intent.contains(.emphasized) {
                    font = .italicSystemFont(ofSize: body.pointSize)
                } else if intent.contains(.code) {
                    font = .monospacedSystemFont(ofSize: body.pointSize * 0.9, weight: .regular)
                }
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.label,
                .paragraphStyle: paragraph,
            ]
            if let link = run.link {
                attributes[.link] = link
            }
            result.append(NSAttributedString(string: piece, attributes: attributes))
        }
        return result
    }
}
