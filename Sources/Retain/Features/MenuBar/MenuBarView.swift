import SwiftUI

/// Menu bar widget view
struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var quickSearchQuery = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "brain.head.profile")
                    .font(.title2)
                    .foregroundColor(.accentColor)

                Text("Retain")
                    .font(.headline)

                Spacer()

                if appState.isSyncing {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }
            .padding()

            Divider()

            // Quick Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)

                TextField("Quick search...", text: $quickSearchQuery)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        openMainWindow(searchQuery: quickSearchQuery)
                    }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(NSColor.textBackgroundColor))

            Divider()

            // Stats
            VStack(spacing: 8) {
                ForEach(Provider.allCases.filter { appState.providerStats[$0] ?? 0 > 0 }, id: \.self) { provider in
                    HStack {
                        Image(systemName: provider.iconName)
                            .foregroundColor(provider.color)
                            .frame(width: 20)

                        Text(provider.displayName)
                            .font(.caption)

                        Spacer()

                        Text("\(appState.providerStats[provider] ?? 0)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if appState.providerStats.isEmpty {
                    Text("No conversations yet")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()

            Divider()

            // Recent Conversations
            VStack(alignment: .leading, spacing: 4) {
                Text("Recent")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)

                ForEach(appState.conversations.prefix(3)) { conversation in
                    Button {
                        openMainWindow(conversation: conversation)
                    } label: {
                        HStack {
                            Image(systemName: conversation.provider.iconName)
                                .foregroundColor(conversation.provider.color)
                                .font(.caption)

                            Text(conversation.title ?? "Untitled")
                                .font(.caption)
                                .lineLimit(1)

                            Spacer()

                            Text(conversation.updatedAt.formatted(.relative(presentation: .named)))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 8)

            Divider()

            // Actions
            VStack(spacing: 4) {
                Button {
                    Task {
                        await appState.syncAll()
                    }
                } label: {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("Sync Now")
                        Spacer()
                        if let lastSync = appState.lastSyncDate {
                            Text(lastSync.formatted(.relative(presentation: .named)))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .buttonStyle(MenuBarButtonStyle())
                .disabled(appState.isSyncing)

                Button {
                    Task {
                        await appState.forceFullSync()
                    }
                } label: {
                    HStack {
                        Image(systemName: "arrow.clockwise.circle")
                        Text("Force Full Sync")
                        Spacer()
                        Text("⌥⌘R")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(MenuBarButtonStyle())
                .disabled(appState.isSyncing)

                Button {
                    openMainWindow()
                } label: {
                    HStack {
                        Image(systemName: "rectangle.expand.vertical")
                        Text("Open Retain")
                        Spacer()
                        Text("⌘O")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(MenuBarButtonStyle())

                Button {
                    openAutomation()
                } label: {
                    HStack {
                        Image(systemName: "flowchart")
                        Text("Automation")
                        Spacer()
                        if !appState.workflowClusters.isEmpty {
                            Text("\(appState.workflowClusters.count)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .buttonStyle(MenuBarButtonStyle())

                Button {
                    openSettings()
                } label: {
                    HStack {
                        Image(systemName: "gear")
                        Text("Settings")
                        Spacer()
                        Text("⌘,")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(MenuBarButtonStyle())
            }
            .padding()

            Divider()

            // Pending Learnings
            if appState.pendingLearningsCount > 0 {
                Button {
                    openLearningsReview()
                } label: {
                    HStack {
                        Image(systemName: "lightbulb.fill")
                            .foregroundColor(.yellow)
                        Text("\(appState.pendingLearningsCount) learnings to review")
                            .font(.caption)
                        Spacer()
                    }
                }
                .buttonStyle(MenuBarButtonStyle())
                .padding(.horizontal)
                .padding(.vertical, 8)

                Divider()
            }

            // Quit
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                HStack {
                    Image(systemName: "power")
                    Text("Quit Retain")
                    Spacer()
                    Text("⌘Q")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(MenuBarButtonStyle())
            .padding()
        }
        .frame(width: 300)
    }

    private func openMainWindow(searchQuery: String? = nil, conversation: Conversation? = nil) {
        // Dismiss the menu bar popover first
        dismiss()

        if let query = searchQuery {
            appState.searchQuery = query
        }
        if let conversation = conversation {
            appState.select(conversation)
        }

        // First activate the app to bring it to foreground
        NSApplication.shared.activate(ignoringOtherApps: true)

        // Find the main content window (not menu bar, settings, or popover)
        let mainWindow = NSApplication.shared.windows.first { window in
            // Must be a regular window that can become main
            window.canBecomeMain &&
            !window.styleMask.contains(.utilityWindow) &&
            window.className != "NSStatusBarWindow" &&
            window.className != "_NSPopoverWindow" &&
            !window.title.lowercased().contains("settings") &&
            window.contentView != nil
        }

        if let window = mainWindow {
            // Use orderFrontRegardless to ensure it comes to front
            window.orderFrontRegardless()
            window.makeKey()
        } else {
            // No main window exists, open a new one
            openWindow(id: "main")
        }
    }

    private func openSettings() {
        dismiss()
        NSApplication.shared.activate(ignoringOtherApps: true)
        if #available(macOS 14.0, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    private func openLearningsReview() {
        appState.activeView = .learnings
        appState.sidebarSelection = .learnings
        openMainWindow()
    }

    private func openAutomation() {
        appState.activeView = .automation
        appState.sidebarSelection = .automation
        openMainWindow()
    }
}

// MARK: - Menu Bar Button Style

struct MenuBarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(configuration.isPressed ? Color.accentColor.opacity(0.1) : Color.clear)
            .cornerRadius(6)
    }
}

#Preview {
    MenuBarView()
        .environmentObject(AppState())
}
