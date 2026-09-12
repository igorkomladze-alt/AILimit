# Contributing

**English** | [Russian](CONTRIBUTING.ru.md)

Issues and discussions are welcome. To report a problem, include your macOS
version, provider, connection method, expected behavior, and what happened.
Never publish keys, cookies, email addresses, `auth.json`, personal quota
snapshots, or files from Application Support.

Before opening a pull request, run:

```bash
swift test
bash scripts/package-app.sh
bash scripts/check-bundle.sh
```

Use synthetic responses for parser tests, not real account data. For UI
changes, check light and dark appearances and the panel dimensions. Do not
make paid generation requests just to verify quota readings.

Preserve independent provider connections, read-only access to other CLI
credentials, strict endpoint restrictions, and secret-free logs. Cache schema
changes must preserve compatibility or explicitly document a migration.

Add dependencies only when needed. Provider logos and trademarks are not
covered by the code's MIT license; retain their source attribution.
