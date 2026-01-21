import SwiftUI
import WebKit

/// WebView-based login for web providers
struct WebLoginSheet: View {
    let provider: Provider
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    @State private var webViewRef: WKWebView?
    @State private var isLoading = true
    @State private var error: String?
    @State private var currentURL: URL?
    @State private var hasHandledLoginSuccess = false

    private var loginURL: URL {
        switch provider {
        case .claudeWeb:
            return URL(string: "https://claude.ai/login")!
        case .chatgptWeb:
            return URL(string: "https://chatgpt.com/auth/login")!
        default:
            return URL(string: "https://example.com")!
        }
    }

    private var successHostSuffix: String {
        switch provider {
        case .claudeWeb:
            return "claude.ai"
        case .chatgptWeb:
            return "chatgpt.com"
        default:
            return ""
        }
    }

    private var successPathPrefixes: [String] {
        switch provider {
        case .claudeWeb:
            return ["/new", "/chats", "/chat"]
        case .chatgptWeb:
            return ["/", "/c"]
        default:
            return []
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: provider.iconName)
                    .foregroundColor(provider.color)
                    .font(.title2)

                Text("Sign in to \(provider.displayName)")
                    .font(.headline)

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // WebView
            ZStack {
                WebViewContainer(
                    url: loginURL,
                    onURLChange: handleURLChange,
                    onLoadingChange: { loading in
                        isLoading = loading
                        if loading {
                            error = nil
                        }
                    },
                    onError: { error = $0 },
                    onWebViewCreated: { webViewRef = $0 }
                )

                if isLoading {
                    ProgressView()
                        .scaleEffect(1.5)
                }

                if let error = error {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.orange)

                        Text(error)
                            .foregroundColor(.secondary)

                        Button("Retry") {
                            self.error = nil
                            isLoading = true
                            webViewRef?.reload()
                        }
                    }
                    .padding()
                    .background(.regularMaterial)
                    .cornerRadius(12)
                }
            }

            Divider()

            // Footer
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    if let url = currentURL {
                        Text(url.host ?? "")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Text("Sign in with your \(provider.displayName) account")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button("Continue") {
                    handleLoginSuccess()
                }
                .buttonStyle(.borderedProminent)
                .disabled(webViewRef == nil)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 500, height: 650)
    }

    private func handleURLChange(_ url: URL) {
        currentURL = url

        guard isSuccessURL(url) else { return }

        // Small delay to ensure cookies are set
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            handleLoginSuccess()
        }
    }

    private func handleLoginSuccess() {
        guard !hasHandledLoginSuccess else { return }
        hasHandledLoginSuccess = true

        Task {
            guard let webView = webViewRef else {
                error = "WebView not available"
                hasHandledLoginSuccess = false
                return
            }

            // Call WebSyncEngine to handle login completion
            await appState.webSyncEngine.handleLoginComplete(for: provider, webView: webView)

            await MainActor.run {
                let status: WebSyncEngine.ConnectionStatus
                switch provider {
                case .claudeWeb:
                    status = appState.webSyncEngine.claudeConnectionStatus
                case .chatgptWeb:
                    status = appState.webSyncEngine.chatgptConnectionStatus
                default:
                    status = .disconnected
                }

                if case .connected = status {
                    dismiss()
                } else {
                    error = "Login not confirmed yet. Please finish sign-in and try again."
                    hasHandledLoginSuccess = false
                }
            }
        }
    }

    private func isSuccessURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let suffix = successHostSuffix
        guard !suffix.isEmpty else { return false }

        let hostMatches = host == suffix || host.hasSuffix("." + suffix)
        let path = url.path.lowercased()
        let isAuthPath = path.contains("login") || path.contains("auth")
        let isChallengePath = path.contains("cdn-cgi")
        let matchesPath = successPathPrefixes.contains { prefix in
            if prefix == "/" {
                return path == "/"
            }
            return path == prefix || path.hasPrefix(prefix + "/")
        }

        return hostMatches && matchesPath && !isAuthPath && !isChallengePath
    }
}

// MARK: - WebView Container

struct WebViewContainer: NSViewRepresentable {
    let url: URL
    let onURLChange: (URL) -> Void
    let onLoadingChange: (Bool) -> Void
    let onError: (String) -> Void
    let onWebViewCreated: ((WKWebView) -> Void)?

    init(
        url: URL,
        onURLChange: @escaping (URL) -> Void,
        onLoadingChange: @escaping (Bool) -> Void,
        onError: @escaping (String) -> Void,
        onWebViewCreated: ((WKWebView) -> Void)? = nil
    ) {
        self.url = url
        self.onURLChange = onURLChange
        self.onLoadingChange = onLoadingChange
        self.onError = onError
        self.onWebViewCreated = onWebViewCreated
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        // Enable JavaScript
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        config.defaultWebpagePreferences = preferences

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator

        // Enable inspector for debugging (only in debug builds)
        #if DEBUG
        webView.configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        #endif

        // Load the login URL
        webView.load(URLRequest(url: url))

        // Pass webView reference to parent
        DispatchQueue.main.async {
            onWebViewCreated?(webView)
        }

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Handle updates if needed
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onURLChange: onURLChange, onLoadingChange: onLoadingChange, onError: onError)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        let onURLChange: (URL) -> Void
        let onLoadingChange: (Bool) -> Void
        let onError: (String) -> Void

        init(
            onURLChange: @escaping (URL) -> Void,
            onLoadingChange: @escaping (Bool) -> Void,
            onError: @escaping (String) -> Void
        ) {
            self.onURLChange = onURLChange
            self.onLoadingChange = onLoadingChange
            self.onError = onError
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            onLoadingChange(true)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onLoadingChange(false)
            if let url = webView.url {
                onURLChange(url)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onLoadingChange(false)
            print("WebView error: \(error)")
            onError(error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onLoadingChange(false)
            print("WebView provisional error: \(error)")
            onError(error.localizedDescription)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Allow all navigation
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            decisionHandler(.allow)
        }
    }
}

#Preview {
    WebLoginSheet(provider: .claudeWeb)
        .environmentObject(AppState())
}
