import SwiftUI

/// A standalone compact chat view with Messages-style transcript and floating composer.
///
/// This view is independent of `AgentsInBlackAppModel` and can be placed in
/// any container: PiP panel, sheet, inspector, etc.
struct CompactChatView: View {
    @Bindable var store: ChatStore

    var body: some View {
        ZStack(alignment: .bottom) {
            transcript
            floatingComposer
        }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if store.messages.isEmpty {
                    emptyState
                } else {
                    LazyVStack(spacing: 6) {
                        ForEach(store.messages) { message in
                            CompactChatMessageRow(message: message)
                                .id(message.id)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    .padding(.bottom, 52)
                }
            }
            .onChange(of: store.messages.count) {
                guard let last = store.messages.last else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Start a Conversation", systemImage: "text.bubble")
        } description: {
            Text("Send a message to begin chatting with this agent.")
        }
        .padding(.top, 24)
    }

    // MARK: - Floating Composer

    private var floatingComposer: some View {
        HStack(spacing: 6) {
            TextField("Message...", text: $store.composerText)
                .textFieldStyle(.plain)
                .font(.system(.caption))
                .onSubmit {
                    guard canSend else { return }
                    Task { await store.send() }
                }

            sendButton
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(.thickMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.tertiary.opacity(0.5), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var sendButton: some View {
        if store.isSending {
            ProgressView()
                .controlSize(.small)
                .padding(.trailing, 4)
        } else {
            Button {
                Task { await store.send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(canSend ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: [.command])
            .help("Send Message")
        }
    }

    private var canSend: Bool {
        !store.isSending && !store.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
