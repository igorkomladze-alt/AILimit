# AI Limits

**English** | [Russian](README.ru.md)

[![CI](https://github.com/igorkomladze-alt/AILimit/actions/workflows/build.yml/badge.svg)](https://github.com/igorkomladze-alt/AILimit/actions/workflows/build.yml)
[![MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![macOS 14+ · Apple Silicon](https://img.shields.io/badge/macOS-14%2B%20%C2%B7%20Apple%20Silicon-black)

**Codex, Claude, Kimi Code, GLM / Z.ai** limits and your **OpenRouter** balance in the macOS menu bar. Connect your own accounts on your own Mac. The application interface is currently in Russian.

**Preview release.** Live readings from Codex, Kimi, GLM and OpenRouter have been verified on one Mac. Claude has test coverage, but live verification is incomplete. Provider API changes may break integrations.

<p align="center">
  <img src="docs/images/panel-light.png" width="280" alt="AI Limits light appearance, demo data" />
  &nbsp;&nbsp;
  <img src="docs/images/panel-dark.png" width="280" alt="AI Limits dark appearance, demo data" />
</p>

*Real interface rendered with synthetic demo data. Screenshots show the current Russian-language app; no personal accounts or balances were used.*

## Download for Mac

**[Download AI Limits v0.1.0 — ZIP](https://github.com/igorkomladze-alt/AILimit/releases/download/v0.1.0/AI-Limits-macOS.zip)** · [SHA256](https://github.com/igorkomladze-alt/AILimit/releases/download/v0.1.0/SHA256SUMS.txt) · [Release notes](https://github.com/igorkomladze-alt/AILimit/releases/tag/v0.1.0)

The prebuilt app needs no Xcode or Homebrew. Requires **macOS 14+ and Apple Silicon**.

1. Unzip the download and move **AI Limits.app** to **Applications**.
2. Open the app. If macOS cannot verify the developer, after attempting to launch it, go to **System Settings → Privacy & Security → Open Anyway**, only if you trust the downloaded file. [Apple's instructions](https://support.apple.com/en-us/102445).
3. Click the menu-bar icon → gear and connect your own services.

**Ad-hoc signed preview; no Developer ID or notarization.** This is not an Apple-verified build. Do not disable Gatekeeper/SIP. If your Mac's policy prevents launch, use the source-build instructions below.

To verify the ZIP, put it next to `SHA256SUMS.txt` and run:

```bash
shasum -a 256 -c SHA256SUMS.txt
```

## Features

- Compact panel with separate quota windows and additional Codex limit groups.
- Automatic refresh, last-known snapshots on errors, light and dark themes.
- Configurable notifications and launch at login, both off by default.
- Custom JSON APIs and a built-in DeepSeek balance preset.
- Secrets in Keychain; no model generation requests just to measure usage.

## Build from source

Requires **Apple Silicon (M1+)**, **macOS 14+**, full **Xcode with Swift 6**, and **XcodeGen**. Command Line Tools alone are insufficient. Local validation used macOS 27 beta / Xcode 27 beta / XcodeGen 2.46; macOS 14 has not been separately tested. Windows and Linux are not supported.

To build it yourself, install and open Xcode, complete its initial setup, and select it under **Xcode → Settings → Locations → Command Line Tools**. If Homebrew is already installed:

```bash
brew install xcodegen
```

See [XcodeGen installation](https://github.com/yonaskolb/XcodeGen#installing) for alternatives. Then:

```bash
git clone https://github.com/igorkomladze-alt/AILimit.git
cd AILimit
xcodebuild -version
swift --version
xcodegen --version
swift test
bash scripts/package-app.sh
bash scripts/check-bundle.sh
```

Open `build` in Finder, move **AI Limits.app** to your **Applications** folder, and launch it. Click its menu-bar icon, then the gear to configure connections.

The local build uses ad-hoc signing; there is no Developer ID signature or notarization. If macOS warns you, use its standard confirmation for opening a trusted application. Do not disable Gatekeeper/SIP or broadly remove quarantine attributes.

## Connect providers

Connect any subset of providers. Enter keys **only in the application UI**, never in source files, `.env`, or Issues.

Button and menu names below are English translations. The app currently displays Russian labels; the [Russian guide](README.ru.md) includes their on-screen wording.

| Provider | Requirements and connection |
|---|---|
| Codex | A ChatGPT subscription with Codex access and the [official Codex CLI](https://learn.chatgpt.com/docs/cli). Click **Sign in with Codex** and complete browser sign-in. |
| Claude | Claude Code and Claude Pro/Max or eligible organizational access. Run `claude auth login --claudeai`, then click **Allow and connect**. Live verification is incomplete. |
| Kimi Code | A **Kimi Code** key, not a Moonshot API key, or a valid Kimi CLI login. Enter the key or allow access to the local login. |
| GLM / Z.ai | An international personal **Coding Plan** key. BigModel CN and API balances are unsupported. |
| OpenRouter | A **Management Key**. GET `/api/v1/credits` reads the account balance. |

Codex CLI is searched for at `/opt/homebrew/bin/codex`, `/usr/local/bin/codex`, and `~/.local/bin/codex`; the app does not install it automatically. ChatGPT Pro and Claude Pro are separate subscriptions.

OpenRouter Management Keys have broader privileges than balance reading; the app only uses a statistics GET request. Claude and Kimi CLI credentials are read with permission. Their refresh tokens are not refreshed by this app: sign in again through the official CLI when needed.

## Custom services and DeepSeek

Click **+** in the panel or open **Settings → Custom services**.

**DeepSeek example:** choose **DeepSeek — API balance**, enter your API key, and click **Test and save**. The preset fills in the endpoint and fields; currency (`CNY` or `USD`) comes from the response. This is an API money balance, not a subscription quota.

For **Custom JSON API**, supply a name, an HTTPS statistics URL, and authentication: none, Bearer, or X-API-Key. Only GET is supported, without URL query parameters, user credentials, fragments, redirects, or browser cookies.

- Up to **20 services** and **8 metrics** per service: remaining/used percentage, money, or remaining/used amounts against a total limit.
- Paths: `data.remaining_percent` selects a nested field; `balance_infos.0.total_balance` selects a field in the first array item. Values may be JSON numbers or numeric strings.
- Currency: a constant or field path. Reset time: ISO 8601 or Unix seconds.
- Saving requires a successful GET and field validation; an error preserves the previous connection.

Synthetic response for configuring a percentage metric:

```json
{"data":{"remaining_percent":72,"resets_at":"2026-10-01T00:00:00Z"}}
```

Keys stay in Keychain; definitions and normalized readings are stored locally in `custom-services.json`. When editing, a blank key preserves the existing key only for the same server address; enter a new key for a different server.

## Readings and settings

- Percentages show **remaining** quota. Zero differs from “No data.” Five-hour and seven-day windows are not added together.
- The primary Codex limit appears first; **More limits** expands additional groups. OpenRouter displays USD.
- Errors preserve the last snapshot with a warning. Reaching a reset time does not automatically set the remaining quota to 100%.
- Built-in providers refresh every 5 minutes with at most three concurrent requests; custom services refresh serially. Errors and Retry-After increase the delay; manual refresh does not bypass it.
- Notification thresholds: 20% / 5%, and strictly below $3 for OpenRouter; warnings and recovery can be configured per provider.
- System, light, or dark appearance; hide disconnected providers; optional launch at login.

## Privacy and removal

Keys use the system Keychain under `local.gutfresh.AILimits`, without iCloud synchronization. Snapshots and settings live in `~/Library/Application Support/AILimits`. These are private local data: do not send them to the developer or add them to the repository.

Codex uses a dedicated `CODEX_HOME` inside that directory and a keyring; other applications’ logins are not copied. Browser cookies are not read. There is no app backend, telemetry, or cloud synchronization; authentication and statistics requests go to providers.

To uninstall, disconnect services and disable launch at login, quit the app, and move it to Trash. Optionally remove `~/Library/Application Support/AILimits` manually. Do not remove `~/.codex`, `~/.claude`, or `~/.kimi-code`: they belong to other applications.

## Troubleshooting

| Symptom | Check |
|---|---|
| `xcodebuild requires Xcode` | Select full Xcode in Settings → Locations. |
| `xcodegen: command not found` | Install XcodeGen and build again. |
| Codex CLI not found | Check `command -v codex` and the supported paths above. |
| Claude will not connect | Repeat `claude auth login --claudeai` and allow reading credentials in the app. |
| 401 / 403 | Check your subscription and key type; sign in again if needed. |
| 429 | Wait for the next attempt; manual refresh does not bypass the delay. |
| Unexpected readings | Compare with the provider dashboard; report the provider, macOS version, and error text. |

Redact email, balance, and other personal data in Issues. Never share keys, `auth.json`, or cookies.

## Known limitations

macOS / Apple Silicon only; Russian application UI only. Live Claude access and the minimum macOS version are not yet verified. Custom services do not support threshold notifications. Sites without a suitable JSON API and separate OAuth flows need dedicated adapters. Provider API changes may interrupt readings.

## Development and license

```bash
swift test
bash scripts/check-privacy.sh
python3 scripts/check-distribution.py
```

CI on macOS checks source, tests, and packaging; see the badge above for its current result. Real accounts and secrets are not required. Passing tests do not establish live API compatibility. See [CONTRIBUTING.md](CONTRIBUTING.md) to contribute.

Code is licensed under [MIT](LICENSE). Provider logos belong to their respective owners; see [sources and notices](THIRD_PARTY_NOTICES.md). This project is not affiliated with OpenAI, Anthropic, Moonshot, Z.ai, or OpenRouter.
