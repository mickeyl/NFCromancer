import SwiftUI
import AppKit

/// A minimal editor for a new mock tag. Much shallower than a GATT tree — a
/// name, a kind, and one value field (a preset grid in place of that field
/// for `.image`: Type 2 tags hold so little memory that picking a file from
/// the filesystem would mostly be a way to pick something too big to fit).
struct MockTagEditor: View {
    let onSave: (MockTag) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var kind: MockTag.Kind = .uri
    @State private var value = ""
    @State private var selectedPreset: ImagePreset?

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
        .onChange(of: kind) { _, newKind in
            if newKind == .image, selectedPreset == nil { selectedPreset = ImagePreset.all.first }
        }
    }

    private var canSave: Bool {
        kind == .image ? selectedPreset != nil : !value.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func newTag(named name: String) -> MockTag {
        guard kind == .image, let selectedPreset, let data = selectedPreset.pngData else {
            return MockTag(name: name, kind: kind, value: value)
        }
        return MockTag(name: name, kind: .image, value: data.base64EncodedString(), mimeType: "image/png")
    }

    @ViewBuilder
    private var imagePicker: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
            ForEach(ImagePreset.all) { preset in
                presetSwatch(preset)
            }
        }
        if let selectedPreset, let bytes = selectedPreset.pngData?.count {
            Text("\(selectedPreset.name) · \(bytes) bytes")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func presetSwatch(_ preset: ImagePreset) -> some View {
        let isSelected = selectedPreset?.id == preset.id
        return Button {
            selectedPreset = preset
        } label: {
            Group {
                if let data = preset.pngData, let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: 22, height: 22)
                } else {
                    Color.clear.frame(width: 22, height: 22)
                }
            }
            .padding(5)
            .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: isSelected ? 1.5 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(preset.name)
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
            case .image: selectedPreset?.name ?? "Image tag"
            case .raw:   "Raw tag"
        }
    }
}
