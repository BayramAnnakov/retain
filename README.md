# Retain (Enhanced Fork)

[![Latest Release](https://img.shields.io/github/v/release/tolmachevmaxim/retain?label=download%20build&color=blue)](https://github.com/tolmachevmaxim/retain/releases/latest)
[![macOS](https://img.shields.io/badge/macOS-14.0%2B-blue)](https://github.com/tolmachevmaxim/retain/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Upstream](https://img.shields.io/badge/upstream-BayramAnnakov%2Fretain-orange)](https://github.com/BayramAnnakov/retain)

> A unified knowledge base for your AI conversations. Search, learn, and reflect across **Google Antigravity**, **Claude Code**, **Codex**, **Cursor**, **claude.ai**, **ChatGPT**, and more.

> [!NOTE]
> This is an enhanced fork by [@tolmachevmaxim](https://github.com/tolmachevmaxim) based on [BayramAnnakov/retain](https://github.com/BayramAnnakov/retain). It includes native **Google Antigravity** ingestion, a robust zero-crash analytics engine for massive datasets, cross-provider all-time search, and macOS stability fixes.

---

### ⚡ One-Line Install (macOS Terminal)

Install or update to the latest pre-built release with a single command:

```bash
curl -fsSL https://raw.githubusercontent.com/tolmachevmaxim/retain/main/install.sh | bash
```

*(Automatically downloads the latest release, installs to `/Applications/Retain.app`, and launches the app).*

Or download the zip directly: **[Retain v0.1.11 (macOS Apple Silicon)](https://github.com/tolmachevmaxim/retain/releases/latest)**.

---

<p align="center">
  <img src="docs/screenshots/conversations.png" width="800" alt="Conversation Browser">
</p>

## What It Does

**The problem**: You use Google Antigravity, Claude Code, claude.ai, ChatGPT, Codex, and other AI tools daily. Context is scattered. When you discover a preference or prompt correction in one tool, you lose it in another. You keep re-explaining the same things.

**The solution**: Retain aggregates all your AI conversations into a single local searchable knowledge base. It automatically extracts corrections and preferences, then exports them to `CLAUDE.md` / system prompts so your AI assistants remember what you taught them.

## 🚀 Key Improvements in this Fork

1. **🌌 Google Antigravity Support (CLI, IDE & Subagents)**:
   - Native two-pass ingestion of conversation trajectories (`transcript.jsonl` + `transcript_full.jsonl`).
   - Parses user prompts, assistant reasoning, multi-turn steps, subagent invocations, and tool activities.
   - Real-time `FileWatcher` automatically syncs new conversations as you work in Antigravity.
2. **⚡ Zero-Crash Analytics Engine**:
   - Replaced memory-heavy unindexed message iteration with high-performance SQLite SQL aggregation.
   - Handles large conversation histories (230,000+ messages) smoothly without memory leaks or UI freezes.
   - Safe date parsing with graceful ISO8601 fallback and collision-free dictionary aggregation.
3. **🔍 Universal Search ("All Conversations")**:
   - Dedicated top-level Smart Folder to search across *all* connected providers and dates at once.
4. **⚙️ UI & Session Fixes**:
   - Settings gear icon in the sidebar footer now reliably opens preferences.
   - Resilient generic password fallback for macOS Keychain session persistence (Claude.ai & ChatGPT).
5. **🛠 SwiftPM CLI Build Support**:
   - Guarded `#Preview` macros and added `scripts/package_app.sh` for one-command release packaging with `swift build -c release`.

---

## Supported Sources

| Source | Type | Sync Method | Status |
|--------|------|-------------|--------|
| **Google Antigravity** | CLI / IDE | Auto (file watching `~/.gemini/antigravity*/`) | ✅ **New in Fork** |
| **Claude Code** | CLI | Auto (file watching `~/.claude/`) | ✅ Stable |
| **Codex CLI** | CLI | Auto (file watching `~/.codex/`) | ✅ Stable |
| **Cursor** | IDE | Auto (file watching) | ✅ Stable |
| **OpenCode** | CLI | Auto (file watching) | ✅ Stable |
| **GitHub Copilot CLI** | CLI | Auto (file watching) | ✅ Stable |
| **claude.ai** | Web | Cookie import from Safari/Chrome/Firefox | ✅ Works |
| **chatgpt.com** | Web | Cookie import from Safari/Chrome/Firefox | ✅ Works |

## Beta Status

**Stable Features:**
- ✅ Conversation sync (Claude Code, Codex CLI, Cursor, Gemini CLI, OpenCode, GitHub Copilot CLI, claude.ai, ChatGPT)
- ✅ Full-text search across all conversations
- ✅ Conversation browser and detail view
- ✅ Menu bar integration
- ✅ Auto-updates via Sparkle

**Work in Progress:**
- 🚧 **Learnings extraction** - functional but under active development
- 🚧 **Automations** - experimental, API may change significantly
- 🚧 **CLAUDE.md export** - works but formatting improvements planned

## Installation

### Requirements
- macOS 14.0 (Sonoma) or later
- For web sync: Safari, Chrome, or Firefox with active sessions

### Download

Download the latest **notarized DMG** (recommended) or zip from [Releases](https://github.com/BayramAnnakov/retain/releases).

### Install

DMG (recommended):
1. Open the DMG.
2. Drag Retain to Applications.
3. Launch Retain from Applications.
4. Future updates will be automatic via Sparkle.

Zip (advanced):
1. Unzip and move Retain.app to Applications.
2. Launch Retain from Applications.

### Updates

Retain checks for updates automatically and notifies you when a new version is available. You can also check manually via the app menu.

## Supported Sources

| Source | Type | Sync Method | Status |
|--------|------|-------------|--------|
| Claude Code | CLI | Auto (file watching) | ✅ Stable |
| Codex CLI | CLI | Auto (file watching) | ✅ Stable |
| Cursor | IDE | Auto (file watching) | ✅ Stable |
| Gemini CLI | CLI | Auto (file watching) | ✅ Stable |
| OpenCode | CLI | Auto (file watching) | ✅ Stable |
| GitHub Copilot CLI | CLI | Auto (file watching) | ✅ Stable |
| claude.ai | Web | Cookie import from Safari/Chrome/Firefox | ✅ Works, sessions expire |
| chatgpt.com | Web | Cookie import from Safari/Chrome/Firefox | ✅ Works, sessions expire |

## Privacy & Security

**This is important. Please read.**

### What stays local
- All conversations are stored in a local SQLite database (`~/Library/Application Support/Retain/`)
- No data is sent to Retain servers (there are none)
- No telemetry, no analytics, no tracking

### What you should know

1. **Web sync reads browser cookies**: To sync from claude.ai/ChatGPT, the app reads session cookies from your browser. This requires Full Disk Access permission. The cookies are used only to authenticate API requests.

2. **Gemini integration (optional)**: If you enable AI features with Gemini:
   - Your API key is stored securely in the macOS Keychain
   - **Learning extraction**: Sends the last 10 messages (up to 500 chars each) to Google's Gemini API
   - **Workflow classification**: Sends conversation title, preview, and first message to categorize automation candidates
   - This feature is opt-in and disabled by default

3. **Claude Code CLI analysis (optional)**: If you enable CLI-based analysis:
   - Uses your local Claude Code CLI installation
   - Sends conversation data to Anthropic's API via the CLI
   - Requires consent in Settings before any data is sent
   - Codex CLI is disabled for security reasons (lacks hard no-tools flag)

4. **Web sessions expire**: claude.ai and ChatGPT sessions typically expire after ~30 days. You'll need to reconnect.

## Known Limitations (Beta)

This is beta software. Core features are stable, but expect some rough edges.

- **macOS only** - No Windows/Linux support planned for v1
- **Web sync is fragile** - Cookie-based auth can break if claude.ai/ChatGPT change their APIs
- **No import from exports** - Can't yet import JSON exports from ChatGPT/Claude settings
- **Web sessions expire** - claude.ai/ChatGPT cookie-based sessions require periodic reconnection
- **No conflict resolution** - If you sync from multiple Macs, conversations may duplicate

## Support

Best-effort. Please open an issue with clear reproduction steps and redacted logs.

## Building from Source

```bash
# Clone
git clone https://github.com/BayramAnnakov/retain.git
cd retain

# Build
swift build -c release

# Run
.build/release/Retain
```

## Roadmap

See [PHASED_VISION.md](docs/PHASED_VISION.md) for the long-term vision:

1. **Phase 1 (Current)**: Personal Memory OS - unified ingestion, learning extraction
2. **Phase 2**: Personal Automation - turn recurring workflows into playbooks
3. **Phase 3**: System of Record - versioning, governance, teams

## From claude-reflect

If you used [claude-reflect](https://github.com/BayramAnnakov/claude-reflect), Retain is its spiritual successor:

- claude-reflect: CLI tool that extracts learnings from Claude Code sessions
- Retain: Native app that does the same across *all* your AI tools with a proper UI

The learning extraction logic is similar, but Retain adds multi-source aggregation, search, and a native interface.

## Contributing

This is an early beta. The best way to contribute right now:

1. **Try it** and report bugs via [Issues](https://github.com/BayramAnnakov/retain/issues)
2. **Share feedback** on what sources you'd want next (Aider? Windsurf? API logs?)
3. **Star the repo** if you find it useful

See [CONTRIBUTING.md](CONTRIBUTING.md) for dev setup and PR guidelines.

## Security & Privacy

- Security policy: [SECURITY.md](SECURITY.md)
- Privacy details: [PRIVACY.md](PRIVACY.md)

## License

MIT License - see [LICENSE](LICENSE) for details.

---

**Questions?** Open an issue or reach out on Twitter/X.
