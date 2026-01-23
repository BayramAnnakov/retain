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

    /// Core CLI providers for onboarding (stable, well-tested)
    /// Additional providers can be enabled in Settings after onboarding
    private static let coreProviders: Set<Provider> = [.claudeCode, .codex]

    /// CLI providers from the registry - only core providers in onboarding
    private var cliProviders: [ProviderConfiguration] {
        ProviderRegistry.cliProviders.filter { Self.coreProviders.contains($0.provider) }
    }

    @State private var providerStatuses: [Provider: CLIToolStatus] = [:]

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

            // Dynamic CLI tool cards from registry
            VStack(spacing: 16) {
                ForEach(cliProviders, id: \.provider) { config in
                    CLISourceCard(
                        name: config.displayName,
                        icon: config.iconName,
                        iconColor: config.brandColor,
                        path: config.sourceDescription,
                        status: providerStatuses[config.provider] ?? .checking,
                        isEnabled: bindingForProvider(config.provider),
                        willSync: "conversation history",
                        willNotAccess: "API keys, system files"
                    )
                }
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

    /// Get binding for a specific provider's enabled state
    private func bindingForProvider(_ provider: Provider) -> Binding<Bool> {
        switch provider {
        case .claudeCode:
            return $claudeCodeEnabled
        case .codex:
            return $codexEnabled
        default:
            return .constant(false)
        }
    }

    private func detectCLITools() async {
        // Detect all CLI providers from registry
        for config in cliProviders {
            let status = CLIToolDetector.status(for: config.provider)
            providerStatuses[config.provider] = status

            // Auto-disable if not found
            if case .notFound = status {
                switch config.provider {
                case .claudeCode:
                    claudeCodeEnabled = false
                case .codex:
                    codexEnabled = false
                default:
                    break
                }
            }
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

    /// Core providers shown in onboarding (matches CLISourcesStepView)
    private static let coreProviders: Set<Provider> = [.claudeCode, .codex]

    private var claudeConnected: Bool {
        appState.webSyncEngine.claudeConnectionStatus.isConnected
    }

    private var chatgptConnected: Bool {
        appState.webSyncEngine.chatgptConnectionStatus.isConnected
    }

    /// Check if a CLI provider is enabled
    private func isProviderEnabled(_ provider: Provider) -> Bool {
        switch provider {
        case .claudeCode: return claudeCodeEnabled
        case .codex: return codexEnabled
        default: return false
        }
    }

    /// Check if a web provider is connected
    private func isWebProviderConnected(_ provider: Provider) -> Bool {
        switch provider {
        case .claudeWeb: return claudeConnected
        case .chatgptWeb: return chatgptConnected
        default: return false
        }
    }

    /// Filtered CLI providers for onboarding summary
    private var coreCliProviders: [ProviderConfiguration] {
        ProviderRegistry.cliProviders.filter { Self.coreProviders.contains($0.provider) }
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

            // Summary - Only core providers shown in onboarding
            VStack(alignment: .leading, spacing: 8) {
                // Core CLI providers (Claude Code, Codex)
                ForEach(coreCliProviders, id: \.provider) { config in
                    SourceSummaryRow(
                        name: config.displayName,
                        isEnabled: isProviderEnabled(config.provider),
                        detail: isProviderEnabled(config.provider) ? "CLI conversations" : nil
                    )
                }
                // Web providers
                ForEach(ProviderRegistry.webProviders, id: \.provider) { config in
                    SourceSummaryRow(
                        name: config.displayName,
                        isEnabled: isWebProviderConnected(config.provider),
                        detail: isWebProviderConnected(config.provider) ? "Web conversations" : nil
                    )
                }
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
    /// Dynamic status detection using provider registry
    static func status(for provider: Provider) -> CLIToolStatus {
        switch provider {
        case .claudeCode:
            return claudeCodeStatus()
        case .codex:
            return codexStatus()
        case .opencode:
            return openCodeStatus()
        case .geminiCLI:
            return geminiCLIStatus()
        case .copilot:
            return copilotStatus()
        case .cursor:
            return cursorStatus()
        case .claudeWeb, .chatgptWeb, .gemini:
            return .notFound  // Web providers don't have CLI status
        }
    }

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

    /// OpenCode status detection
    static func openCodeStatus() -> CLIToolStatus {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/storage")

        guard FileManager.default.fileExists(atPath: path.path) else {
            return .notFound
        }

        do {
            let contents = try FileManager.default.contentsOfDirectory(atPath: path.path)
            let sessionCount = contents.filter { !$0.hasPrefix(".") }.count
            return .found(count: sessionCount, size: nil)
        } catch {
            return .notFound
        }
    }

    /// Gemini CLI status detection
    static func geminiCLIStatus() -> CLIToolStatus {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/tmp")

        guard FileManager.default.fileExists(atPath: path.path) else {
            return .notFound
        }

        return .found(count: 1, size: "Found")
    }

    /// Cursor status detection
    static func cursorStatus() -> CLIToolStatus {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor")

        guard FileManager.default.fileExists(atPath: path.path) else {
            return .notFound
        }

        return .found(count: 1, size: "Found")
    }

    static func copilotStatus() -> CLIToolStatus {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".copilot/session-state")

        guard FileManager.default.fileExists(atPath: path.path) else {
            return .notFound
        }

        // Count session files
        do {
            let contents = try FileManager.default.contentsOfDirectory(atPath: path.path)
            let sessionCount = contents.filter { $0.hasSuffix(".jsonl") }.count
            return .found(count: sessionCount, size: nil)
        } catch {
            return .notFound
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
