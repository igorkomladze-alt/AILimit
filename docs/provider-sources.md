# Provider integration sources

**English** | [Russian](provider-sources.ru.md)

AI Limits is an independent statistics client, not an official provider app.
The existence of an endpoint does not guarantee its long-term stability.

- **Codex:** official app-server, `account/rateLimits/read`;
  [API contract](https://learn.chatgpt.com/docs/app-server#6-rate-limits-chatgpt).
  Uses a dedicated `CODEX_HOME` and keyring, without starting tasks or generations.
- **OpenRouter:** official GET `/api/v1/credits`, requiring a Management Key;
  [documentation](https://openrouter.ai/docs/api-reference/credits/get-credits).
- **Claude:** GET `/api/oauth/usage`, using read-only local OAuth credentials.
  Credential formats and sources were checked against CodexBar; this is not
  a guarantee of a stable public API.
- **Kimi Code:** GET `https://api.kimi.com/coding/v1/usages`, using a Kimi Code
  key or an existing CLI login.
- **Z.ai:** GET `https://api.z.ai/api/monitor/usage/quota/limit`, for the
  international personal Coding Plan. Other regions are not tried automatically.

CodexBar (MIT) was consulted as a reference; its source code was not copied.
The Claude reference is pinned to commit
`6b83e08637de85f11887934fb37e1bf7db559e01`:
[OAuth model](https://github.com/steipete/CodexBar/blob/6b83e08637de85f11887934fb37e1bf7db559e01/Sources/CodexBarCore/Providers/Claude/ClaudeOAuth/ClaudeOAuthCredentialModels.swift),
[Keychain service](https://github.com/steipete/CodexBar/blob/6b83e08637de85f11887934fb37e1bf7db559e01/Sources/CodexBarCore/Providers/Claude/ClaudeOAuth/ClaudeOAuthCredentials.swift).

Preview validation: live readings from Codex, Kimi, Z.ai and OpenRouter were
obtained on one Mac. Claude and the full system-behavior matrix still require
live verification. Automated tests use synthetic data.

## Custom JSON APIs

Custom connections issue HTTPS GET requests only to the address explicitly
provided by the user. Bearer and X-API-Key authentication are supported; keys
are stored only in Keychain.

The DeepSeek preset uses GET `https://api.deepseek.com/user/balance`;
[official schema](https://api-docs.deepseek.com/api/get-user-balance/).
Balance and currency are read from the first `balance_infos` item, including
CNY/USD. Additional metrics can be configured for multiple wallets.

A live DeepSeek key was not provided for acceptance testing. The synthetic
schema, persistence, error handling, and configuration form were checked.
