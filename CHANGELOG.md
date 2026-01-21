# Changelog

All notable changes to Retain will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0-beta] - 2026-01-21

### Changed
- Promoted from alpha to beta
- UI polish: WCAG AA compliant search badges and contrast improvements
- Improved conversation title display (2-line support with truncation)
- Better timestamp formatting ("Just now", "Yesterday", relative dates)
- Loading state improvements in Analytics view

### Added
- UI verification test suite
- Auto-select first conversation on filter change
- GitHub Actions CI/CD workflows
- DMG creation script for releases
- Expanded security documentation

### Beta Notes
- **Learnings extraction**: Functional but under active development
- **Automations**: Experimental feature, API may change significantly
- **CLAUDE.md export**: Works but formatting improvements planned

---

## [0.1.0-alpha] - 2026-01-10

### Added
- Initial alpha release
- Multi-source conversation aggregation
  - Claude Code CLI (auto-sync via file watching)
  - Codex CLI (auto-sync via file watching)
  - claude.ai (cookie-based web sync)
  - chatgpt.com (cookie-based web sync)
- Full-text search with FTS5
- Learning extraction from corrections and preferences
- Export learnings to CLAUDE.md
- Optional Gemini integration for workflow extraction (experimental)
- Menu bar integration
- Native macOS app (Sonoma 14.0+)

### Known Issues
- Web sync sessions expire after ~30 days
- Import from JSON exports not yet implemented
- No conflict resolution for multi-Mac sync

### Security Notes
- Local-first architecture: all data stored locally by default
- Web session cookies stored securely in macOS Keychain
- Gemini API key stored securely in macOS Keychain
- No telemetry or analytics
- Optional cloud features (when enabled):
  - Web sync fetches conversations from claude.ai/chatgpt.com
  - Gemini integration sends conversation metadata to Google API
  - CLI LLM analysis sends data to selected model provider
