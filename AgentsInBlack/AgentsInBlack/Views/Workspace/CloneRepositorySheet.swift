import SwiftUI

struct CloneRepositorySheet: View {
    @Bindable var model: AgentsInBlackAppModel
    @FocusState private var isURLFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .padding(20)
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            isURLFieldFocused = true
        }
    }

    private var header: some View {
        HStack {
            Label("Clone Repository", systemImage: "square.and.arrow.down")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Repository URL")
                    .font(.subheadline.weight(.medium))
                TextField("https://github.com/user/repo.git", text: $model.cloneURL)
                    .textFieldStyle(.roundedBorder)
                    .focused($isURLFieldFocused)
                    .disabled(model.cloneInProgress)
                    .onSubmit {
                        if canClone {
                            model.cloneRepository()
                        }
                    }
            }

            if model.cloneInProgress {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Cloning…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = model.cloneError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    model.showCloneSheet = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Clone") {
                    model.cloneRepository()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canClone)
            }
        }
    }

    private var canClone: Bool {
        !model.cloneURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.cloneInProgress
    }
}
