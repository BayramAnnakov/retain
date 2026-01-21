# Privacy

Retain is local-first. Your data stays on your machine unless you enable
optional cloud features.

## What stays local
- Conversations are stored in a local SQLite database:
  `~/Library/Application Support/Retain/`
- There are no Retain servers.
- No telemetry or tracking by default.

## Web sync (claude.ai / chatgpt.com)
- Retain reads **browser session cookies** to authenticate web requests.
- Cookies are stored in the macOS Keychain.
- Sessions expire periodically and require reconnection.
- You can disconnect at any time to remove stored cookies.

## Optional cloud features

If you enable cloud analysis features, data is sent to external providers:
- **Gemini (Google)**: used for AI analysis if configured.
- **Claude Code CLI**: sends data to Anthropic via the local CLI.

These features are opt-in and require consent in Settings.

## Data removal

To remove all local data:
```bash
rm -rf ~/Library/Application\ Support/Retain
rm -f  ~/Library/Preferences/com.empatika.Retain.plist
```

## Questions

Open a GitHub issue for privacy questions or concerns.
