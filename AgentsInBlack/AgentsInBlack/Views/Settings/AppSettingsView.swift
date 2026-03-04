import SwiftUI

struct AppSettingsView: View {
    @AppStorage(AppSettingsKey.terminalFontSize) private var terminalFontSize = AppSettingsDefault.terminalFontSize
    @State private var envEntries: [EnvEntry] = []
    @State private var showValues: Set<UUID> = []

    var body: some View {
        Form {
            Section("Environment Variables") {
                Text("Injected into all service processes started by the emulator.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach($envEntries) { $entry in
                    HStack(spacing: 8) {
                        TextField("KEY", text: $entry.key)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 200)

                        if showValues.contains(entry.id) {
                            TextField("Value", text: $entry.value)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                        } else {
                            SecureField("Value", text: $entry.value)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                        }

                        Button {
                            if showValues.contains(entry.id) {
                                showValues.remove(entry.id)
                            } else {
                                showValues.insert(entry.id)
                            }
                        } label: {
                            Image(systemName: showValues.contains(entry.id) ? "eye.slash" : "eye")
                                .frame(width: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)

                        Button {
                            envEntries.removeAll { $0.id == entry.id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .frame(width: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                    }
                }

                Button {
                    envEntries.append(EnvEntry(key: "", value: ""))
                } label: {
                    Label("Add Variable", systemImage: "plus")
                }
            }

            Section("Terminal") {
                HStack {
                    Text("Font Size")
                    Spacer()
                    Text("\(Int(terminalFontSize)) pt")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Slider(value: $terminalFontSize, in: 8...24, step: 1) {
                    Text("Font Size")
                } minimumValueLabel: {
                    Text("A")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Text("A")
                        .font(.system(size: 16, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Text("The quick brown fox jumps over the lazy dog")
                    .font(.system(size: CGFloat(terminalFontSize), design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onAppear { loadEntries() }
        .onChange(of: envEntries) { _, _ in saveEntries() }
    }

    private func loadEntries() {
        guard let dict = UserDefaults.standard.dictionary(forKey: AppSettingsKey.userEnvironmentVariables) as? [String: String] else {
            return
        }
        envEntries = dict.sorted(by: { $0.key < $1.key }).map { EnvEntry(key: $0.key, value: $0.value) }
    }

    private func saveEntries() {
        var dict: [String: String] = [:]
        for entry in envEntries where !entry.key.isEmpty {
            dict[entry.key] = entry.value
        }
        UserDefaults.standard.set(dict, forKey: AppSettingsKey.userEnvironmentVariables)
    }
}

private struct EnvEntry: Identifiable, Equatable {
    let id = UUID()
    var key: String
    var value: String
}

#Preview {
    AppSettingsView()
}
