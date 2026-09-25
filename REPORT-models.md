# REPORT — Seletor de modelos (branch `wip/models`)

Registro incremental do trabalho de adicionar um seletor de modelos no app
Hermes-iOS (Swift), no relay (Python/FastAPI) e no connector (Python).

Modelos suportados (override `provider/model`):

| Rótulo no app | override |
|---|---|
| Hermes padrão (GPT-6 Luna) | (sem override) |
| GPT-6 Luna | `openai-codex/gpt-6-luna` |
| GPT-6 Astra | `openai-codex/gpt-6-astra` |
| GPT-5.6 Luna | `openai-codex/gpt-5.6-luna` |
| Gemini 3.8 Flash | `gemini/gemini-3.8-flash` |
| DeepSeek V4.1 Flash | `opencode-go/deepseek-v4.1-flash` |

Legado aceito no relay/connector: `gemini-3.8-flash` → `gemini/gemini-3.8-flash`.

## Etapas

### Etapa 0 — Exploração e baseline

- Estrutura mapeada:
  - App: `HermesMobile/Models/UserSettings.swift` (enum `ChatModelChoice`),
    `HermesMobile/Features/Chat/ChatScreen.swift` (popover do chip),
    `HermesMobile/Services/Live/LiveHermesClient.swift` (`modelOverride`).
  - Relay: `relay/app/schemas.py` (`MessageCreateRequest.modelOverride`),
    `relay/app/main.py` (propaga para o job).
  - Connector: `connector/src/hermes_mobile_connector/client.py` (`_handle_job`),
    `connector/src/hermes_mobile_connector/hermes_api_executor.py`.
- Worktree limpo no início (`wip/models`, HEAD `7ca4e92`).
- Baseline de testes executada (resultados registrados abaixo).
- `REPORT-models.md` criado.

### Etapa 1 — App (Swift)

Arquivos alterados:
- `HermesMobile/Models/UserSettings.swift`
  - `ChatModelChoice` ganhou os casos `gpt6Luna`, `gpt6Astra`, `gpt56Luna`,
    `deepseekV41Flash` (e manteve `hermesDefault`, `gemini38Flash`).
  - `displayName` com os rótulos da tabela; default = "Hermes padrão (GPT-6 Luna)".
  - `modelOverride` retornando `provider/model` (nil para Hermes padrão).
  - `init(from:)`/`encode(to:)` explícitos: rawValues antigos preservados
    (`gemini38Flash` continua válido) e o valor legado `gemini-3.8-flash`
    também decodifica para `.gemini38Flash`.
  - Default de `UserSettings` (init e fallback de decode) mudou de
    `.gemini38Flash` para `.hermesDefault`.
- `HermesMobile/Features/Chat/ChatScreen.swift`
  - `displayedModelName` mostra o `displayName` do modelo escolhido quando há
    override; para `.hermesDefault` mantém o modelo ativo do host.
  - O popover já itera `ChatModelChoice.allCases`, então lista os 6 automaticamente.
- `HermesMobile/Services/Live/LiveHermesClient.swift`: sem alteração — já envia
  `chatModelChoiceProvider().modelOverride` (agora `provider/model`).
- Nenhum `project.pbxproj` tocado (não criei arquivo Swift).

Commit: `2de397c feat(app): expand chat model selector to provider/model options`.

### Etapa 2 — Relay

Arquivos alterados:
- `relay/app/schemas.py`
  - Constantes `SUPPORTED_MODEL_OVERRIDES` (5 strings) e
    `LEGACY_MODEL_OVERRIDES` (`gemini-3.8-flash` → `gemini/gemini-3.8-flash`).
  - `MessageCreateRequest.modelOverride` passou de `pattern` para
    `field_validator` que normaliza o legado e rejeita o resto (422).
- `relay/tests/test_model_overrides.py` (novo): allowlist, legado, default None,
  rejeições e testes de endpoint (200/422).

Commit: `7ce7b36 feat(relay): validate model overrides against explicit allowlist`.

### Etapa 3 — Connector

Arquivos alterados:
- `connector/src/hermes_mobile_connector/model_overrides.py` (novo):
  allowlist, alias legado e `parse_model_override()` → `(provider, model)`.
- `connector/src/hermes_mobile_connector/hermes_api_executor.py`:
  campos `provider`/`model` e `_model_payload()`/`_build_payload()`; com override
  envia `{"provider", "model"}`, sem override mantém `{"model": "hermes-agent"}`.
- `connector/src/hermes_mobile_connector/client.py`:
  `_handle_job` usa `parse_model_override`; com override e runtime de API server,
  clona o executor com provider/model; caso contrário (CLI) usa
  `hermes_provider`/`hermes_model`; override inválido → `job.failed` retryable=False.
- `connector/tests/test_model_overrides.py` (novo): parser (allowlist/legado/None/
  inválido), payload do API executor com e sem override, roteamento para API
  executor e para CLI, e rejeição de override inválido.

Commit: `c445a46 feat(connector): support provider/model overrides via allowlist`.

## Testes e resultados

Baseline (antes das mudanças):
- `cd relay && ./.venv/bin/python -m pytest -q` → travou no ambiente no
  `test_hosts.py` (após 16 passed, 1 failed no `test_api.py`), provavelmente por
  chamada de rede/DNS sem saída nesta máquina. Não é possível rodar a suíte
  relay completa aqui.
- `cd connector && PYTHONPATH=src .venv/bin/python -m pytest -q` → travou no
  `test_connector.py` (após 5 passed), mesmo motivo. O teste já conhecido como
  falho (`test_talk_session_create_normalizes_client_secret_payload`) não foi
  alcançado.

Após as mudanças (comandos relevantes, sempre com `PYTHONPATH=src` no connector):
- `cd relay && ./.venv/bin/python -m pytest -o addopts="" tests/test_model_overrides.py -v`
  → **10 passed** (94.9s; os testes de endpoint são lentos neste ambiente).
- `cd relay && ./.venv/bin/python -m pytest tests/test_api.py -q`
  → **8 passed** (baseline também passava; valida que o schema novo não quebrou
  o fluxo de mensagens).
- `cd connector && PYTHONPATH=src .venv/bin/python -m pytest -o addopts="" tests/test_model_overrides.py tests/test_streaming.py -v`
  → **30 passed** (2.6s).

## Resumo final

Arquivos alterados/criados:
- `HermesMobile/Models/UserSettings.swift` (alterado)
- `HermesMobile/Features/Chat/ChatScreen.swift` (alterado)
- `relay/app/schemas.py` (alterado)
- `relay/tests/test_model_overrides.py` (novo)
- `connector/src/hermes_mobile_connector/model_overrides.py` (novo)
- `connector/src/hermes_mobile_connector/hermes_api_executor.py` (alterado)
- `connector/src/hermes_mobile_connector/client.py` (alterado)
- `connector/tests/test_model_overrides.py` (novo)
- `REPORT-models.md` (novo, este arquivo)

Commits na branch `wip/models` (sem push):
1. `2de397c feat(app): expand chat model selector to provider/model options`
2. `7ce7b36 feat(relay): validate model overrides against explicit allowlist`
3. `c445a46 feat(connector): support provider/model overrides via allowlist`
(e um 4º commit de chore apenas com este relatório.)

Pendências / observações:
- Não há Xcode nesta máquina: o código Swift foi editado com cuidado, mas não
  compilado. Recomenda-se compilar/rodar os testes iOS na outra máquina.
- Suítes completas de relay/connector travam no ambiente por testes não
  relacionados (rede/DNS); rodei os arquivos de teste relevantes e o
  `tests/test_api.py` do relay. O teste já falho
  `test_talk_session_create_normalizes_client_secret_payload` continua fora do
  escopo (outro agente).
- A allowlist está duplicada em relay e connector (pacotes publicáveis
  separados, sem dependência compartilhada). Mantê-las em sincronia.
- `displayedModelName` do chip usa o rótulo do modelo escolhido; para
  "Hermes padrão" continua exibindo o modelo ativo reportado pelo host.
