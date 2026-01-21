# Contributing

Thanks for your interest in Retain. This is an alpha project and support is best-effort.

## How to Help

1) **Report bugs**  
Use GitHub Issues with clear steps to reproduce.

2) **Request features**  
Explain the workflow you want to improve and why it matters.

3) **Send pull requests**  
Small, focused changes are easiest to review.

## Development

Requirements:
- macOS 14+
- Swift 5.9+
- Xcode 16 (recommended)

Build:
```bash
swift build -c release
```

Run:
```bash
.build/release/Retain
```

## PR Guidelines

- Keep changes focused and well-scoped.
- Add or update tests when behavior changes.
- Avoid committing user data, cookies, or local databases.
- Update docs if you change user-facing behavior.

## Privacy

Please redact sensitive data in logs or screenshots. Do not include cookies,
API keys, or private conversations in issues or PRs.
