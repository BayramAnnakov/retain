import SwiftUI

/// App settings view with sidebar navigation (System Preferences style)
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: SettingsTab
    var showCloseButton: Bool = false

    init(initialTab: SettingsTab = .general, showCloseButton: Bool = false) {
        _selectedTab = State(initialValue: initialTab)
        self.showCloseButton = showCloseButton
    }

    enum SettingsTab: String, CaseIterable, Identifiable {
        case general = "General"
        case dataSources = "Data Sources"
        case webAccounts = "Web Accounts"
        case learnings = "Learnings"
        case aiFeatures = "AI Features"
        case diagnostics = "Diagnostics"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .general: return "gear"
            case .dataSources: return "externaldrive"
            case .webAccounts: return "globe"
            case .learnings: return "lightbulb"
            case .aiFeatures: return "sparkles"
            case .diagnostics: return "stethoscope"
            }
        }

        var color: Color {
            switch self {
            case .general: return .gray
            case .dataSources: return .blue
            case .webAccounts: return .green
            case .learnings: return .orange
            case .aiFeatures: return .purple
            case .diagnostics: return .red
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: $selectedTab) { tab in
                Label {
                    Text(tab.rawValue)
                } icon: {
                    Image(systemName: tab.icon)
                        .foregroundColor(tab.color)
                }
                .tag(tab)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 220)
        } detail: {
            Group {
                switch selectedTab {
                case .general:
                    GeneralSettingsView()
                case .dataSources:
                    DataSourcesSettingsView()
                case .webAccounts:
                    WebAccountsSettingsView()
                case .learnings:
                    LearningsSettingsView()
                case .aiFeatures:
                    AIFeaturesSettingsView()
                case .diagnostics:
                    DiagnosticsSettingsView()
                }
            }
            .frame(minWidth: 480)
        }
        .frame(minWidth: 600, idealWidth: 700, maxWidth: 900, minHeight: 450, idealHeight: 500, maxHeight: 700)
        .toolbar {
            if showCloseButton {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        // Keychain explanation alert (needed when Settings opens as separate window)
        .alert(
            "Keychain Access Required",
            isPresented: $appState.showingKeychainExplanation,
            presenting: appState.pendingKeychainContext
        ) { _ in
            Button("Continue") {
                appState.showingKeychainExplanation = false
                appState.pendingKeychainContext = nil
            }
            Button("Cancel", role: .cancel) {
                appState.showingKeychainExplanation = false
                appState.pendingKeychainContext = nil
            }
        } message: { context in
            Text(keychainExplanationMessage(for: context))
        }
    }

    /// Generate explanation message for keychain access
    private func keychainExplanationMessage(for context: BrowserCookieKeychainPromptContext) -> String {
        let browserLabel = context.label
        return "Retain needs to read the \(browserLabel) Safe Storage key from your Keychain to decrypt cookies.\n\nmacOS will ask for your permission. This is a one-time request per browser."
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @AppStorage("syncOnLaunch") private var syncOnLaunch = true
    @AppStorage("autoSyncEnabled") private var autoSyncEnabled = true
    @AppStorage("autoSyncInterval") private var autoSyncInterval = 300 // 5 minutes

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, _ in
                        appState.updateLaunchAtLogin()
                    }
                Toggle("Show menu bar icon", isOn: $showMenuBarIcon)
            }

            Section("Sync") {
                Toggle("Sync on launch", isOn: $syncOnLaunch)
                Toggle("Auto-sync in background", isOn: $autoSyncEnabled)
                    .onChange(of: autoSyncEnabled) { _, _ in
                        appState.restartAutoSync()
                    }

                if autoSyncEnabled {
                    Picker("Sync interval", selection: $autoSyncInterval) {
                        Text("1 minute").tag(60)
                        Text("5 minutes").tag(300)
                        Text("15 minutes").tag(900)
                        Text("30 minutes").tag(1800)
                        Text("1 hour").tag(3600)
                    }
                    .onChange(of: autoSyncInterval) { _, _ in
                        appState.restartAutoSync()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Data Sources Settings

struct DataSourcesSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("claudeCodeEnabled") private var claudeCodeEnabled = true
    @AppStorage("codexEnabled") private var codexEnabled = true
    @AppStorage("opencodeEnabled") private var opencodeEnabled = false
    @AppStorage("geminiCLIEnabled") private var geminiCLIEnabled = false
    @AppStorage("copilotEnabled") private var copilotEnabled = false
    @AppStorage("cursorEnabled") private var cursorEnabled = false

    /// CLI providers from the registry
    private var cliProviders: [ProviderConfiguration] {
        ProviderRegistry.cliProviders
    }

    /// Get binding for a specific provider's enabled state
    private func bindingForProvider(_ provider: Provider) -> Binding<Bool> {
        switch provider {
        case .claudeCode:
            return $claudeCodeEnabled
        case .codex:
            return $codexEnabled
        case .opencode:
            return $opencodeEnabled
        case .geminiCLI:
            return $geminiCLIEnabled
        case .copilot:
            return $copilotEnabled
        case .cursor:
            return $cursorEnabled
        default:
            // Return a constant binding for unsupported/web providers
            return .constant(false)
        }
    }

    var body: some View {
        Form {
            Section("CLI Tools") {
                // Dynamic list from registry
                ForEach(cliProviders, id: \.provider) { config in
                    DynamicDataSourceRow(
                        config: config,
                        count: appState.providerStats[config.provider] ?? 0,
                        isEnabled: bindingForProvider(config.provider),
                        onChange: { enabled in
                            appState.updateLocalSourceConfiguration()
                            // Auto-sync just this provider when enabled
                            if enabled {
                                Task {
                                    await appState.syncAll(localProviders: [config.provider])
                                }
                            }
                        },
                        onSync: {
                            Task {
                                await appState.syncAll(localProviders: [config.provider])
                            }
                        }
                    )
                }
            }

            Section {
                HStack {
                    Image(systemName: "plus.circle")
                        .foregroundColor(.secondary)
                    Text("More providers coming soon")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Link("Request", destination: URL(string: "https://github.com/BayramAnnakov/retain/issues/new?template=provider-request.md")!)
                        .font(.caption)
                }
            }

            Section("File Locations") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Database Location")
                        .font(.headline)
                    Text(getDatabasePath())
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)

                    Button("Open in Finder") {
                        let path = getDatabasePath()
                        let url = URL(fileURLWithPath: path)
                        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
                    }
                }
            }

            Section {
                Button("Rescan All Sources") {
                    Task {
                        await appState.syncAll()
                    }
                }
                .disabled(appState.isSyncing)

                Button("Force Full Sync") {
                    Task {
                        await appState.forceFullSync()
                    }
                }
                .disabled(appState.isSyncing)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func getDatabasePath() -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Retain/retain.sqlite").path
    }
}

// MARK: - Data Source Row

struct DataSourceRow: View {
    let name: String
    let icon: String
    let color: Color
    let path: String
    @Binding var isEnabled: Bool
    let count: Int

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 24)

            VStack(alignment: .leading) {
                Text(name)
                    .font(.headline)
                Text(path)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text("\(count) conversations")
                .font(.caption)
                .foregroundColor(.secondary)

            Toggle("", isOn: $isEnabled)
                .toggleStyle(.switch)
        }
    }
}

// MARK: - Dynamic Data Source Row (Registry-based)

struct DynamicDataSourceRow: View {
    let config: ProviderConfiguration
    let count: Int
    @Binding var isEnabled: Bool
    var onChange: ((Bool) -> Void)?
    var onSync: (() -> Void)?

    var body: some View {
        HStack {
            Image(systemName: config.iconName)
                .foregroundColor(config.brandColor)
                .frame(width: 24)

            VStack(alignment: .leading) {
                Text(config.displayName)
                    .font(.headline)
                Text(config.sourceDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if isEnabled && count == 0 {
                Button("Sync") {
                    onSync?()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Text("\(count) conversations")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Toggle("", isOn: $isEnabled)
                .toggleStyle(.switch)
                .onChange(of: isEnabled) { _, newValue in
                    onChange?(newValue)
                }
        }
    }
}

// MARK: - Web Accounts Settings

struct WebAccountsSettingsView: View {
    @EnvironmentObject private var appState: AppState

    private var claudeSessionState: WebSyncEngine.SessionState {
        appState.webSyncEngine.getSessionState(for: .claudeWeb)
    }

    private var chatgptSessionState: WebSyncEngine.SessionState {
        appState.webSyncEngine.getSessionState(for: .chatgptWeb)
    }

    private var sessionExpiredNotification: WebSyncEngine.SessionExpiredNotification? {
        appState.webSyncEngine.sessionExpiredNotification
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.blue)
                        Text("First, sign into claude.ai or chatgpt.com in your browser.")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    Text("Then click Connect to import your session. Retain reads cookies from Safari, Chrome, or Firefox. If one browser fails, try another.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if let notification = sessionExpiredNotification {
                Section {
                    InlineWarningBanner(
                        message: "\(notification.provider.displayName) session expired (~30 days). Already-synced conversations are safe. Sign in again in your browser, then reconnect.",
                        primaryActionTitle: "Reconnect",
                        onPrimaryAction: { connect(provider: notification.provider) },
                        onDismiss: { appState.webSyncEngine.clearSessionExpiredNotification() }
                    )
                }
            }

            Section {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        KeychainInfoRow(
                            icon: "key.fill",
                            title: "Keychain Access",
                            description: "Chrome-based browsers encrypt cookies. Retain needs permission to read the encryption key from your Keychain."
                        )
                        KeychainInfoRow(
                            icon: "externaldrive.fill",
                            title: "Full Disk Access",
                            description: "Safari stores cookies in a protected location. Grant Full Disk Access in System Settings → Privacy & Security.",
                            actionTitle: "Open System Settings",
                            action: {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        )
                        KeychainInfoRow(
                            icon: "lock.shield.fill",
                            title: "Your Data Stays Local",
                            description: "Cookies are only used to authenticate with claude.ai and chatgpt.com. No data is sent to third parties."
                        )
                    }
                    .padding(.vertical, Spacing.xs)
                } label: {
                    Label("Why permissions are needed", systemImage: "questionmark.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section("Claude.ai") {
                WebAccountRowView(
                    name: "Claude.ai",
                    icon: "globe",
                    color: .orange,
                    sessionState: claudeSessionState,
                    onConnect: { connect(provider: .claudeWeb) },
                    onVerify: { verifySession(provider: .claudeWeb) },
                    onDisconnect: { appState.webSyncEngine.disconnect(provider: .claudeWeb) },
                    onSync: { Task { await appState.syncWeb(provider: .claudeWeb) } }
                )
            }

            Section("ChatGPT") {
                WebAccountRowView(
                    name: "ChatGPT",
                    icon: "bubble.left.and.bubble.right",
                    color: .green,
                    sessionState: chatgptSessionState,
                    onConnect: { connect(provider: .chatgptWeb) },
                    onVerify: { verifySession(provider: .chatgptWeb) },
                    onDisconnect: { appState.webSyncEngine.disconnect(provider: .chatgptWeb) },
                    onSync: { Task { await appState.syncWeb(provider: .chatgptWeb) } }
                )
            }

            Section("Manual Import") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Import conversation exports")
                        .font(.headline)
                    Text("You can import JSON exports from ChatGPT or Claude.ai Settings → Export")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button("Import JSON File...") {
                        importJSONFile()
                    }
                    .disabled(true)
                    .help("Coming soon in a future release")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func connect(provider: Provider) {
        Task {
            await appState.webSyncEngine.importBrowserCookies(for: provider)
        }
    }

    private func verifySession(provider: Provider) {
        Task {
            await appState.webSyncEngine.verifySession(for: provider)
        }
    }

    private func importJSONFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = true

        if panel.runModal() == .OK {
            for url in panel.urls {
                // TODO: Import logic
                print("Import: \(url)")
            }
        }
    }
}

// MARK: - Web Account Row

struct WebAccountRowView: View {
    let name: String
    let icon: String
    let color: Color
    let sessionState: WebSyncEngine.SessionState
    let onConnect: () -> Void
    let onVerify: () -> Void
    let onDisconnect: () -> Void
    let onSync: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    private var statusText: String {
        switch sessionState {
        case .notConnected:
            return "Not connected"
        case .connecting:
            return "Verifying..."
        case .sessionSaved:
            return "Session saved (not verified)"
        case .connected(let email):
            return email ?? "Connected"
        case .error(let message):
            return "Error: \(message)"
        }
    }

    private var statusColor: Color {
        switch sessionState {
        case .connected:
            return AppColors.statusTextColor(.success, colorScheme: colorScheme)
        case .sessionSaved:
            return AppColors.statusTextColor(.warning, colorScheme: colorScheme)
        case .error:
            return AppColors.statusTextColor(.error, colorScheme: colorScheme)
        default:
            return .secondary
        }
    }

    private var statusIcon: String {
        switch sessionState {
        case .connected:
            return "checkmark.circle.fill"
        case .sessionSaved:
            return "clock.badge.questionmark"
        case .error:
            return "exclamationmark.triangle.fill"
        case .connecting:
            return "arrow.triangle.2.circlepath"
        case .notConnected:
            return "xmark.circle"
        }
    }

    private var isConnected: Bool {
        if case .connected = sessionState { return true }
        return false
    }

    private var isSessionSaved: Bool {
        if case .sessionSaved = sessionState { return true }
        return false
    }

    private var isConnecting: Bool {
        if case .connecting = sessionState { return true }
        return false
    }

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.headline)

                HStack(spacing: 4) {
                    if isConnecting {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 12, height: 12)
                    } else {
                        Image(systemName: statusIcon)
                            .font(.caption)
                    }
                    Text(statusText)
                        .font(.caption)
                }
                .foregroundColor(statusColor)
                .help(isSessionSaved ? "Session cookies exist but haven't been verified with the server recently. Click Verify to confirm the session is still valid." : "")
            }

            Spacer()

            if isConnected {
                if let onSync {
                    Button("Sync") {
                        onSync()
                    }
                }

                Button("Disconnect") {
                    onDisconnect()
                }
                .foregroundColor(.red)
            } else if isSessionSaved {
                Button("Verify") {
                    onVerify()
                }
                .buttonStyle(.bordered)

                Button("Disconnect") {
                    onDisconnect()
                }
                .foregroundColor(.red)
            } else {
                Button("Connect") {
                    onConnect()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isConnecting)
            }
        }
    }
}

// MARK: - Learnings Settings

struct LearningsSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("autoExtractLearnings") private var autoExtractLearnings = true
    @AppStorage("learningConfidenceThreshold") private var learningConfidenceThreshold = 0.8
    @AppStorage("learningExtractionMode") private var learningExtractionMode: LearningExtractionMode = .semantic
    @AppStorage("includeImplicitLearnings") private var includeImplicitLearnings = false
    @State private var showExportSheet = false

    var body: some View {
        Form {
            Section {
                Toggle("Auto-extract learnings from corrections", isOn: $autoExtractLearnings)

                VStack(alignment: .leading) {
                    Text("Confidence threshold: \(Int(learningConfidenceThreshold * 100))%")
                    Slider(value: $learningConfidenceThreshold, in: 0.5...0.95, step: 0.05)
                        .onChange(of: learningConfidenceThreshold) { _, _ in
                            appState.updateLearningConfidenceThreshold()
                        }
                }

                Toggle("Include implicit positive learnings (heuristic)", isOn: $includeImplicitLearnings)
                    .onChange(of: includeImplicitLearnings) { _, _ in
                        appState.updateImplicitLearningPreference()
                    }
                Text("May add noise; requires review. Best kept off unless needed.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Learning Extraction") {
                Picker("Extraction mode", selection: $learningExtractionMode) {
                    ForEach(LearningExtractionMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: learningExtractionMode) { _, _ in
                    appState.updateLearningExtractionMode()
                }

                Text(learningExtractionMode.description)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if learningExtractionMode != .deterministic && !appState.geminiWorkflowEnabled {
                    Label("Enable Gemini in AI Features for AI-powered extraction", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundColor(.orange)
                } else if learningExtractionMode != .deterministic && appState.geminiApiKey.isEmpty {
                    Label("Set Gemini API key in AI Features", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            Section("Pending Learnings") {
                HStack {
                    Text("Learnings awaiting review")
                    Spacer()
                    Text("\(appState.pendingLearningsCount)")
                        .font(.title2)
                        .fontWeight(.bold)
                }

                Button("Review Learnings") {
                    appState.activeView = .learnings
                    // Close settings window
                    NSApplication.shared.keyWindow?.close()
                }
                .disabled(appState.pendingLearningsCount == 0)
            }

            Section("Export") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Export to CLAUDE.md")
                        .font(.headline)
                    Text("Export approved learnings to your project's CLAUDE.md file")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button("Export Learnings...") {
                        showExportSheet = true
                    }
                    .disabled(appState.learningQueue.approvedLearnings.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .sheet(isPresented: $showExportSheet) {
            ExportLearningsSheet(learnings: appState.learningQueue.approvedLearnings)
        }
    }
}

// MARK: - AI Features Settings

struct AIFeaturesSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("geminiWorkflowEnabled") private var geminiEnabled = false
    @AppStorage("geminiWorkflowModel") private var geminiModel = "gemini-3-flash-preview"
    @AppStorage("learningExtractionMode") private var learningExtractionMode: LearningExtractionMode = .semantic
    @State private var geminiApiKeyInput = ""
    @State private var activeSearchProvider = "Checking..."
    @State private var showAdvanced = false
    @State private var showResetConfirmation = false
    @State private var showClearEmbeddingsConfirmation = false

    // Gemini API key validation state
    enum ApiKeyValidationState: Equatable {
        case idle
        case typing       // User is still typing (debounce period)
        case validating   // Actually making API call
        case valid
        case invalid(String)
        case networkError(String)
    }
    @State private var apiKeyValidationState: ApiKeyValidationState = .idle
    @State private var validationTask: Task<Void, Never>?

    // Search settings
    @AppStorage("semanticSearchEnabled") private var semanticSearchEnabled = true

    // Ollama settings (advanced)
    @AppStorage("preferOllama") private var preferOllama = false
    @AppStorage("ollamaModel") private var ollamaModel = "embeddinggemma"
    @AppStorage("ollamaEndpoint") private var ollamaEndpoint = "http://localhost:11434"
    @State private var ollamaStatus = "Not checked"

    var body: some View {
        Form {
            // MARK: - CLI LLM Analysis (Claude Code / Codex)
            CLILLMSettingsView()

            // MARK: - Gemini (Cloud AI)
            Section {
                Toggle("Enable Gemini", isOn: $geminiEnabled)
                    .onChange(of: geminiEnabled) { _, newValue in
                        appState.updateGeminiConfiguration()
                        // Auto-switch to smart mode when enabling Gemini
                        if newValue && learningExtractionMode == .deterministic {
                            learningExtractionMode = .semantic
                            appState.updateLearningExtractionMode()
                        }
                    }

                if geminiEnabled {
                    HStack {
                        SecureField("API Key", text: $geminiApiKeyInput)
                            .onChange(of: geminiApiKeyInput) { _, newValue in
                                appState.setGeminiApiKey(newValue)
                                // Debounced validation
                                validationTask?.cancel()
                                if newValue.isEmpty {
                                    apiKeyValidationState = .idle
                                } else {
                                    apiKeyValidationState = .typing  // Show typing state during debounce
                                    validationTask = Task {
                                        // Debounce: wait 500ms before validating
                                        try? await Task.sleep(nanoseconds: 500_000_000)
                                        guard !Task.isCancelled else { return }
                                        await MainActor.run {
                                            apiKeyValidationState = .validating  // Now actually validating
                                        }
                                        await validateApiKey(newValue)
                                    }
                                }
                            }
                            .onAppear {
                                geminiApiKeyInput = appState.geminiApiKey
                                // Validate existing key on appear
                                if !geminiApiKeyInput.isEmpty {
                                    Task { await validateApiKey(geminiApiKeyInput) }
                                }
                            }

                        // Validation status indicator
                        apiKeyStatusView
                    }

                    // Show validation feedback
                    if case .invalid(let message) = apiKeyValidationState {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundColor(.red)
                    } else if case .networkError(let message) = apiKeyValidationState {
                        Label(message, systemImage: "wifi.slash")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }

                    TextField("Model", text: $geminiModel)
                        .onChange(of: geminiModel) { _, _ in
                            appState.updateGeminiConfiguration()
                        }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Powers:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("  \u{2022} Learning extraction from conversations")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("  \u{2022} Workflow/automation classification")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundColor(.blue)
                    Text("Learning extraction sends last 10 messages to Google. Workflow sends title, preview, and first message. API key stored in Keychain.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                HStack {
                    Text("Gemini (Cloud AI)")
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

            // MARK: - Search (Local)
            Section {
                Toggle("Enable Smart Search", isOn: $semanticSearchEnabled)
                    .help("Uses on-device ML to find semantically similar content, not just exact matches")

                if semanticSearchEnabled {
                    HStack {
                        Text("Status")
                        Spacer()
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.caption)
                            Text(activeSearchProvider)
                                .foregroundColor(.secondary)
                        }
                    }
                    .task {
                        await checkActiveProvider()
                    }

                    Text("Uses Apple's on-device ML to find semantically similar content. All processing happens locally on your Mac.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("When disabled, search uses full-text matching only (faster but less intelligent).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                HStack {
                    Text("Search")
                    Spacer()
                    Text("LOCAL")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundColor(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.15))
                        .cornerRadius(4)
                }
            }

            // MARK: - Advanced (Collapsible)
            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    // Ollama settings
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Prefer Ollama for embeddings", isOn: $preferOllama)
                                .onChange(of: preferOllama) { _, _ in
                                    appState.updateOllamaConfiguration()
                                    Task { await checkActiveProvider() }
                                }

                            if preferOllama {
                                TextField("Endpoint", text: $ollamaEndpoint)
                                    .textFieldStyle(.roundedBorder)
                                    .onChange(of: ollamaEndpoint) { _, _ in
                                        appState.updateOllamaConfiguration()
                                    }

                                Picker("Model", selection: $ollamaModel) {
                                    Text("embeddinggemma").tag("embeddinggemma")
                                    Text("nomic-embed-text").tag("nomic-embed-text")
                                    Text("all-minilm").tag("all-minilm")
                                    Text("mxbai-embed-large").tag("mxbai-embed-large")
                                }

                                HStack {
                                    Text("Status: \(ollamaStatus)")
                                        .font(.caption)
                                        .foregroundColor(ollamaStatus.contains("Connected") ? .green : .secondary)
                                    Spacer()
                                    Button("Test") { testOllamaConnection() }
                                        .buttonStyle(.link)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    } label: {
                        Label("Ollama (Optional)", systemImage: "server.rack")
                    }

                    // Database
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Button("Rebuild Embeddings") {
                                Task { try? await appState.semanticSearch.indexAllConversations() }
                            }
                            .buttonStyle(.link)

                            Button("Clear All Embeddings") {
                                showClearEmbeddingsConfirmation = true
                            }
                            .buttonStyle(.link)
                            .foregroundColor(.red)
                        }
                        .padding(.vertical, 4)
                    } label: {
                        Label("Database", systemImage: "cylinder")
                    }

                    // Debug
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Button("Open Logs Folder") {
                                let logsPath = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
                                    .appendingPathComponent("Logs/Retain")
                                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: logsPath.path)
                            }
                            .buttonStyle(.link)

                            Button("Export Debug Info") { exportDebugInfo() }
                                .buttonStyle(.link)
                        }
                        .padding(.vertical, 4)
                    } label: {
                        Label("Debug", systemImage: "ladybug")
                    }

                    // Danger zone
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Button("Reset App State") {
                                showResetConfirmation = true
                            }
                            .foregroundColor(.red)

                            Text("Deletes all local data and shows onboarding again")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    } label: {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("Danger Zone")
                        }
                    }
                }
                .padding(.top, 8)
            }
        }
        .formStyle(.grouped)
        .padding()
        .alert("Reset Retain?", isPresented: $showResetConfirmation) {
            Button("Reset", role: .destructive) {
                Task { await appState.resetAppState() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will delete all local conversations, learnings, workflow candidates, and web sessions. You will see onboarding again.")
        }
        .alert("Clear All Embeddings?", isPresented: $showClearEmbeddingsConfirmation) {
            Button("Clear", role: .destructive) {
                try? appState.semanticSearch.clearAllEmbeddings()
                Task { await checkActiveProvider() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will delete all search embeddings. They will be rebuilt automatically when needed.")
        }
    }

    private func checkActiveProvider() async {
        let available = await appState.semanticSearch.checkAvailability()
        await MainActor.run {
            activeSearchProvider = available ? appState.semanticSearch.activeProviderName : "None available"
        }
    }

    private func testOllamaConnection() {
        ollamaStatus = "Testing..."
        Task {
            do {
                let url = URL(string: "\(ollamaEndpoint)/api/tags")!
                let (data, response) = try await URLSession.shared.data(from: url)
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    // Check if the selected model is available
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let models = json["models"] as? [[String: Any]] {
                        let modelNames = models.compactMap { $0["name"] as? String }
                        let hasModel = modelNames.contains { $0.contains(ollamaModel) }
                        await MainActor.run {
                            if hasModel {
                                ollamaStatus = "Connected (\(ollamaModel) ready)"
                            } else {
                                ollamaStatus = "Connected (model not found)"
                            }
                        }
                    } else {
                        await MainActor.run {
                            ollamaStatus = "Connected"
                        }
                    }
                } else {
                    await MainActor.run {
                        ollamaStatus = "Connection failed"
                    }
                }
            } catch {
                await MainActor.run {
                    ollamaStatus = "Error: \(error.localizedDescription)"
                }
            }
        }
    }

    private func exportDebugInfo() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Retain-Debug-\(ISO8601DateFormatter().string(from: Date())).txt"

        if panel.runModal() == .OK, let url = panel.url {
            var info = """
            Retain Debug Info
            =================
            Generated: \(Date())

            System
            ------
            macOS Version: \(ProcessInfo.processInfo.operatingSystemVersionString)
            App Version: 0.1.0-alpha

            Database
            --------
            Path: ~/Library/Application Support/Retain/retain.sqlite

            Conversations
            -------------
            """

            for (provider, count) in appState.providerStats.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                info += "\n\(provider.displayName): \(count)"
            }
            info += "\nTotal: \(appState.conversations.count)"

            info += """


            Learnings
            ---------
            Pending: \(appState.pendingLearningsCount)
            Approved: \(appState.learningQueue.approvedLearnings.count)

            Configuration
            -------------
            Ollama Preferred: \(preferOllama)
            Ollama Endpoint: \(ollamaEndpoint)
            Ollama Model: \(ollamaModel)
            Gemini Enabled: \(geminiEnabled)
            Gemini Model: \(geminiModel)
            Active Search Provider: \(activeSearchProvider)

            Web Sync
            --------
            Claude.ai: \(appState.webSyncEngine.claudeConnectionStatus.isConnected ? "Connected" : "Not connected")
            ChatGPT: \(appState.webSyncEngine.chatgptConnectionStatus.isConnected ? "Connected" : "Not connected")
            """

            do {
                try info.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                print("Failed to export debug info: \(error)")
            }
        }
    }

    // MARK: - API Key Validation

    @ViewBuilder
    private var apiKeyStatusView: some View {
        switch apiKeyValidationState {
        case .idle:
            EmptyView()
        case .typing:
            // Subtle indicator while user is still typing
            Image(systemName: "pencil")
                .foregroundColor(.secondary)
                .font(.caption)
                .help("Waiting for you to finish typing...")
        case .validating:
            ProgressView()
                .scaleEffect(0.7)
                .frame(width: 20, height: 20)
                .help("Verifying API key...")
        case .valid:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .help("API key is valid")
        case .invalid:
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.red)
                .help("API key is invalid")
        case .networkError:
            Image(systemName: "wifi.slash")
                .foregroundColor(.orange)
                .help("Could not verify API key (network error)")
        }
    }

    private func validateApiKey(_ apiKey: String) async {
        let result = await GeminiClient.validateApiKey(apiKey)

        await MainActor.run {
            switch result {
            case .valid:
                apiKeyValidationState = .valid
            case .invalid(let message):
                apiKeyValidationState = .invalid(message)
            case .networkError(let message):
                apiKeyValidationState = .networkError(message)
            }
        }
    }
}

// MARK: - Web Login View (Placeholder)

struct WebLoginView: View {
    let provider: Provider
    @Binding var isConnected: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Text("Connect to \(provider.displayName)")
                .font(.title)

            Text("A web view will open for you to sign in. Your session will be saved securely.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            // Placeholder - WebView will be added in Phase 2
            Rectangle()
                .fill(Color.secondary.opacity(0.1))
                .frame(height: 400)
                .overlay {
                    Text("WebView Login (Coming Soon)")
                        .foregroundColor(.secondary)
                }

            HStack {
                Button("Cancel") {
                    dismiss()
                }

                Spacer()

                Button("Done") {
                    isConnected = true
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 500, height: 550)
    }
}

// MARK: - Keychain Info Row

/// Helper view for displaying permission explanations
private struct KeychainInfoRow: View {
    let icon: String
    let title: String
    let description: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: IconSize.md))
                .foregroundColor(.accentColor)
                .frame(width: IconSize.lg)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppFont.caption)
                    .fontWeight(.medium)
                Text(description)
                    .font(AppFont.caption)
                    .foregroundColor(AppColors.secondaryText)
                if let actionTitle, let action {
                    Button(actionTitle) {
                        action()
                    }
                    .font(AppFont.caption)
                    .buttonStyle(.link)
                }
            }
        }
    }
}

private struct InlineWarningBanner: View {
    let message: String
    let primaryActionTitle: String
    let onPrimaryAction: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.system(size: 14, weight: .semibold))

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(message)
                    .font(.caption)
                    .foregroundColor(AppColors.primaryText)

                HStack(spacing: Spacing.sm) {
                    Button(primaryActionTitle) {
                        onPrimaryAction()
                    }
                    .buttonStyle(.bordered)

                    Button("Dismiss", role: .cancel) {
                        onDismiss()
                    }
                    .buttonStyle(.bordered)
                }
            }

            Spacer()
        }
        .padding(.vertical, Spacing.xs)
    }
}

// MARK: - Diagnostics Settings

struct DiagnosticsSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var diagnosticInfo: [ProviderDiagnostic] = []
    @State private var isLoading = false
    @State private var syncLogs: [String] = []

    struct ProviderDiagnostic: Identifiable {
        let id = UUID()
        let provider: Provider
        let name: String
        let isEnabled: Bool
        let paths: [PathInfo]
        let conversationCount: Int

        struct PathInfo: Identifiable {
            let id = UUID()
            let path: String
            let exists: Bool
            let fileCount: Int
        }
    }

    var body: some View {
        Form {
            Section("Provider Paths") {
                if isLoading {
                    ProgressView("Scanning paths...")
                } else if diagnosticInfo.isEmpty {
                    Button("Run Diagnostics") {
                        runDiagnostics()
                    }
                } else {
                    ForEach(diagnosticInfo) { diag in
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(diag.paths) { pathInfo in
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: pathInfo.exists ? "checkmark.circle.fill" : "xmark.circle.fill")
                                            .foregroundColor(pathInfo.exists ? .green : .red)
                                            .font(.caption)

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(pathInfo.path)
                                                .font(.system(.caption, design: .monospaced))
                                                .textSelection(.enabled)
                                            if pathInfo.exists {
                                                Text("\(pathInfo.fileCount) files found")
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                            } else {
                                                Text("Path not found")
                                                    .font(.caption2)
                                                    .foregroundColor(.red)
                                            }
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                            .padding(.vertical, 4)
                        } label: {
                            HStack {
                                Image(systemName: diag.isEnabled ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(diag.isEnabled ? .green : .secondary)
                                Text(diag.name)
                                    .fontWeight(.medium)
                                Spacer()
                                Text("\(diag.conversationCount) conversations")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    Button("Refresh") {
                        runDiagnostics()
                    }
                    .padding(.top, 8)
                }
            }

            Section("Sync Logs") {
                if syncLogs.isEmpty {
                    Text("No recent sync activity")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(syncLogs, id: \.self) { log in
                                Text(log)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                }

                Button("Copy Logs") {
                    let logText = syncLogs.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(logText, forType: .string)
                }
                .disabled(syncLogs.isEmpty)
            }

            Section("Spotlight Integration") {
                Toggle("Index conversations in Spotlight", isOn: Binding(
                    get: { appState.spotlightIndexingEnabled },
                    set: { appState.spotlightIndexingEnabled = $0 }
                ))
                .help("Allow searching Retain conversations from system Spotlight")

                HStack {
                    Button("Reindex Spotlight") {
                        Task {
                            await appState.reindexSpotlight()
                        }
                    }
                    .disabled(!appState.spotlightIndexingEnabled)

                    Button("Clear Index", role: .destructive) {
                        Task {
                            await appState.clearSpotlightIndex()
                        }
                    }
                    .disabled(!appState.spotlightIndexingEnabled)
                }
            }

            Section("Debug Actions") {
                Button("Export Diagnostic Report") {
                    exportDiagnosticReport()
                }

                Button("Clear Database Cache", role: .destructive) {
                    // Placeholder for cache clearing
                }
                .disabled(true)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            runDiagnostics()
        }
    }

    private func runDiagnostics() {
        isLoading = true
        diagnosticInfo = []
        syncLogs = []

        Task {
            var results: [ProviderDiagnostic] = []
            let fm = FileManager.default
            let home = fm.homeDirectoryForCurrentUser

            // Claude Code (handle symlinks)
            let claudeCodePath = home.appendingPathComponent(".claude/projects")
            let claudeCodeResolved = claudeCodePath.resolvingSymlinksInPath()
            let isSymlink = claudeCodePath.path != claudeCodeResolved.path
            let claudeCodeExists = fm.fileExists(atPath: claudeCodeResolved.path)
            let claudeCodeFiles = claudeCodeExists ? (try? fm.contentsOfDirectory(atPath: claudeCodeResolved.path))?.count ?? 0 : 0
            var claudeCodePaths = [ProviderDiagnostic.PathInfo(path: claudeCodePath.path + (isSymlink ? " (symlink)" : ""), exists: claudeCodeExists, fileCount: claudeCodeFiles)]
            if isSymlink {
                claudeCodePaths.append(ProviderDiagnostic.PathInfo(path: "→ \(claudeCodeResolved.path)", exists: claudeCodeExists, fileCount: 0))
            }
            results.append(ProviderDiagnostic(
                provider: .claudeCode,
                name: "Claude Code",
                isEnabled: UserDefaults.standard.bool(forKey: "claudeCodeEnabled"),
                paths: claudeCodePaths,
                conversationCount: appState.providerStats[.claudeCode] ?? 0
            ))
            syncLogs.append("[\(Date().formatted(date: .omitted, time: .standard))] Checked Claude Code: \(claudeCodeResolved.path)\(isSymlink ? " (symlink)" : "")")

            // Codex
            let codexPath = home.appendingPathComponent(".codex")
            let codexExists = fm.fileExists(atPath: codexPath.path)
            let codexFiles = codexExists ? (try? fm.contentsOfDirectory(atPath: codexPath.path))?.count ?? 0 : 0
            results.append(ProviderDiagnostic(
                provider: .codex,
                name: "Codex CLI",
                isEnabled: UserDefaults.standard.bool(forKey: "codexEnabled"),
                paths: [ProviderDiagnostic.PathInfo(path: codexPath.path, exists: codexExists, fileCount: codexFiles)],
                conversationCount: appState.providerStats[.codex] ?? 0
            ))
            syncLogs.append("[\(Date().formatted(date: .omitted, time: .standard))] Checked Codex: \(codexPath.path)")

            // Cursor
            let cursorWorkspace = home.appendingPathComponent("Library/Application Support/Cursor/User/workspaceStorage")
            let cursorGlobal = home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage")
            let cursorWsExists = fm.fileExists(atPath: cursorWorkspace.path)
            let cursorGsExists = fm.fileExists(atPath: cursorGlobal.path)

            var cursorWsFiles = 0
            if cursorWsExists, let dirs = try? fm.contentsOfDirectory(atPath: cursorWorkspace.path) {
                for dir in dirs {
                    let dbPath = cursorWorkspace.appendingPathComponent(dir).appendingPathComponent("state.vscdb")
                    if fm.fileExists(atPath: dbPath.path) {
                        cursorWsFiles += 1
                    }
                }
            }
            let cursorGsFiles = cursorGsExists && fm.fileExists(atPath: cursorGlobal.appendingPathComponent("state.vscdb").path) ? 1 : 0

            results.append(ProviderDiagnostic(
                provider: .cursor,
                name: "Cursor",
                isEnabled: UserDefaults.standard.bool(forKey: "cursorEnabled"),
                paths: [
                    ProviderDiagnostic.PathInfo(path: cursorWorkspace.path, exists: cursorWsExists, fileCount: cursorWsFiles),
                    ProviderDiagnostic.PathInfo(path: cursorGlobal.path, exists: cursorGsExists, fileCount: cursorGsFiles)
                ],
                conversationCount: appState.providerStats[.cursor] ?? 0
            ))
            syncLogs.append("[\(Date().formatted(date: .omitted, time: .standard))] Checked Cursor: \(cursorWsFiles) workspace DBs, \(cursorGsFiles) global DB")

            // OpenCode
            let opencodePath = home.appendingPathComponent(".local/share/opencode/storage")
            let opencodeExists = fm.fileExists(atPath: opencodePath.path)
            let opencodeFiles = opencodeExists ? (try? fm.contentsOfDirectory(atPath: opencodePath.path))?.count ?? 0 : 0
            results.append(ProviderDiagnostic(
                provider: .opencode,
                name: "OpenCode",
                isEnabled: UserDefaults.standard.bool(forKey: "opencodeEnabled"),
                paths: [ProviderDiagnostic.PathInfo(path: opencodePath.path, exists: opencodeExists, fileCount: opencodeFiles)],
                conversationCount: appState.providerStats[.opencode] ?? 0
            ))

            // Gemini CLI
            let geminiPath = home.appendingPathComponent(".gemini")
            let geminiExists = fm.fileExists(atPath: geminiPath.path)
            let geminiFiles = geminiExists ? (try? fm.contentsOfDirectory(atPath: geminiPath.path))?.count ?? 0 : 0
            results.append(ProviderDiagnostic(
                provider: .geminiCLI,
                name: "Gemini CLI",
                isEnabled: UserDefaults.standard.bool(forKey: "geminiCLIEnabled"),
                paths: [ProviderDiagnostic.PathInfo(path: geminiPath.path, exists: geminiExists, fileCount: geminiFiles)],
                conversationCount: appState.providerStats[.geminiCLI] ?? 0
            ))

            // Copilot CLI
            let copilotPath = home.appendingPathComponent(".copilot")
            let copilotExists = fm.fileExists(atPath: copilotPath.path)
            let copilotFiles = copilotExists ? (try? fm.contentsOfDirectory(atPath: copilotPath.path))?.count ?? 0 : 0
            results.append(ProviderDiagnostic(
                provider: .copilot,
                name: "GitHub Copilot CLI",
                isEnabled: UserDefaults.standard.bool(forKey: "copilotEnabled"),
                paths: [ProviderDiagnostic.PathInfo(path: copilotPath.path, exists: copilotExists, fileCount: copilotFiles)],
                conversationCount: appState.providerStats[.copilot] ?? 0
            ))

            await MainActor.run {
                diagnosticInfo = results
                isLoading = false
                syncLogs.append("[\(Date().formatted(date: .omitted, time: .standard))] Diagnostics complete")
            }
        }
    }

    private func exportDiagnosticReport() {
        var report = "Retain Diagnostic Report\n"
        report += "Generated: \(Date().formatted())\n\n"

        for diag in diagnosticInfo {
            report += "## \(diag.name)\n"
            report += "Enabled: \(diag.isEnabled)\n"
            report += "Conversations: \(diag.conversationCount)\n"
            for path in diag.paths {
                report += "  Path: \(path.path)\n"
                report += "  Exists: \(path.exists), Files: \(path.fileCount)\n"
            }
            report += "\n"
        }

        report += "## Sync Logs\n"
        report += syncLogs.joined(separator: "\n")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState())
}
