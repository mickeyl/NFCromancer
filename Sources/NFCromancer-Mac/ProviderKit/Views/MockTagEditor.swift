import SwiftUI

/// A minimal editor for a new mock tag. Much shallower than a GATT tree — a
/// name, a kind, and one value field.
struct MockTagEditor: View {
    let onSave: (MockTag) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var kind: MockTag.Kind = .uri
    @State private var value = ""

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
                TextField(valuePrompt, text: $value, axis: .vertical)
                    .lineLimit(1...4)
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Add") {
                    let finalName = name.isEmpty ? defaultName : name
                    onSave(MockTag(name: finalName, kind: kind, value: value))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(value.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private var valuePrompt: String {
        switch kind {
            case .uri:  "https://…"
            case .text: "Text content"
            case .raw:  "NDEF message as hex"
        }
    }

    private var defaultName: String {
        switch kind {
            case .uri:  "URL tag"
            case .text: "Text tag"
            case .raw:  "Raw tag"
        }
    }
}
