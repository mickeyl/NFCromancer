import SwiftUI
import CoreNFC
import NFCromancer

@main
struct SampleApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var readingAvailable = false

    var body: some View {
        NavigationStack {
            List {
                Section("Availability") {
                    LabeledContent("NFC reading available") {
                        Text(readingAvailable ? "Yes" : "No")
                            .foregroundStyle(readingAvailable ? .green : .red)
                    }
                }
                Section {
                    Text("Phase 1 adds NDEF scanning and an APDU console here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("NFCromancer Sample")
        }
        .task {
            // Availability reflects provider connectivity; poll so the label
            // reacts when the provider starts or stops.
            while !Task.isCancelled {
                readingAvailable = NFCNDEFReaderSession.readingAvailable
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
