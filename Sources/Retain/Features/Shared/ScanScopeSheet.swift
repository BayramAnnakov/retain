import SwiftUI

struct ScanScopeSheet: View {
    let title: String
    @Binding var timeWindowDays: Int
    @Binding var projectOnly: Bool
    let projectPath: String?
    @Binding var selectedProviders: Set<Provider>
    let availableProviders: [Provider]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(title)
                    .font(.title2.bold())
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.title2)
                }
                .buttonStyle(.plain)
            }

            Form {
                Section("Time Window") {
                    Picker("Range", selection: $timeWindowDays) {
                        Text("All time").tag(0)
                        Text("Last 30 days").tag(30)
                    }
                    .pickerStyle(.segmented)
                }

                Section("Project Scope") {
                    Toggle("Only selected project", isOn: projectToggleBinding)
                        .disabled(projectPath == nil)

                    if let path = projectPath, !path.isEmpty {
                        Text(path)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("Select a conversation with a project path to enable.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section("Providers") {
                    Toggle("All providers", isOn: allProvidersBinding)

                    ForEach(availableProviders, id: \.self) { provider in
                        Toggle(provider.displayName, isOn: providerBinding(for: provider))
                    }
                }
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(minWidth: 460)
    }

    private var projectToggleBinding: Binding<Bool> {
        Binding(
            get: { projectOnly && projectPath != nil },
            set: { newValue in
                projectOnly = newValue
            }
        )
    }

    private var allProvidersBinding: Binding<Bool> {
        Binding(
            get: { selectedProviders.isEmpty },
            set: { newValue in
                if newValue {
                    selectedProviders = []
                } else {
                    selectedProviders = Set(availableProviders)
                }
            }
        )
    }

    private func providerBinding(for provider: Provider) -> Binding<Bool> {
        Binding(
            get: {
                selectedProviders.isEmpty || selectedProviders.contains(provider)
            },
            set: { isOn in
                var set = selectedProviders.isEmpty ? Set(availableProviders) : selectedProviders
                if isOn {
                    set.insert(provider)
                } else {
                    set.remove(provider)
                }
                selectedProviders = set
            }
        )
    }
}

enum ScanScopeStorage {
    static func decodeProviders(_ value: String) -> Set<Provider> {
        let rawValues = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let providers = rawValues.compactMap { Provider(rawValue: String($0)) }
        return Set(providers)
    }

    static func encodeProviders(_ providers: Set<Provider>) -> String {
        providers.map { $0.rawValue }.sorted().joined(separator: ",")
    }
}
