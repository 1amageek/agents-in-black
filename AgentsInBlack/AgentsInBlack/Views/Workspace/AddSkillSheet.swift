import AIBCore
import SwiftUI

/// Sheet for creating a new skill in the user library (`~/.aib/skills/`).
struct AddSkillSheet: View {
    @Bindable var model: AgentsInBlackAppModel
    @State private var skillName: String = ""
    @State private var skillDescription: String = ""
    @State private var skillInstructions: String = ""
    @State private var isCreating: Bool = false
    @State private var errorMessage: String?
    @FocusState private var isNameFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .padding(20)
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Label("New Skill", systemImage: "puzzlepiece.extension.fill")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(.subheadline.weight(.medium))
                TextField("e.g. deploy, code-review", text: $skillName)
                    .textFieldStyle(.roundedBorder)
                    .focused($isNameFieldFocused)
                    .disabled(isCreating)
                    .onSubmit {
                        if canCreate { create() }
                    }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Description")
                    .font(.subheadline.weight(.medium))
                TextField("What the skill does and when to use it", text: $skillDescription)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isCreating)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Instructions")
                    .font(.subheadline.weight(.medium))
                TextEditor(text: $skillInstructions)
                    .font(.callout.monospaced())
                    .frame(minHeight: 120, maxHeight: 200)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                    .disabled(isCreating)
                Text("Markdown instructions loaded into the agent's context")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    model.showAddSkillSheet = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Create") {
                    create()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
            }
        }
    }

    // MARK: - Validation

    private var canCreate: Bool {
        !skillName.trimmingCharacters(in: .whitespaces).isEmpty && !isCreating
    }

    // MARK: - Actions

    private func create() {
        guard canCreate else { return }
        isCreating = true
        errorMessage = nil

        let name = skillName.trimmingCharacters(in: .whitespaces)
        let desc = skillDescription.trimmingCharacters(in: .whitespaces)
        let instr = skillInstructions.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            await model.createLibrarySkill(
                name: name,
                description: desc.isEmpty ? nil : desc,
                instructions: instr.isEmpty ? nil : instr,
                tags: []
            )
            if model.lastErrorMessage == nil {
                model.showAddSkillSheet = false
            } else {
                errorMessage = model.lastErrorMessage
            }
            isCreating = false
        }
    }
}
