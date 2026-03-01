import SwiftUI

/// A standalone compact chat view with Messages-style transcript and floating composer.
///
/// This view is independent of `AgentsInBlackAppModel` and can be placed in
/// any container: PiP panel, sheet, inspector, etc.
struct CompactChatView: View {
    @Bindable var session: ChatSession
    var onSelectMessage: ((ChatMessageItem?) -> Void)?

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
                if session.messages.isEmpty {
                    emptyState
                } else {
                    LazyVStack(spacing: 6) {
                        ForEach(session.messages) { message in
                            CompactChatMessageRow(
                                message: message,
                                isSelected: session.selectedMessageID == message.id
                            )
                            .id(message.id)
                            .onTapGesture {
                                session.selectMessage(message.id)
                                onSelectMessage?(session.selectedMessage)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    .padding(.bottom, 56)
                }
            }
            .onChange(of: session.messages.count) {
                guard let last = session.messages.last else { return }
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
            TextField("Message...", text: $session.composerText)
                .textFieldStyle(.plain)
                .font(.body)
                .onSubmit {
                    guard canSend else { return }
                    Task { await session.send() }
                }

            sendButton
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var sendButton: some View {
        if session.isSending {
            ProgressView()
                .controlSize(.small)
                .padding(.trailing, 4)
        } else {
            Button {
                Task { await session.send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(canSend ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: [.command])
            .help("Send Message")
        }
    }

    private var canSend: Bool {
        !session.isSending && !session.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
