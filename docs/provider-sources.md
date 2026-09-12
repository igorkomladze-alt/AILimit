# Источники интеграций

AI Limits — независимый клиент статистики. Это не официальное приложение
провайдеров. Наличие endpoint не является гарантией его стабильности.

- Codex: официальный app-server, `account/rateLimits/read`;
  [контракт](https://learn.chatgpt.com/docs/app-server#6-rate-limits-chatgpt).
  Отдельный CODEX_HOME и keyring, без запуска задач или генераций.
- OpenRouter: официальный GET `/api/v1/credits`, Management Key;
  [документация](https://openrouter.ai/docs/api-reference/credits/get-credits).
- Claude: GET `/api/oauth/usage`; read-only локальная OAuth-авторизация.
  Формат/источник сверялись с CodexBar, а не считаются публичной гарантией API.
- Kimi Code: GET `https://api.kimi.com/coding/v1/usages`, ключ Kimi Code или CLI.
- Z.ai: GET `https://api.z.ai/api/monitor/usage/quota/limit`, международный
  персональный Coding Plan. Другие регионы автоматически не пробуются.

CodexBar (MIT) использован как reference, исходники не копировались.
Закреплённый reference для Claude:
`6b83e08637de85f11887934fb37e1bf7db559e01` —
[OAuth model](https://github.com/steipete/CodexBar/blob/6b83e08637de85f11887934fb37e1bf7db559e01/Sources/CodexBarCore/Providers/Claude/ClaudeOAuth/ClaudeOAuthCredentialModels.swift),
[Keychain service](https://github.com/steipete/CodexBar/blob/6b83e08637de85f11887934fb37e1bf7db559e01/Sources/CodexBarCore/Providers/Claude/ClaudeOAuth/ClaudeOAuthCredentials.swift).

Статус предварительного выпуска: реальные данные Codex, Kimi, Z.ai и
OpenRouter прочитаны на одном Mac; Claude и полная матрица системных сценариев
ещё требуют живой проверки. Тесты используют искусственные данные.
