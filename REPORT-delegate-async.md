# Report — Delegation assíncrona com polling

Branch: `wip/delegate-async` (worktree isolado, sem push)

## Objetivo
Corrigir a perda de respostas do Hermes no modo de voz GPT Live (`codex_live`).
Hoje o app chama `tools/call` síncrono em `talk_mcp.py`, que faz RPC
`talk.delegate` com timeout de 90 s. Consultas reais levam 2–4 min e a
Cloudflare corta requisições em 100 s. Solução: POST assíncrono + polling.

## Plano
1. Relay:
   - Setting `TALK_DELEGATE_ASYNC_TIMEOUT_SECONDS` (padrão 600).
   - `POST /v1/talk/session/{id}/delegations` → 202 + background task.
   - `GET  /v1/talk/session/{id}/delegations/{delegation_id}` → status/text/error.
   - Estado em memória com TTL de 30 min.
   - Manter `tools/call` síncrono intacto.
2. App (`LiveVoiceSessionService.swift`, só `codex_live`):
   - POST assíncrono + commentary imediato.
   - Polling a cada 2 s (até 10 min), commentary a cada ~45 s.
   - Speakable no fim; speakable curto em falha/timeout.
   - Cancelar polling ao encerrar sessão.

## Progresso
- [x] Reconhecimento do código (relay + app).
- [x] Relay: setting `TALK_DELEGATE_ASYNC_TIMEOUT_SECONDS` (padrão 600).
- [x] Relay: endpoints POST/GET + estado em memória (TTL 30 min) em `main.py`.
- [x] Testes do relay (`tests/test_hosts.py`): 4 novos cenários.
- [x] Testes existentes de talk/delegation: 15 passed.
- [x] App: polling assíncrono (`handleCodexLiveDelegation`, só `codex_live`).
- [x] Rodar testes finais (relay) e commits finais.

## Implementação (app — `LiveVoiceSessionService.swift`)
- `handleCodexLiveDelegation` (somente `codex_live`) agora:
  - `POST talk/session/{id}/delegations` via `apiClient`/`performAuthorizedRequest`;
  - envia `delegation.context.append` `commentary` imediato;
  - faz polling do GET a cada 2 s por até 10 min (via `Task`, sem bloquear);
  - a cada ~45 s manda `commentary` "Ainda consultando…";
  - conclui com `speakable`; falha/timeout → `speakable` curto em português.
- `delegationPollingTasks` guarda as Tasks por `itemID`; `endSession()` cancela
  todas.
- `callHermesDelegate` (síncrono via MCP) permanece para Gemini Live.
- Novos tipos: `TalkDelegationCreateRequest/Response`, `TalkDelegationStatusResponse`.
- Sem execução de swift/xcodebuild (conforme restrições); alteração revisada à mão.

## Implementação (relay)
- `config.py`: `talk_delegate_async_timeout_seconds` (env
  `TALK_DELEGATE_ASYNC_TIMEOUT_SECONDS`, padrão `600.0`).
- `schemas.py`: `TalkDelegationCreateRequest { prompt }`.
- `main.py`:
  - Estado `app.state.talk_delegations` + `talk_delegation_tasks`.
  - `prune_talk_delegations()`: remove entradas com TTL > 30 min.
  - `run_talk_delegation()`: background task que chama
    `send_connector_rpc(method="talk.delegate")` com timeout longo,
    registra o turno do assistente e grava `completed`/`failed`.
  - `POST /v1/talk/session/{id}/delegations` → 202 `{delegationId,status}`.
  - `GET  /v1/talk/session/{id}/delegations/{delegation_id}` →
    `{status,text,error}`; valida dono da voice session.
  - `tools/call` síncrono em `talk_mcp.py` mantido intacto.

## Resultados de teste (relay)
- `tests/test_hosts.py -k "talk or delegat"`: 15 passed.
- `tests/test_hosts.py -k "test_talk_async_delegation"`: 4 passed.
- `test_api`, `test_config`, `test_conversations`, `test_hermes_adapter`,
  `test_model_overrides`, `test_storage`, `test_pairing`: 42 passed.
- `test_streaming`: 9 passed.
- Ambiente local extremamente lento em SQLite (~20 s/teste de connector);
  executado em lotes com timeouts generosos.

## Notas de revisão
- `GET` de delegation é `async def` para serializar o acesso ao dict em
  memória no event loop (evita `RuntimeError` de mutação concorrente).
- TTL (30 min) > timeout assíncrono (10 min), então uma delegação nunca é
  podada antes de concluir.
- Testes do relay usam `TestClient` + thread, sem rede externa (connector
  websocket mockado), como o restante de `test_hosts.py`.

## Estado final
Relay e app implementados, commits pequenos em inglês com `Co-Authored-By`.
Sem push. Não foi possível compilar Swift neste ambiente (sem xcodebuild),
alterações revisadas manualmente.
