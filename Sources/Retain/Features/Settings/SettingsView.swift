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

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .general: return "gear"
            case .dataSources: return "externaldrive"
            case .webAccounts: return "globe"
            case .learnings: return "lightbulb"
            case .aiFeatures: return "sparkles"
            }
        }

        var color: Color {
            switch self {
            case .general: return .gray
            case .dataSources: return .blue
            case .webAccounts: return .green
            case .learnings: return .orange
            case .aiFeatures: return .purple
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

    var body: some View {
        Form {
            Section("CLI Tools") {
                DataSourceRow(
                    name: "Claude Code",
                    icon: "terminal",
                    color: .orange,
                    path: "~/.claude/projects/",
                    isEnabled: $claudeCodeEnabled,
                    count: appState.providerStats[.claudeCode] ?? 0
                )
                .onChange(of: claudeCodeEnabled) { _, _ in
                    appState.updateLocalSourceConfiguration()
                }

                DataSourceRow(
                    name: "Codex",
                    icon: "command",
                    color: .blue,
                    path: "~/.codex/sessions/",
                    isEnabled: $codexEnabled,
                    count: appState.providerStats[.codex] ?? 0
                )
                .onChange(of: codexEnabled) { _, _ in
                    appState.updateLocalSourceConfiguration()
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
            return .green
        case .sessionSaved:
            return .orange
        case .error:
            return .red
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
        case validating
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
                                    apiKeyValidationState = .validating
                                    validationTask = Task {
                                        // Debounce: wait 500ms before validating
                                        try? await Task.sleep(nanoseconds: 500_000_000)
                                        guard !Task.isCancelled else { return }
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
                VStack(alignment: .leading, spacing: 16) {
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
        case .validating:
            ProgressView()
                .scaleEffect(0.7)
                .frame(width: 20, height: 20)
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

#Preview {
    SettingsView()
        .environmentObject(AppState())
}
