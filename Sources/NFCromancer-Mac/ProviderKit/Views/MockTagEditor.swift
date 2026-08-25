import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A minimal editor for a new mock tag. Much shallower than a GATT tree — a
/// name, a kind, and one value field (a file picker in place of that field
/// for `.image`, since a base64 blob isn't something to type).
struct MockTagEditor: View {
    let onSave: (MockTag) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var kind: MockTag.Kind = .uri
    @State private var value = ""
    @State private var imageData: Data?
    @State private var imageMimeType = "image/png"
    @State private var imageFileName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Tag").font(.headline)

            Form {
                TextField("Name", text: $name)
                Picker("Kind", selection: $kind) {
                    ForEach(MockTag.Kind.allCases, id: \.self) { k in
                        Text(k.title).tag(k)
                    }
                }
                if kind == .image {
                    imagePicker
                } else {
                    TextField(valuePrompt, text: $value, axis: .vertical)
                        .lineLimit(1...4)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Add") {
                    let finalName = name.isEmpty ? defaultName : name
                    onSave(newTag(named: finalName))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private var canSave: Bool {
        kind == .image ? imageData != nil : !value.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func newTag(named name: String) -> MockTag {
        guard kind == .image, let imageData else {
            return MockTag(name: name, kind: kind, value: value)
        }
        return MockTag(name: name, kind: .image, value: imageData.base64EncodedString(), mimeType: imageMimeType)
    }

    @ViewBuilder
    private var imagePicker: some View {
        HStack(spacing: 8) {
            if let imageData, let preview = NSImage(data: imageData) {
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            Button(imageData == nil ? "Choose Image…" : "Change…") { pickImage() }
            Spacer()
        }
        if let imageData {
            let bytes = imageData.count
            Text("\(imageFileName) · \(bytes) bytes")
                .font(.caption)
                .foregroundStyle(bytes > 800 ? .orange : .secondary)
            if bytes > 800 {
                Text("Most Type 2 tags hold well under 1 KB — this may not fit.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        imageData = data
        imageFileName = url.lastPathComponent
        let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        imageMimeType = type?.preferredMIMEType ?? "image/png"
    }

    private var valuePrompt: String {
        switch kind {
            case .uri:   "https://…"
            case .text:  "Text content"
            case .image: ""
            case .raw:   "NDEF message as hex"
        }
    }

    private var defaultName: String {
        switch kind {
            case .uri:   "URL tag"
            case .text:  "Text tag"
            case .image: "Image tag"
            case .raw:   "Raw tag"
        }
    }
}
