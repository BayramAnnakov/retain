# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| 0.1.x   | ✅ Beta - best effort support |

## Reporting a Vulnerability

### Private Disclosure (Preferred)

**GitHub Security Advisories**: Report vulnerabilities via the [Security tab](../../security/advisories/new) to ensure private handling.

If Security Advisories are not available, open a GitHub issue labeled **security** with minimal details (no exploit code), and we will follow up privately.

### Response Timeline

- **Acknowledgment**: Within 72 hours
- **Initial Assessment**: Within 1 week
- **Fix Timeline**: Depends on severity
  - Critical: Days
  - High: 2 weeks
  - Medium/Low: Next release

### What to Include

- Description of the vulnerability
- Steps to reproduce (minimal proof-of-concept)
- Potential impact assessment
- Any suggested mitigations (optional)

## Security Architecture

### Local-First Design

Retain is designed with privacy as a core principle:

- **All data stored locally**: Conversations are stored in a local SQLite database (`~/Library/Application Support/Retain/`)
- **No Retain servers**: There are no backend servers. Your data never leaves your machine unless you explicitly enable optional cloud features.
- **Credentials in macOS Keychain**: API keys and session tokens are stored in the system Keychain, protected by macOS security.

### Optional Cloud Features (User-Enabled)

These features are **opt-in** and disabled by default:

| Feature | What It Sends | Where |
|---------|---------------|-------|
| Web Sync | Session cookies (stored locally) | claude.ai / chatgpt.com |
| Gemini Integration | Conversation metadata (title, preview, last 10 messages) | Google Gemini API |
| CLI Analysis | Conversation content | Anthropic API via Claude Code CLI |

### Permissions Required

- **Full Disk Access**: Only required for reading browser cookies for web sync. Without this, web sync features will not work.
- **Network Access**: Required for web sync and optional AI features.

## Security Practices

### What We Don't Collect

- No telemetry or analytics
- No crash reporting with user data
- No usage tracking
- No fingerprinting

### Credential Handling

- API keys never leave the Keychain except to authenticate requests
- Session tokens are not logged or persisted to disk
- No credentials are hardcoded in source code

### Data Isolation

- Each user's data is stored in their own Application Support directory
- Database files are not world-readable
- No inter-process communication with sensitive data

## Security Audits

Before each release, we run:

- **TruffleHog**: Scans git history for accidentally committed secrets
- **Dependency review**: Check for known vulnerabilities in dependencies

## Responsible Disclosure

We appreciate security researchers who:

1. Give us reasonable time to fix issues before public disclosure
2. Make good-faith efforts to avoid privacy violations and data destruction
3. Do not exploit vulnerabilities beyond proof-of-concept

We will credit researchers in release notes (unless they prefer anonymity).

## Contact

For security issues, please use GitHub Security Advisories or email the maintainer directly (see profile).
