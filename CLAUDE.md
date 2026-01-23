# Retain

Native macOS app that aggregates AI conversations from multiple platforms into a unified, searchable knowledge base with intelligent learning extraction.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                         SwiftUI                              │
│  ContentView → ConversationDetailView, MenuBarView, etc.    │
├─────────────────────────────────────────────────────────────┤
│                    AppState (@MainActor)                     │
│  - conversations, searchResults, syncState                   │
│  - manages all UI state and coordinates services             │
├─────────────────────────────────────────────────────────────┤
│                        Services                              │
│  ┌─────────────┐  ┌─────────────┐  ┌────────────────────┐   │
│  │ SyncService │  │ FileWatcher │  │  WebSyncEngine     │   │
│  │ (actor)     │  │ (FSEvents)  │  │  (claude.ai/gpt)   │   │
│  └──────┬──────┘  └──────┬──────┘  └─────────┬──────────┘   │
│         └────────────────┴───────────────────┘              │
│                          │                                   │
│  ┌─────────────────────────────────────────────────────────┐│
│  │  ConversationRepository / LearningRepository (GRDB)     ││
│  └─────────────────────────────────────────────────────────┘│
│                          │                                   │
│  ┌─────────────────────────────────────────────────────────┐│
│  │  SQLite + FTS5 (~/.../Retain/retain.sqlite)            ││
│  └─────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────┘
```

## Project Structure

```
Sources/Retain/
├── App/                    # Entry point, AppState, ContentView
├── Components/             # Reusable UI (SyncOverlay, ProviderBadge)
├── Data/
│   ├── Models/             # Conversation, Message, Learning, Provider
│   ├── Parsers/            # ClaudeCodeParser, CodexParser
│   └── Storage/            # Database, Repositories
├── Features/
│   ├── ConversationBrowser/
│   ├── Learning/
│   ├── MenuBar/
│   ├── Settings/
│   └── Onboarding/
└── Services/
    ├── FileWatcher.swift   # FSEvents for file changes
    ├── SyncService.swift   # Background sync (actor)
    ├── Learning/           # CorrectionDetector, CLAUDEMDExporter
    ├── Search/             # SemanticSearch, OllamaService
    └── WebSync/            # ClaudeWebSync, ChatGPTWebSync
```

## Key Components

### Data Sources

| Source | Location | Format | Auto-sync |
|--------|----------|--------|-----------|
| Claude Code | `~/.claude/projects/**/*.jsonl` | JSONL | Yes (FSEvents) |
| Codex CLI | `~/.codex/history.jsonl` | JSONL | Yes (FSEvents) |
| claude.ai | Web API | JSON | Manual connect |
| chatgpt.com | Web API | JSON | Manual connect |

### Threading Model

- **SyncService**: Swift `actor` for thread-safe background sync
- **AppState**: `@MainActor` for UI state management
- **Database ops**: `DispatchQueue.global(qos: .userInitiated)`
- **UI updates**: Batched progress updates to reduce MainActor thrashing

### Core Models

```swift
struct Conversation {
    var id: UUID
    var provider: Provider       // .claudeCode, .claudeWeb, .chatgptWeb, .codex
    var sourceType: SourceType   // .cli, .web, .importFile
    var externalId: String?      // For deduplication
    var title: String?
    var projectPath: String?     // For CLI sources
    var messageCount: Int
}

struct Message {
    var id: UUID
    var conversationId: UUID
    var role: Role              // .user, .assistant, .system, .tool
    var content: String
    var timestamp: Date
}

struct Learning {
    var id: UUID
    var conversationId: UUID
    var type: LearningType      // .correction, .positive, .implicit
    var extractedRule: String
    var status: LearningStatus  // .pending, .approved, .rejected
    var scope: LearningScope    // .global, .project
}
```

## Build & Run

```bash
swift build                      # Debug build
swift build -c release           # Release build
swift test                       # Run tests
swift build && .build/debug/Retain  # Build and run
```

## Key Patterns

### Non-blocking Sync
```swift
// AppState.syncAll() uses Task.detached to avoid MainActor inheritance
syncTask = Task.detached { [syncService] in
    _ = try await syncService.syncAll()
}
```

### Background Database Operations
```swift
// SyncService uses withCheckedContinuation for async DB writes
await withCheckedContinuation { continuation in
    DispatchQueue.global(qos: .userInitiated).async {
        try? repository.upsert(conversation, messages: messages)
        continuation.resume()
    }
}
```

### FTS5 Search
```swift
// Uses synchronized FTS5 tables for instant search
try db.create(virtualTable: "messages_fts", using: FTS5()) { t in
    t.synchronize(withTable: "messages")
    t.tokenizer = .porter()
    t.column("content")
}
```

### Progress Updates (batched)
```swift
// Update UI every 20 files or 5% to reduce MainActor thrashing
let progressUpdateInterval = max(20, totalFiles / 20)
if index % progressUpdateInterval == 0 { ... }
```

## Provider Registry Architecture

The Provider Registry (`Data/Models/ProviderRegistry.swift`) centralizes provider configuration:

```swift
// Adding a new provider:
struct OpenCodeProviderConfig: ProviderConfiguration {
    let provider = Provider.opencode
    let displayName = "OpenCode"
    let iconName = "chevron.left.slash.chevron.right"
    let brandColor = Color.cyan
    let isSupported = true
    let isWebProvider = false
    let enabledKey = "opencodeEnabled"
    let sourceDescription = "~/.local/share/opencode/storage/"

    var dataPath: URL? {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/storage")
    }
}

// Register in ProviderRegistry.all
static let all: [ProviderConfiguration] = [
    ...,
    OpenCodeProviderConfig(),
]
```

### Provider Data Locations (Reference)

From [agent-sessions](https://github.com/jazzyalex/agent-sessions):

| Provider | Location | Format |
|----------|----------|--------|
| Claude Code | `~/.claude/projects/**/*.jsonl` | JSONL |
| Codex CLI | `~/.codex/sessions/` | JSONL |
| OpenCode | `~/.local/share/opencode/storage/` | JSON |
| Gemini CLI | `~/.gemini/tmp/` | JSON |
| GitHub Copilot CLI | `~/.copilot/session-state/` | JSON |
| Factory/Droid | `~/.factory/sessions/` | JSON |

## Common Tasks

### Add New Provider
1. Add case to `Provider` enum in `Data/Models/Provider.swift`
2. Create config struct implementing `ProviderConfiguration` in `Data/Models/ProviderRegistry.swift`
3. Register in `ProviderRegistry.all`
4. Create parser in `Data/Parsers/` (if CLI provider)
5. Add sync method in `SyncService`
6. Add file watcher in `FileWatcher` (if applicable)
7. Add @AppStorage binding in `DataSourcesSettingsView` if needed

### Database Migration
```swift
// In Database.swift migrator
migrator.registerMigration("v2_feature") { db in
    try db.alter(table: "conversations") { t in
        t.add(column: "newField", .text)
    }
}
```

## Dependencies

- **GRDB.swift 6.24+**: SQLite wrapper with FTS5 support
- **Ollama** (optional): Local embeddings for semantic search

## Database Location

`~/Library/Application Support/Retain/retain.sqlite`

## Notes

- Menu bar uses `MenuBarExtra` with `.menuBarExtraStyle(.window)`
- Dock icon set programmatically via `NSApplication.shared.applicationIconImage`
- Web sessions stored in Keychain, expire after ~30 days
- Learning extraction uses regex patterns in `CorrectionDetector`
- **Message preservation**: Messages are intentionally NOT deleted when source files are removed (preserves learnings via FK)
- **Browser support**: Any Chromium-based browser works (Chrome, Brave, Vivaldi, Arc) for cookie reading

## Release & Distribution

### Release Workflow

```bash
# 1. Build release
./scripts/build-release.sh

# 2. Sign, notarize, and create DMG (requires Developer ID certificate)
./scripts/sign-and-notarize.sh 0.1.x-beta

# 3. Create GitHub release
git tag v0.1.x-beta && git push origin v0.1.x-beta
gh release create v0.1.x-beta dist/Retain-0.1.x-beta.dmg dist/Retain-0.1.x-beta.zip --prerelease
```

### Key Points

- **Xcode 15.4+ required**: `nonisolated(unsafe)` syntax requires Swift 5.10; CI workflows must use Xcode 15.4+
- **CI should NOT upload release assets**: Release workflows overwrite manually notarized builds; use verify-only CI
- **Notarization is on the .app bundle**: The ticket is stapled to the app, not the DMG container
- **DMG MUST include Applications symlink**: Always create DMG with drag-to-install support:
  ```bash
  mkdir -p dmg_staging && cp -R Retain.app dmg_staging/ && ln -sf /Applications dmg_staging/Applications
  hdiutil create -volname "Retain" -srcfolder dmg_staging -ov -format UDZO Retain-x.x.x.dmg
  ```
- **Parser version bump**: When changing `ClaudeCodeParser` display logic (titles, previews), bump `claudeCodeParserVersion` in `SyncService.swift` to force re-sync on user's next launch
