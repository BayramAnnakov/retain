# Retain Documentation

Retain is a native macOS application that aggregates AI conversations from multiple platforms into a unified, searchable knowledge base with intelligent learning extraction.

## Table of Contents

1. [Architecture Overview](./ARCHITECTURE.md)
2. [Data Sources](./DATA_SOURCES.md)
3. [Search System](./SEARCH.md)
4. [Learning Extraction](./LEARNING.md)
5. [Web Sync Engine](./WEB_SYNC.md)
6. [Development Guide](./DEVELOPMENT.md)

## Quick Start

### Requirements

- macOS 14.0 (Sonoma) or later
- Xcode 15.0 or later
- Swift 5.9 or later
- Semantic search uses Apple NL (built-in, no setup required)
- (Optional) Ollama for higher-quality embeddings

### Installation

```bash
# Clone the repository
git clone https://github.com/BayramAnnakov/retain.git
cd retain

# Build with Swift Package Manager
swift build

# Or open in Xcode
open Package.swift
```

### First Run

1. Launch Retain
2. Complete the onboarding flow
3. Click "Sync Now" to import CLI conversations
4. (Optional) Connect web accounts in Settings

## Features

### Supported Data Sources

| Source | Type | Status |
|--------|------|--------|
| Claude Code | CLI | ✅ Auto-sync |
| Codex CLI | CLI | ✅ Auto-sync |
| claude.ai | Web | ✅ Manual connect |
| chatgpt.com | Web | ✅ Manual connect |

### Key Capabilities

- **Unified Search**: Full-text search across all conversations with FTS5
- **Semantic Search**: Vector similarity search using Apple NL (default) or Ollama
- **Real-time Sync**: FSEvents-based file watching for CLI tools
- **Learning Extraction**: Automatic detection of corrections and preferences
- **Profile Export**: Generate CLAUDE.md files from learned preferences

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Retain App                              │
├─────────────────────────────────────────────────────────────┤
│  Data Layer                                                 │
│  ┌─────────────┐  ┌─────────────┐  ┌───────────────────┐   │
│  │ CLI Watcher │  │ WebView     │  │ Manual Import     │   │
│  │ (FSEvents)  │  │ Sync Engine │  │ (JSON/Export)     │   │
│  └──────┬──────┘  └──────┬──────┘  └─────────┬─────────┘   │
│         └────────────────┼───────────────────┘             │
│                          ▼                                  │
│  ┌─────────────────────────────────────────────────────┐   │
│  │         SQLite + FTS5 + Vector Store                │   │
│  └─────────────────────────────────────────────────────┘   │
│                          │                                  │
│  ┌───────────┬───────────┼───────────┬───────────────┐     │
│  ▼           ▼           ▼           ▼               ▼     │
│ Search   Learning    Profile    Export          Analytics  │
│ Engine   Extractor   Builder    Manager                    │
└─────────────────────────────────────────────────────────────┘
```

## Configuration

Retain stores its configuration in:
- `~/Library/Application Support/Retain/` - Database and settings
- `~/Library/Preferences/` - User preferences (via @AppStorage)

### Environment Variables (Optional)

| Variable | Description | Default |
|----------|-------------|---------|
| `OLLAMA_ENDPOINT` | Ollama API URL (if using Ollama) | `http://localhost:11434` |
| `OLLAMA_MODEL` | Ollama embedding model | `nomic-embed-text` |

> **Note**: By default, Retain uses Apple's built-in NaturalLanguage framework for embeddings. No configuration required. Ollama is optional for users who prefer higher-quality embeddings.

## License

MIT License - see [LICENSE](../LICENSE) for details.
