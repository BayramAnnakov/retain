import SwiftUI

/// Settings view for CLI-based LLM analysis (Claude Code)
struct CLILLMSettingsView: View {
    @EnvironmentObject private var appState: AppState

    /// Use the shared orchestrator from AppState (not a local instance)
    private var orchestrator: LLMOrchestrator { appState.llmOrchestrator }

    @AppStorage("allowCloudAnalysis") private var allowCloudAnalysis = false  // Opt-in per SECURITY.md
    @AppStorage("customClaudePath") private var customClaudePath = ""

    @State private var showPrivacyAlert = false
    @State private var isDetectingTools = false

    var body: some View {
        Group {
            // MARK: - Privacy Consent Section
            privacyConsentSection

            // MARK: - CLI Tools Section
            if allowCloudAnalysis {
                cliToolsSection
                customPathsSection
            }
        }
    }

    // MARK: - Privacy Consent

    private var privacyConsentSection: some View {
        Section {
            Toggle("Allow Cloud-Based AI Analysis", isOn: $allowCloudAnalysis)
                .onChange(of: allowCloudAnalysis) { _, newValue in
                    if newValue {
                        showPrivacyAlert = true
                    }
                }

            if allowCloudAnalysis {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.caption)
                    Text("Data will be sent to Claude (Anthropic)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Link(destination: URL(string: "https://www.anthropic.com/privacy")!) {
                    Label("Anthropic Privacy Policy", systemImage: "arrow.up.right.square")
                        .font(.caption)
                }
            } else {
                Text("Enable to use Claude Code CLI for advanced AI analysis of your conversations.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } header: {
            HStack {
                Text("CLI Analysis")
                Spacer()
                Text("CLOUD")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundColor(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.15))
                    .cornerRadius(4)
            }
        }
        .alert("Cloud Analysis Privacy Notice", isPresented: $showPrivacyAlert) {
            Button("Allow") {
                allowCloudAnalysis = true
                Task { await refreshToolDetection() }
            }
            Button("Cancel", role: .cancel) {
                allowCloudAnalysis = false
            }
        } message: {
            Text("Analysis will send conversation snippets to Claude (Anthropic) servers. Your data is processed according to their privacy policy.\n\nYour local CLI tool handles the API calls - Retain does not have access to your API keys.")
        }
    }

    // MARK: - CLI Tools Detection

    private var cliToolsSection: some View {
        Section("Detected CLI Tools") {
            if let authMessage = cliAuthMessage {
                Label(authMessage, systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            if isDetectingTools {
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Detecting tools...")
                        .foregroundColor(.secondary)
                }
            } else if orchestrator.availableCLITools.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("No CLI tools detected", systemImage: "xmark.circle")
                        .foregroundColor(.secondary)

                    Text("Install Claude Code CLI to enable AI analysis.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Link("Install Claude Code", destination: URL(string: "https://docs.anthropic.com/claude-code")!)
                        .font(.caption)
                }
            } else {
                ForEach(orchestrator.availableCLITools, id: \.tool) { item in
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        VStack(alignment: .leading) {
                            Text(item.tool.displayName)
                                .font(.headline)
                            Text(item.path)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        if orchestrator.activeBackend.rawValue.contains(item.tool.rawValue) {
                            Text("Active")
                                .font(.caption2)
                                .fontWeight(.medium)
                                .foregroundColor(.green)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.15))
                                .cornerRadius(4)
                        }
                    }
                }
            }

            Button {
                Task { await refreshToolDetection() }
            } label: {
                Label("Refresh Detection", systemImage: "arrow.clockwise")
            }
            .disabled(isDetectingTools)
        }
        .task {
            await refreshToolDetection()
        }
    }

    // MARK: - Custom Paths

    private var customPathsSection: some View {
        Section("Custom CLI Path (Optional)") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Use this field if automatic detection fails to find Claude Code CLI.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    Text("Claude Code:")
                        .frame(width: 100, alignment: .leading)
                    TextField("/opt/homebrew/bin/claude", text: $customClaudePath)
                        .textFieldStyle(.roundedBorder)
                }

                Text("Example paths:\n• Apple Silicon Homebrew: /opt/homebrew/bin/\n• Intel Homebrew: /usr/local/bin/\n• npm global: ~/.npm-global/bin/")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Actions

    private func refreshToolDetection() async {
        isDetectingTools = true
        _ = await orchestrator.selectBackend()
        isDetectingTools = false
    }

    private var cliAuthMessage: String? {
        guard let error = orchestrator.lastAnalysisError?.lowercased() else { return nil }
        if error.contains("not logged in") || error.contains("claude cli not logged in") || error.contains("authentication") {
            return "Claude CLI is installed but not logged in. Run `claude login`."
        }
        return nil
    }
}

// MARK: - Analysis Capabilities Info

struct AnalysisCapabilitiesView: View {
    var body: some View {
        Section("Analysis Capabilities") {
            VStack(alignment: .leading, spacing: 8) {
                capabilityRow(
                    icon: "gearshape.2",
                    title: "Workflow Detection",
                    description: "Identifies repetitive patterns that could be automated"
                )
                capabilityRow(
                    icon: "lightbulb",
                    title: "Learning Extraction",
                    description: "Finds corrections and preferences from your conversations"
                )
                capabilityRow(
                    icon: "text.quote",
                    title: "Smart Summaries",
                    description: "Generates titles and summaries for untitled conversations"
                )
                capabilityRow(
                    icon: "arrow.triangle.merge",
                    title: "Deduplication",
                    description: "Identifies duplicate learnings that can be merged"
                )
            }
        }
    }

    private func capabilityRow(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Backend Status Badge

struct BackendStatusBadge: View {
    let backend: LLMOrchestrator.Backend

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(backend.displayName)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(statusColor.opacity(0.1))
        .cornerRadius(CornerRadius.lg)
    }

    private var statusColor: Color {
        switch backend {
        case .claudeCode: return .orange
        case .codex: return .blue
        case .gemini: return .purple
        case .none: return .gray
        }
    }
}

#Preview {
    Form {
        CLILLMSettingsView()
    }
    .formStyle(.grouped)
    .environmentObject(AppState())
}
