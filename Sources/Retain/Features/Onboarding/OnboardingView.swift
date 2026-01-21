import SwiftUI

/// Consent-based onboarding flow for first-time users
struct OnboardingView: View {
    @Binding var isPresented: Bool
    @EnvironmentObject private var appState: AppState
    @State private var currentStep: OnboardingStep = .welcome

    // Persisted settings
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("claudeCodeEnabled") private var claudeCodeEnabled = true
    @AppStorage("codexEnabled") private var codexEnabled = true  // Fix 5: Track Codex state
    @AppStorage("autoSyncEnabled") private var autoSyncEnabled = true
    @AppStorage("autoExtractLearnings") private var autoExtractLearnings = true
    @AppStorage("allowCloudAnalysis") private var allowCloudAnalysis = false  // Opt-in per SECURITY.md

    enum OnboardingStep: Int, CaseIterable {
        case welcome
        case cliSources
        case webAccounts
        case ready
    }

    var body: some View {
        VStack(spacing: 0) {
            // Step content
            Group {
                switch currentStep {
                case .welcome:
                    WelcomeStepView(onContinue: { currentStep = .cliSources })
                case .cliSources:
                    CLISourcesStepView(
                        claudeCodeEnabled: $claudeCodeEnabled,
                        codexEnabled: $codexEnabled,  // Fix 5: Pass codexEnabled binding
                        onBack: { currentStep = .welcome },
                        onContinue: { currentStep = .webAccounts }
                    )
                case .webAccounts:
                    WebAccountsStepView(
                        onBack: { currentStep = .cliSources },
                        onContinue: { currentStep = .ready }
                    )
                case .ready:
                    ReadyStepView(
                        claudeCodeEnabled: claudeCodeEnabled,
                        codexEnabled: codexEnabled,  // Fix 5
                        autoSyncEnabled: $autoSyncEnabled,
                        autoExtractLearnings: $autoExtractLearnings,
                        allowCloudAnalysis: $allowCloudAnalysis,  // Fix 6
                        onBack: { currentStep = .webAccounts },
                        onComplete: completeOnboarding
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Progress indicator
            HStack(spacing: 8) {
                ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                    Circle()
                        .fill(step.rawValue <= currentStep.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                }
            }
            .padding(.bottom, 20)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(currentStep.rawValue + 1) of \(OnboardingStep.allCases.count)")
        }
        .frame(width: 620, height: 650)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func completeOnboarding() {
        isPresented = false
        appState.completeOnboarding()
    }
}

// MARK: - Step 1: Welcome

struct WelcomeStepView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // App icon
            Image(systemName: "brain.head.profile")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)
                .frame(width: 100, height: 100)
                .background(Color.accentColor.opacity(0.1))
                .clipShape(Circle())

            // Title
            VStack(spacing: 8) {
                Text("Welcome to Retain")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Your AI Conversation Knowledge Base")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }

            // Feature cards
            VStack(spacing: 12) {
                FeatureCard(
                    icon: "magnifyingglass",
                    iconColor: .blue,
                    title: "Search Everything",
                    description: "Instantly find any conversation across all your AI tools with full-text and semantic search"
                )

                FeatureCard(
                    icon: "lightbulb",
                    iconColor: .yellow,
                    title: "Extract Learnings",
                    description: "Build your AI identity by capturing corrections and preferences from your conversations"
                )

                FeatureCard(
                    icon: "lock.shield",
                    iconColor: .green,
                    title: "Local-First & Private",
                    description: "Your data is stored locally. Optional features (web sync, AI analysis) connect to external services when you enable them."
                )
            }
            .padding(.horizontal, 40)

            Spacer()

            // CTA
            Button(action: onContinue) {
                Text("Get Started")
                    .frame(width: 140)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.bottom, 20)
        }
        .padding()
    }
}

struct FeatureCard: View {
    let icon: String
    let iconColor: Color
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(iconColor)
                .frame(width: 32)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
}

// MARK: - Step 2: CLI Sources

struct CLISourcesStepView: View {
    @Binding var claudeCodeEnabled: Bool
    @Binding var codexEnabled: Bool  // Fix 5: Accept binding from parent
    let onBack: () -> Void
    let onContinue: () -> Void

    @State private var claudeCodeStatus: CLIToolStatus = .checking
    @State private var codexStatus: CLIToolStatus = .checking

    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 8) {
                Text("Connect Your CLI Tools")
                    .font(.title)
                    .fontWeight(.bold)

                Text("Retain can sync conversations from your terminal AI tools")
                    .font(.body)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 30)

            // CLI tool cards
            VStack(spacing: 16) {
                CLISourceCard(
                    name: "Claude Code",
                    icon: "terminal",
                    iconColor: .orange,
                    path: "~/.claude/projects/**/*.jsonl",
                    status: claudeCodeStatus,
                    isEnabled: $claudeCodeEnabled,
                    willSync: "conversation history, tool usage",
                    willNotAccess: "API keys, system files"
                )

                CLISourceCard(
                    name: "Codex CLI",
                    icon: "terminal.fill",
                    iconColor: .green,
                    path: "~/.codex/history.jsonl",
                    status: codexStatus,
                    isEnabled: $codexEnabled,
                    willSync: "conversation history",
                    willNotAccess: "API keys, system files"
                )
            }
            .padding(.horizontal, 30)

            // Privacy note
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundColor(.secondary)
                Text("Data is indexed locally. Files are never uploaded or shared.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 30)

            Spacer()

            // Navigation
            HStack {
                Button("Back", action: onBack)
                    .buttonStyle(.bordered)

                Spacer()

                Button("Continue", action: onContinue)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 20)
        }
        .task {
            await detectCLITools()
        }
    }

    private func detectCLITools() async {
        claudeCodeStatus = CLIToolDetector.claudeCodeStatus()
        codexStatus = CLIToolDetector.codexStatus()

        // Auto-disable if not found
        if case .notFound = claudeCodeStatus {
            claudeCodeEnabled = false
        }
        if case .notFound = codexStatus {
            codexEnabled = false
        }
    }
}

enum CLIToolStatus {
    case checking
    case found(count: Int, size: String?)
    case notFound
}

struct CLISourceCard: View {
    let name: String
    let icon: String
    let iconColor: Color
    let path: String
    let status: CLIToolStatus
    @Binding var isEnabled: Bool
    let willSync: String
    let willNotAccess: String

    var isAvailable: Bool {
        if case .found = status { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(iconColor)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.headline)
                    Text(path)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fontDesign(.monospaced)
                }

                Spacer()

                if isAvailable {
                    Toggle("", isOn: $isEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }

            // Status row
            HStack(spacing: 8) {
                switch status {
                case .checking:
                    ProgressView()
                        .scaleEffect(0.6)
                    Text("Checking...")
                        .font(.caption)
                        .foregroundColor(.secondary)

                case .found(let count, let size):
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    if let size = size {
                        // Custom label provided (e.g., "5 sessions" for Codex)
                        Text(size)
                            .font(.caption)
                            .foregroundColor(.green)
                    } else {
                        // Default: show as projects (for Claude Code)
                        Text(count == 1 ? "1 project found" : "\(count) projects found")
                            .font(.caption)
                            .foregroundColor(.green)
                    }

                case .notFound:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                    Text("Not detected")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if isAvailable && isEnabled {
                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                            .font(.caption2)
                            .foregroundColor(.green)
                        Text("Will sync: \(willSync)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "xmark")
                            .font(.caption2)
                            .foregroundColor(.red)
                        Text("Will NOT access: \(willNotAccess)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
        .opacity(isAvailable ? 1 : 0.6)
    }
}

// MARK: - Step 3: Web Accounts

struct WebAccountsStepView: View {
    @EnvironmentObject private var appState: AppState
    let onBack: () -> Void
    let onContinue: () -> Void

    @State private var showKeychainExplanation = false
    @State private var pendingProvider: Provider?
    @State private var refreshTrigger = UUID()  // Fix 3: Force SwiftUI refresh after connect

    private var claudeConnected: Bool {
        appState.webSyncEngine.claudeConnectionStatus.isConnected
    }

    private var chatgptConnected: Bool {
        appState.webSyncEngine.chatgptConnectionStatus.isConnected
    }

    private var claudeConnecting: Bool {
        if case .connecting = appState.webSyncEngine.claudeConnectionStatus { return true }
        return false
    }

    private var chatgptConnecting: Bool {
        if case .connecting = appState.webSyncEngine.chatgptConnectionStatus { return true }
        return false
    }

    private var claudeError: String? {
        if case .error(let message) = appState.webSyncEngine.claudeConnectionStatus {
            return message
        }
        return nil
    }

    private var chatgptError: String? {
        if case .error(let message) = appState.webSyncEngine.chatgptConnectionStatus {
            return message
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 8) {
                Text("Connect Web Accounts")
                    .font(.title)
                    .fontWeight(.bold)

                Text("Sync conversations from your web-based AI platforms")
                    .font(.body)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 30)

            // Prerequisite info card
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "1.circle.fill")
                    .foregroundColor(.blue)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Sign in to claude.ai or chatgpt.com in your browser first")
                        .font(.subheadline.weight(.semibold))

                    Text("Then click Connect below. Retain will import your session cookies to sync conversations. Your passwords are never accessed.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("macOS may prompt for Keychain (Chrome) or Full Disk Access (Safari) permission.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(Color.blue.opacity(0.1))
            .cornerRadius(12)
            .padding(.horizontal, 30)

            // Web account cards
            VStack(spacing: 16) {
                WebAccountCard(
                    name: "Claude.ai",
                    icon: "globe",
                    iconColor: .orange,
                    isConnected: claudeConnected,
                    isConnecting: claudeConnecting,
                    statusText: claudeConnected ? "Connected" : "Not connected",
                    errorMessage: claudeError,
                    onConnect: { requestConnect(provider: .claudeWeb) },
                    onDisconnect: { performDisconnect(provider: .claudeWeb) }  // Fix 7
                )

                WebAccountCard(
                    name: "ChatGPT",
                    icon: "bubble.left.and.bubble.right",
                    iconColor: .green,
                    isConnected: chatgptConnected,
                    isConnecting: chatgptConnecting,
                    statusText: chatgptConnected ? "Connected" : "Not connected",
                    errorMessage: chatgptError,
                    onConnect: { requestConnect(provider: .chatgptWeb) },
                    onDisconnect: { performDisconnect(provider: .chatgptWeb) }  // Fix 7
                )
            }
            .padding(.horizontal, 30)
            .id(refreshTrigger)  // Fix 3: Force refresh when connection status changes

            // Info notes
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.secondary)
                    Text("Web sessions expire after ~30 days. Already-synced conversations remain. Reconnect anytime in Settings.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "key.fill")
                        .foregroundColor(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Text("**Safari:**")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("Grant Full Disk Access.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Button("Open Settings") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .font(.caption)
                            .buttonStyle(.link)
                        }
                        Text("**Chrome:** Allow Keychain access when prompted.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("**Firefox:** Just ensure you're signed in.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 30)

            Spacer()

            // Navigation
            HStack {
                Button("Back", action: onBack)
                    .buttonStyle(.bordered)

                Spacer()

                Button("Skip for Now", action: onContinue)
                    .buttonStyle(.bordered)

                if claudeConnected || chatgptConnected {
                    Button("Continue", action: onContinue)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 20)
        }
        .alert("Browser Cookie Access", isPresented: $showKeychainExplanation) {
            Button("Cancel", role: .cancel) {
                pendingProvider = nil
            }
            Button("Continue") {
                if let provider = pendingProvider {
                    performConnect(provider: provider)
                }
                pendingProvider = nil
            }
        } message: {
            Text("Retain will read cookies from your browser to sync your conversations.\n\nChrome/Chromium users: macOS will ask for Keychain access to decrypt cookies. This is a one-time prompt.\n\nSafari users: You may need to grant Full Disk Access in System Settings.\n\nIf Safari doesn’t work, log in to Claude/ChatGPT in Chrome or Firefox and try again.")
        }
    }

    private func requestConnect(provider: Provider) {
        pendingProvider = provider
        showKeychainExplanation = true
    }

    private func performConnect(provider: Provider) {
        Task {
            await appState.webSyncEngine.importBrowserCookies(for: provider)
            // Fix 3: Force SwiftUI to re-evaluate connection status
            await MainActor.run {
                refreshTrigger = UUID()
            }
        }
    }

    // Fix 7: Disconnect during onboarding
    private func performDisconnect(provider: Provider) {
        Task {
            appState.webSyncEngine.disconnect(provider: provider)
            await MainActor.run {
                refreshTrigger = UUID()
            }
        }
    }
}

struct WebAccountCard: View {
    let name: String
    let icon: String
    let iconColor: Color
    let isConnected: Bool
    let isConnecting: Bool
    let statusText: String
    var errorMessage: String? = nil
    let onConnect: () -> Void
    var onDisconnect: (() -> Void)? = nil  // Fix 7: Optional disconnect callback

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(iconColor)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.headline)
                    Text("Session stored locally for quick re-sync")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if isConnected {
                    VStack(alignment: .trailing, spacing: 4) {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text(statusText)
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                        // Fix 7: Disconnect button
                        if let onDisconnect {
                            Button("Disconnect") {
                                onDisconnect()
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.red)
                            .font(.caption)
                        }
                    }
                } else {
                    Button(isConnecting ? "Connecting..." : "Connect") {
                        onConnect()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isConnecting)
                }
            }

            // Show error message if present
            if let errorMessage, !isConnected {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(.caption)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(.red)
                        .lineLimit(2)
                }
                .padding(.leading, 40)  // Align with text above
            }
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
    }
}

// MARK: - Step 4: Ready

struct ReadyStepView: View {
    let claudeCodeEnabled: Bool
    let codexEnabled: Bool  // Fix 5
    @Binding var autoSyncEnabled: Bool
    @Binding var autoExtractLearnings: Bool
    @Binding var allowCloudAnalysis: Bool  // Fix 6
    @EnvironmentObject private var appState: AppState
    let onBack: () -> Void
    let onComplete: () -> Void

    private var claudeConnected: Bool {
        appState.webSyncEngine.claudeConnectionStatus.isConnected
    }

    private var chatgptConnected: Bool {
        appState.webSyncEngine.chatgptConnectionStatus.isConnected
    }

    var body: some View {
        VStack(spacing: 16) {
            // Header
            Image(systemName: "checkmark.circle")
                .font(.system(size: 48))
                .foregroundColor(.green)
                .padding(.top, 20)

            VStack(spacing: 8) {
                Text("Ready to Get Started")
                    .font(.title)
                    .fontWeight(.bold)

                Text("Retain will now sync your selected data sources:")
                    .font(.body)
                    .foregroundColor(.secondary)
            }

            // Summary
            VStack(alignment: .leading, spacing: 8) {
                SourceSummaryRow(
                    name: "Claude Code",
                    isEnabled: claudeCodeEnabled,
                    detail: claudeCodeEnabled ? "CLI conversations" : nil
                )
                // Fix 5: Add Codex row
                SourceSummaryRow(
                    name: "Codex CLI",
                    isEnabled: codexEnabled,
                    detail: codexEnabled ? "CLI conversations" : nil
                )
                SourceSummaryRow(
                    name: "Claude.ai",
                    isEnabled: claudeConnected,
                    detail: claudeConnected ? "Web conversations" : nil
                )
                SourceSummaryRow(
                    name: "ChatGPT",
                    isEnabled: chatgptConnected,
                    detail: chatgptConnected ? "Web conversations" : nil
                )
            }
            .padding(16)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(10)
            .padding(.horizontal, 30)

            // Database location
            VStack(alignment: .leading, spacing: 4) {
                Text("Your data will be indexed locally in:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("~/Library/Application Support/Retain/")
                    .font(.caption)
                    .fontDesign(.monospaced)
                    .foregroundColor(.secondary)
            }

            // Options
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Sync automatically in background", isOn: $autoSyncEnabled)
                Toggle("Extract learnings from corrections", isOn: $autoExtractLearnings)
            }
            .padding(16)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(10)
            .padding(.horizontal, 30)

            // Fix 6: Cloud analysis toggle with explanation
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $allowCloudAnalysis) {
                    Text("AI-powered learning extraction")
                        .font(.subheadline.weight(.medium))
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "sparkles")
                            .foregroundColor(.purple)
                            .frame(width: 16)
                        Text("Automatically extracts learnings and patterns from your conversations")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "cloud")
                            .foregroundColor(.blue)
                            .frame(width: 16)
                        Text("Uses your configured AI (via Claude Code CLI) for deeper analysis")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "lock.shield")
                            .foregroundColor(.green)
                            .frame(width: 16)
                        Text("You can disable this anytime in Settings")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.leading, 4)
            }
            .padding(16)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .cornerRadius(10)
            .padding(.horizontal, 30)

            Spacer()

            // Navigation
            HStack {
                Button("Back", action: onBack)
                    .buttonStyle(.bordered)

                Spacer()

                Button(action: onComplete) {
                    Text("Start Retain")
                        .frame(width: 120)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 20)
        }
    }
}

struct SourceSummaryRow: View {
    let name: String
    let isEnabled: Bool
    let detail: String?

    var body: some View {
        HStack {
            Image(systemName: isEnabled ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundColor(isEnabled ? .green : .secondary)

            Text(name)
                .font(.body)

            Spacer()

            if let detail = detail {
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("Not connected")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - CLI Tool Detector

struct CLIToolDetector {
    static func claudeCodeStatus() -> CLIToolStatus {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")

        guard FileManager.default.fileExists(atPath: path.path) else {
            return .notFound
        }

        // Count project directories
        do {
            let contents = try FileManager.default.contentsOfDirectory(atPath: path.path)
            let projectCount = contents.filter { !$0.hasPrefix(".") }.count
            return .found(count: projectCount, size: nil)
        } catch {
            return .notFound
        }
    }

    static func codexStatus() -> CLIToolStatus {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/history.jsonl")

        guard FileManager.default.fileExists(atPath: path.path) else {
            return .notFound
        }

        // Count sessions (each line is a separate session in JSONL)
        do {
            let contents = try String(contentsOfFile: path.path, encoding: .utf8)
            let sessionCount = contents.components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .count
            let count = max(1, sessionCount)
            let label = count == 1 ? "1 session" : "\(count) sessions"
            return .found(count: count, size: label)
        } catch {
            // File exists but couldn't read - show as found
            return .found(count: 1, size: "Found")
        }
    }
}

// MARK: - First Launch Check

struct FirstLaunchModifier: ViewModifier {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showOnboarding = false

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showOnboarding) {
                OnboardingView(isPresented: $showOnboarding)
            }
            .interactiveDismissDisabled(!hasCompletedOnboarding)  // Fix 8: Prevent Esc dismissal during onboarding
            .onAppear {
                if !hasCompletedOnboarding {
                    showOnboarding = true
                }
            }
    }
}

extension View {
    func showOnboardingIfNeeded() -> some View {
        modifier(FirstLaunchModifier())
    }
}

#Preview {
    OnboardingView(isPresented: .constant(true))
        .environmentObject(AppState())
}
