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

## Common Tasks

### Add New Provider
1. Add case to `Provider` enum in `Data/Models/Provider.swift`
2. Create parser in `Data/Parsers/`
3. Add sync method in `SyncService`
4. Add file watcher in `FileWatcher` (if applicable)

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

## Release & Distribution

- **Xcode 15.4+ required**: `nonisolated(unsafe)` syntax requires Swift 5.10; CI workflows must use Xcode 15.4+
- **CI should NOT upload release assets**: Release workflows overwrite manually notarized builds; use verify-only CI for notarized apps
- **DMG with Applications link**: Use `create-dmg --app-drop-link` or manually `ln -s /Applications` before `hdiutil create`
- **Notarization is on the .app**: The notarization ticket is stapled to the app bundle, not the DMG; recreating the DMG preserves notarization
