# Retain Developer Documentation

For user documentation, see the main [README](../README.md).

## Building from Source

### Requirements

- macOS 14.0 (Sonoma) or later
- Xcode 15.0+ or Swift 5.9+

### Build

```bash
# Clone
git clone https://github.com/BayramAnnakov/retain.git
cd retain

# Build
swift build -c release

# Run
.build/release/Retain
```

## Project Structure

```
Sources/Retain/
├── App/                    # Entry point, AppState, ContentView
├── Components/             # Reusable UI components
├── Data/
│   ├── Models/             # Conversation, Message, Learning
│   ├── Parsers/            # Claude Code, Codex parsers
│   └── Storage/            # SQLite + GRDB repositories
├── Features/               # Main UI features
└── Services/               # Sync, search, web sync engines
```

## Data Storage

- **Database**: `~/Library/Application Support/Retain/retain.sqlite`
- **Preferences**: `~/Library/Preferences/` (via @AppStorage)

## Dependencies

- [GRDB.swift](https://github.com/groue/GRDB.swift) - SQLite with FTS5 support

## License

MIT License - see [LICENSE](../LICENSE)
