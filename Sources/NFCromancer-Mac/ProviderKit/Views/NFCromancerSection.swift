import SwiftUI
import AppKit
import SimBridgeServer
import SimBridgeShell

/// The embeddable heart of the NFCromancer provider UI: mode picker, status
/// line, and the mode-specific body. The standalone panel wraps it with a
/// title header and an app footer; the Simsalabim suite embeds it as one
/// section among several providers.
public struct NFCromancerSection: View {
    @ObservedObject var server: TagServer
    @ObservedObject var store: TagStore
    @ObservedObject var transport: ProtocolServer
    @ObservedObject var controller: ModeTransitionController<ProviderMode>
    /// A host that surfaces the connected client on its own level (the suite
    /// does) passes false; the section then omits its client display.
    var showsClient: Bool

    public init(
        server: TagServer,
        transport: ProtocolServer,
        controller: ModeTransitionController<ProviderMode>,
        showsClient: Bool = true
    ) {
        self.server = server
        self.store = server.store
        self.transport = transport
        self.controller = controller
        self.showsClient = showsClient
    }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Picker("Mode", selection: modeBinding) {
                    ForEach(ProviderMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(controller.isSwitching)

                if controller.mode != .off {
                    statusLine
                }
            }
            .padding(12)
            Divider()

            switch controller.mode {
                case .off:
                    offBody
                case .mock:
                    mockBody
                case .passthrough:
                    passthroughBody
            }
        }
    }

    /// The provider's health, for a host that wants to tint its own chrome.
    public static func statusColor(mode: ProviderMode, status: ProtocolServer.Status) -> Color {
        switch mode {
            case .off:
                .secondary
            case .mock, .passthrough:
                switch status {
                    case .stopped:         .secondary
                    case .listening:       .blue
                    case .clientConnected: .green
                    case .blocked:         .orange
                }
        }
    }

    private var modeBinding: Binding<ProviderMode> {
        Binding(
            get: { controller.mode },
            set: { controller.select($0) }
        )
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Self.statusColor(mode: controller.mode, status: transport.status))
                .frame(width: 7, height: 7)
            Text(statusText)
                .font(.caption.weight(.medium))
            if showsClient, let client = transport.connectedClient {
                Text("· \(client.displayText)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var statusText: String {
        switch transport.status {
            case .stopped:          "Stopped"
            case .listening:        "Waiting for a simulator app…"
            case .clientConnected:  "Client connected"
            case .blocked(let message): message
        }
    }

    /// The product's own icon, pre-scaled so redraws never pay for
    /// downsampling the icns. Present in the standalone bundle and copied
    /// into the suite bundle by its Makefile.
    private static let brandIcon = NSImage(named: "NFCromancer")?.sbkScaled(toPointSize: 148)

    private var offBody: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 16)
            if let icon = Self.brandIcon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 148, height: 148)
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                    // Rasterized once: a bare .shadow forces an offscreen blur
                    // on every commit, which the suite pays ~100 times per
                    // second while its pane splitter is dragged.
                    .drawingGroup()
            } else {
                Image(systemName: "wave.3.right")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary.opacity(0.35))
            }
            VStack(spacing: 4) {
                Text("NFCromancer is off")
                    .font(.headline)
                Text("Simulator apps see no NFC.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Mock body

    @State private var showAddSheet = false

    @ViewBuilder
    private var mockBody: some View {
        // A client-supplied fixture replaces the library, so it must replace
        // what the panel shows too — otherwise the panel describes tags that
        // are not being served.
        if let config = server.clientConfiguration {
            clientConfigBody(config)
        } else {
            libraryBody
        }
    }

    private func clientConfigBody(_ config: ClientTagConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "iphone.and.arrow.forward")
                    .foregroundStyle(.orange)
                Text(config.name ?? "Test fixtures")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(config.tags.count) tag(s)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.orange.opacity(0.10))
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(config.tags) { tag in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(tag.name ?? tag.id).font(.subheadline).lineLimit(1)
                            Text("\(tag.kind.title) · \(tag.value)")
                                .font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                    }
                }
                .padding(.vertical, 4)
            }
            Text("Presented programmatically by the test; your library resumes when it disconnects.")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var libraryBody: some View {
        VStack(spacing: 0) {
            HStack {
                Text(server.sessionWaiting ? "Session waiting — tap a tag to present it" : "No session — start a scan in the app")
                    .font(.caption)
                    .foregroundStyle(server.sessionWaiting ? Color.green : .secondary)
                Spacer()
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add a tag")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(store.tags) { tag in
                        mockTagRow(tag)
                    }
                    if store.tags.isEmpty {
                        Text("No tags — add one with +")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .sheet(isPresented: $showAddSheet) {
            MockTagEditor { newTag in store.add(newTag) }
        }
    }

    private func mockTagRow(_ tag: MockTag) -> some View {
        let isPresented = server.presentedMockTagId == tag.id
        return HStack(spacing: 8) {
            Image(systemName: tag.kind == .uri ? "link" : tag.kind == .text ? "text.alignleft" : "number")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(tag.name).font(.subheadline).lineLimit(1)
                Text(tag.value)
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if isPresented {
                Button("Remove") { server.retract() }
                    .font(.caption).controlSize(.small).tint(.orange)
            } else {
                Button("Present") { server.present(tag) }
                    .font(.caption).controlSize(.small)
                    .disabled(!server.sessionWaiting)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isPresented ? Color.green.opacity(0.08) : .clear)
        .contextMenu {
            Button("Delete", role: .destructive) { store.delete(id: tag.id) }
        }
    }

    /// The UID of the card most recently copied into the library, so the button
    /// can confirm the save. A new card carries a different UID, resetting it.
    @State private var capturedUID: String?

    @ViewBuilder
    private func captureButton(_ tag: PresentedTag) -> some View {
        let saved = capturedUID == tag.uidHex
        Button {
            store.add(MockTag.captured(uidHex: tag.uidHex, ndef: tag.ndef))
            capturedUID = tag.uidHex
        } label: {
            Label(saved ? "Saved to Library" : "Copy to Library",
                  systemImage: saved ? "checkmark" : "square.and.arrow.down")
        }
        .controlSize(.small)
        .tint(saved ? .green : nil)
        .disabled(saved)
        .padding(.top, 4)
        .help(tag.hasNDEF
              ? "Snapshot this card's NDEF and UID into the mock library."
              : "This card exposes no NDEF; only its UID is captured (a blank tag).")
    }

    /// A mock tag chosen from the write menu, awaiting the overwrite
    /// confirmation; and the result of the last write, shown inline.
    @State private var pendingWrite: MockTag?
    @State private var writeStatus: WriteStatus = .idle

    private enum WriteStatus: Equatable {
        case idle, writing, success, failure(String)
    }

    @ViewBuilder
    private func writeControl(_ tag: PresentedTag) -> some View {
        VStack(spacing: 4) {
            Menu {
                if store.tags.isEmpty {
                    Text("No mock tags to write")
                } else {
                    ForEach(store.tags) { t in
                        Button(t.name) { pendingWrite = t }
                    }
                }
            } label: {
                Label("Write Mock Tag…", systemImage: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .controlSize(.small)
            .disabled(store.tags.isEmpty || writeStatus == .writing)

            switch writeStatus {
                case .idle:
                    EmptyView()
                case .writing:
                    Label("Writing…", systemImage: "square.and.arrow.up")
                        .font(.caption).foregroundStyle(.secondary)
                case .success:
                    Label("Written to card", systemImage: "checkmark")
                        .font(.caption).foregroundStyle(.green)
                case .failure(let message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.red)
                        .multilineTextAlignment(.center)
            }
        }
        .confirmationDialog(
            pendingWrite.map { "Write “\($0.name)” to the tag on the reader?" } ?? "",
            isPresented: Binding(get: { pendingWrite != nil }, set: { if !$0 { pendingWrite = nil } }),
            presenting: pendingWrite
        ) { mock in
            Button("Write", role: .destructive) { performWrite(mock) }
            Button("Cancel", role: .cancel) { pendingWrite = nil }
        } message: { _ in
            Text("This overwrites the tag's current NDEF content. Type 2 tags only.")
        }
    }

    private func performWrite(_ tag: MockTag) {
        pendingWrite = nil
        writeStatus = .writing
        server.writeToReader(tag) { result in
            switch result {
                case .success:            writeStatus = .success
                case .failure(let error): writeStatus = .failure(error.localizedDescription)
            }
        }
    }

    @ViewBuilder
    private var passthroughBody: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 16)
            if let tag = server.presentedTag {
                Image(systemName: "wave.3.right.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.green)
                VStack(spacing: 4) {
                    Text("Tag on reader")
                        .font(.headline)
                    Text(tag.tech)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("UID \(tag.uid)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if let text = tag.ndefText {
                        Text(text)
                            .font(.callout)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .truncationMode(.tail)
                            .padding(.horizontal, 16)
                    } else if let imageData = tag.ndefImage, let image = NSImage(data: imageData) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 120, maxHeight: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else if tag.hasNDEF {
                        Label("NDEF present", systemImage: "doc.text")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
                captureButton(tag)
                if tag.isType2 {
                    writeControl(tag)
                }
            } else if server.readerAvailable {
                Image(systemName: "wave.3.right.circle")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary.opacity(0.5))
                VStack(spacing: 4) {
                    Text("Reader ready")
                        .font(.headline)
                    Text("Present a tag on the reader.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "wave.3.right.slash")
                    .font(.system(size: 40))
                    .foregroundStyle(.orange.opacity(0.7))
                VStack(spacing: 4) {
                    Text("No reader")
                        .font(.headline)
                    Text("Connect a USB NFC reader (ACR122U).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            Spacer(minLength: 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A different card (or an empty field) invalidates the last write result.
        .onChange(of: server.presentedTag?.uidHex) { _, _ in
            writeStatus = .idle
        }
    }

    private func placeholderBody(systemImage: String, message: String) -> some View {
        VStack(spacing: 14) {
            Spacer(minLength: 16)
            Image(systemName: systemImage)
                .font(.system(size: 34))
                .foregroundStyle(.secondary.opacity(0.5))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer(minLength: 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
