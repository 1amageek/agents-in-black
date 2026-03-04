import AIBCore
import AIBRuntimeCore
import SwiftUI

struct ServiceWorkbenchView: View {
    @Bindable var model: AgentsInBlackAppModel

    var body: some View {
        Group {
            if let service = model.primaryWorkbenchService() {
                ServiceWorkbenchContentView(model: model, service: service)
            } else {
                ContentUnavailableView(
                    "Select a Service",
                    systemImage: "paperplane",
                    description: Text("Choose a service in the sidebar to start validating it. Selecting a repository with a single service also opens the workbench.")
                )
            }
        }
    }
}

private struct ServiceWorkbenchContentView: View {
    @Bindable var model: AgentsInBlackAppModel
    let service: AIBServiceModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch model.effectiveWorkbenchMode(for: service) {
                case .chat:
                    ChatPaneView(model: model, service: service)
                case .raw:
                    RawPaneView(model: model, service: service)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(service.namespacedID)
                    .font(.headline)
                Text(model.requestBaseURLString(for: service) ?? "\(service.mountPath) (emulator stopped)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.requestBaseURLString(for: service) ?? service.mountPath)
            }

            if let snapshot = model.serviceSnapshot(for: service) {
                Text(snapshot.lifecycleState.rawValue)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            }

            Spacer()

            Picker(
                "Mode",
                selection: Binding(
                    get: { model.effectiveWorkbenchMode(for: service) },
                    set: { model.setWorkbenchMode($0, for: service) }
                )
            ) {
                Text("Chat").tag(AIBWorkbenchMode.chat)
                Text("Raw").tag(AIBWorkbenchMode.raw)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 180)

            Button("Clear") {
                model.clearWorkbench(for: service)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct ChatPaneView: View {
    @Bindable var model: AgentsInBlackAppModel
    let service: AIBServiceModel

    var body: some View {
        let session = model.activeSession(for: service)
        VStack(spacing: 0) {
            if let unavailable = model.chatUnavailableReason(for: service) {
                chatUnavailableView(unavailable)
            } else {
                transcript(session: session)
                Divider()
                composer(session: session)
            }
        }
    }

    @ViewBuilder
    private func chatUnavailableView(_ reason: String) -> some View {
        VStack(spacing: 12) {
            ContentUnavailableView(
                "Chat Unavailable",
                systemImage: "bubble.left.and.exclamationmark.bubble.right",
                description: Text(reason)
            )
            Button("Open Raw Mode") {
                model.setWorkbenchMode(.raw, for: service)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func transcript(session: ChatSession) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if session.messages.isEmpty {
                        ContentUnavailableView(
                            "Start a Conversation",
                            systemImage: "text.bubble",
                            description: Text("Send a message to validate the selected agent service.")
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                    } else {
                        ForEach(session.messages) { message in
                            ChatMessageRow(message: message)
                                .id(message.id)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: session.messages.count) {
                guard let last = session.messages.last else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private func composer(session: ChatSession) -> some View {
        VStack(spacing: 8) {
            TextEditor(text: Bindable(session).composerText)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity)
                .frame(height: 84)

            HStack(spacing: 8) {
                Button("Reset Conversation") {
                    session.reset()
                }
                .buttonStyle(.borderless)

                Spacer()

                Button {
                    Task { await session.send() }
                } label: {
                    if session.isSending {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Send", systemImage: "paperplane.fill")
                    }
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(session.isSending || session.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .background(.bar)
    }
}

private struct RawPaneView: View {
    @Bindable var model: AgentsInBlackAppModel
    let service: AIBServiceModel

    var body: some View {
        let draft = model.rawDraftSnapshot(for: service)
        VStack(spacing: 0) {
            requestControls(draft: draft)
            Divider()
            requestEditors(draft: draft)
            Divider()
            responseView(draft: draft)
        }
    }

    private func requestControls(draft: RawRequestDraft) -> some View {
        HStack(spacing: 8) {
            Picker(
                "Method",
                selection: Binding(
                    get: { model.rawDraftSnapshot(for: service).method },
                    set: { newValue in
                        var updated = model.rawDraftSnapshot(for: service)
                        updated.method = newValue
                        model.setRawDraft(updated, for: service)
                    }
                )
            ) {
                ForEach(HTTPRequestMethod.allCases) { method in
                    Text(method.rawValue).tag(method)
                }
            }
            .pickerStyle(.menu)

            TextField(
                "Path",
                text: Binding(
                    get: { model.rawDraftSnapshot(for: service).path },
                    set: { newValue in
                        var updated = model.rawDraftSnapshot(for: service)
                        updated.path = newValue
                        model.setRawDraft(updated, for: service)
                    }
                )
            )
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))

            Button {
                Task { await model.sendRawRequest(for: service) }
            } label: {
                if draft.isSending {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Send", systemImage: "paperplane.fill")
                }
            }
            .disabled(draft.isSending)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func requestEditors(draft: RawRequestDraft) -> some View {
        VStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Headers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(
                    text: Binding(
                        get: { model.rawDraftSnapshot(for: service).headersText },
                        set: { newValue in
                            var updated = model.rawDraftSnapshot(for: service)
                            updated.headersText = newValue
                            model.setRawDraft(updated, for: service)
                        }
                    )
                )
                .font(.system(.caption, design: .monospaced))
                .frame(height: 72)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Body")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if draft.method.supportsBody {
                    TextEditor(
                        text: Binding(
                            get: { model.rawDraftSnapshot(for: service).bodyText },
                            set: { newValue in
                                var updated = model.rawDraftSnapshot(for: service)
                                updated.bodyText = newValue
                                model.setRawDraft(updated, for: service)
                            }
                        )
                    )
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 110)
                } else {
                    Text("This HTTP method does not use a request body in this UI.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func responseView(draft: RawRequestDraft) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Response")
                    .font(.headline)
                Spacer()
                if let trace = draft.lastTrace, let status = trace.response.statusCode {
                    Text("HTTP \(status)")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                }
                if let latency = draft.lastTrace?.response.latencyMilliseconds {
                    Text("\(latency)ms")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let trace = draft.lastTrace {
                        Text("\(trace.method) \(trace.urlString)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)

                        if let errorMessage = trace.response.errorMessage {
                            Text(errorMessage)
                                .foregroundStyle(.red)
                                .font(.callout)
                        }

                        if !trace.response.headersText.isEmpty {
                            Text("Headers")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(trace.response.headersText)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }

                        Text("Body")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(trace.response.bodyText.isEmpty ? "(empty)" : trace.response.bodyText)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    } else {
                        Text("Send a request to view the response.")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }
}

private struct ChatMessageRow: View {
    let message: ChatMessageItem

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(message.role.rawValue.capitalized)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(roleColor)
                if let statusCode = message.statusCode {
                    Text("HTTP \(statusCode)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let latencyMs = message.latencyMs {
                    Text("\(latencyMs)ms")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let requestID = message.requestID {
                    Text(requestID)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(requestID)
                }
                Spacer()
                Text(message.timestamp, format: .dateTime.hour().minute().second())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(message.text)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(message.role == .error ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary))
                .textSelection(.enabled)
        }
        .padding(10)
        .background(bubbleBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var roleColor: Color {
        switch message.role {
        case .user:
            return .blue
        case .assistant:
            return .green
        case .system:
            return .secondary
        case .error:
            return .orange
        case .info:
            return .secondary
        }
    }

    private var bubbleBackground: AnyShapeStyle {
        switch message.role {
        case .user:
            return AnyShapeStyle(.quaternary)
        case .assistant:
            return AnyShapeStyle(.background)
        case .system, .info:
            return AnyShapeStyle(.bar)
        case .error:
            return AnyShapeStyle(Color.orange.opacity(0.10))
        }
    }
}
