import SwiftUI
import Carbon.HIToolbox

/// Global keyboard shortcuts handler
final class KeyboardShortcutsManager: ObservableObject {
    static let shared = KeyboardShortcutsManager()

    // MARK: - Shortcut Definitions

    enum Shortcut: String, CaseIterable {
        case search = "search"
        case sync = "sync"
        case newWindow = "newWindow"
        case settings = "settings"
        case learnings = "learnings"
        case analytics = "analytics"

        var defaultKeyCombo: KeyCombo {
            switch self {
            case .search: return KeyCombo(key: .f, modifiers: [.command])
            case .sync: return KeyCombo(key: .r, modifiers: [.command])
            case .newWindow: return KeyCombo(key: .n, modifiers: [.command])
            case .settings: return KeyCombo(key: .comma, modifiers: [.command])
            case .learnings: return KeyCombo(key: .l, modifiers: [.command, .shift])
            case .analytics: return KeyCombo(key: .a, modifiers: [.command, .shift])
            }
        }

        var displayName: String {
            switch self {
            case .search: return "Search"
            case .sync: return "Sync Now"
            case .newWindow: return "New Window"
            case .settings: return "Settings"
            case .learnings: return "Review Learnings"
            case .analytics: return "Analytics"
            }
        }
    }

    struct KeyCombo: Equatable {
        let key: Key
        let modifiers: NSEvent.ModifierFlags

        var displayString: String {
            var parts: [String] = []

            if modifiers.contains(.control) { parts.append("⌃") }
            if modifiers.contains(.option) { parts.append("⌥") }
            if modifiers.contains(.shift) { parts.append("⇧") }
            if modifiers.contains(.command) { parts.append("⌘") }

            parts.append(key.displayString)
            return parts.joined()
        }

        enum Key: String {
            case a, b, c, d, e, f, g, h, i, j, k, l, m
            case n, o, p, q, r, s, t, u, v, w, x, y, z
            case comma, period, slash, semicolon
            case space, `return`, escape, delete
            case up, down, left, right

            var displayString: String {
                switch self {
                case .comma: return ","
                case .period: return "."
                case .slash: return "/"
                case .semicolon: return ";"
                case .space: return "Space"
                case .return: return "↩"
                case .escape: return "⎋"
                case .delete: return "⌫"
                case .up: return "↑"
                case .down: return "↓"
                case .left: return "←"
                case .right: return "→"
                default: return rawValue.uppercased()
                }
            }

            var keyCode: UInt16 {
                switch self {
                case .a: return UInt16(kVK_ANSI_A)
                case .b: return UInt16(kVK_ANSI_B)
                case .c: return UInt16(kVK_ANSI_C)
                case .d: return UInt16(kVK_ANSI_D)
                case .e: return UInt16(kVK_ANSI_E)
                case .f: return UInt16(kVK_ANSI_F)
                case .g: return UInt16(kVK_ANSI_G)
                case .h: return UInt16(kVK_ANSI_H)
                case .i: return UInt16(kVK_ANSI_I)
                case .j: return UInt16(kVK_ANSI_J)
                case .k: return UInt16(kVK_ANSI_K)
                case .l: return UInt16(kVK_ANSI_L)
                case .m: return UInt16(kVK_ANSI_M)
                case .n: return UInt16(kVK_ANSI_N)
                case .o: return UInt16(kVK_ANSI_O)
                case .p: return UInt16(kVK_ANSI_P)
                case .q: return UInt16(kVK_ANSI_Q)
                case .r: return UInt16(kVK_ANSI_R)
                case .s: return UInt16(kVK_ANSI_S)
                case .t: return UInt16(kVK_ANSI_T)
                case .u: return UInt16(kVK_ANSI_U)
                case .v: return UInt16(kVK_ANSI_V)
                case .w: return UInt16(kVK_ANSI_W)
                case .x: return UInt16(kVK_ANSI_X)
                case .y: return UInt16(kVK_ANSI_Y)
                case .z: return UInt16(kVK_ANSI_Z)
                case .comma: return UInt16(kVK_ANSI_Comma)
                case .period: return UInt16(kVK_ANSI_Period)
                case .slash: return UInt16(kVK_ANSI_Slash)
                case .semicolon: return UInt16(kVK_ANSI_Semicolon)
                case .space: return UInt16(kVK_Space)
                case .return: return UInt16(kVK_Return)
                case .escape: return UInt16(kVK_Escape)
                case .delete: return UInt16(kVK_Delete)
                case .up: return UInt16(kVK_UpArrow)
                case .down: return UInt16(kVK_DownArrow)
                case .left: return UInt16(kVK_LeftArrow)
                case .right: return UInt16(kVK_RightArrow)
                }
            }
        }
    }

    // MARK: - Properties

    @Published var shortcuts: [Shortcut: KeyCombo] = [:]
    private var handlers: [Shortcut: () -> Void] = [:]
    private var eventMonitor: Any?

    // MARK: - Init

    private init() {
        loadDefaultShortcuts()
    }

    // MARK: - Setup

    private func loadDefaultShortcuts() {
        for shortcut in Shortcut.allCases {
            shortcuts[shortcut] = shortcut.defaultKeyCombo
        }
    }

    // MARK: - Registration

    func register(_ shortcut: Shortcut, handler: @escaping () -> Void) {
        handlers[shortcut] = handler
    }

    func unregister(_ shortcut: Shortcut) {
        handlers.removeValue(forKey: shortcut)
    }

    // MARK: - Event Monitoring

    func startMonitoring() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            return self?.handleKeyEvent(event)
        }
    }

    func stopMonitoring() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        for (shortcut, keyCombo) in shortcuts {
            if event.keyCode == keyCombo.key.keyCode &&
               event.modifierFlags.intersection(.deviceIndependentFlagsMask) == keyCombo.modifiers {
                handlers[shortcut]?()
                return nil // Consume the event
            }
        }
        return event
    }
}

// MARK: - SwiftUI Integration

struct KeyboardShortcutsModifier: ViewModifier {
    @EnvironmentObject private var appState: AppState
    @StateObject private var shortcuts = KeyboardShortcutsManager.shared

    func body(content: Content) -> some View {
        content
            .onAppear {
                setupShortcuts()
                shortcuts.startMonitoring()
            }
            .onDisappear {
                shortcuts.stopMonitoring()
            }
    }

    private func setupShortcuts() {
        shortcuts.register(.search) {
            appState.focusSearch()
        }

        shortcuts.register(.sync) {
            Task {
                await appState.syncAll()
            }
        }

        shortcuts.register(.settings) {
            if #available(macOS 14.0, *) {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } else {
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            }
        }
    }
}

extension View {
    func withKeyboardShortcuts() -> some View {
        modifier(KeyboardShortcutsModifier())
    }
}

// MARK: - Shortcuts Settings View

struct ShortcutsSettingsView: View {
    @StateObject private var shortcuts = KeyboardShortcutsManager.shared

    var body: some View {
        Form {
            Section("Keyboard Shortcuts") {
                ForEach(KeyboardShortcutsManager.Shortcut.allCases, id: \.self) { shortcut in
                    HStack {
                        Text(shortcut.displayName)

                        Spacer()

                        if let keyCombo = shortcuts.shortcuts[shortcut] {
                            Text(keyCombo.displayString)
                                .font(.system(.body, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.secondary.opacity(0.1))
                                .cornerRadius(4)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
