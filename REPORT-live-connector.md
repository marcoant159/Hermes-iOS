# REPORT — provider de voz `codex_live` (gpt-live-1-codex)

Branch: `wip/live-connector` (worktree). Sem rede/credenciais reais; testes com mocks.

## Plano
1. Constantes `codex_live` em `talk_support.py`.
2. `client.py`: seleção de provider, `_create_codex_live_session`, `_rpc_talk_sdp_exchange`
   com URL/headers de live, `talk_readiness_payload`.
3. Testes novos `test_codex_live.py` + ajuste dos testes de `auto`.
4. Rodar pytest e suíte (ignorando `test_sensor_store.py`).
5. Commits pequenos (inglês, Co-Authored-By).

## Decisões
- Store: reaproveitado `_codex_realtime_sessions` (mesmo TTL de 600s) com campo
  `kind` (`"realtime"`/`"live"`); entradas antigas sem `kind` caem em `"realtime"`.
- `talk_readiness_payload` com credencial Codex reporta `codex_live`
  (`preferredModels=[gpt-live-1-codex, gpt-realtime-1.5]`).
- Auto: `codex_live > codex_realtime > gemini_live > openai_realtime`;
  `codex_realtime` forçado continua funcionando (URL/headers sem `OpenAI-Alpha`).
- Sessão live exata (sem `type`/`tools`/`output_modalities`/`audio.input`) com
  `delegation={"type":"client","ack_filler":true}`.

## Progresso
- [x] Exploração: `talk_support.py`, `client.py` (`_create_codex_realtime_session`,
      `_resolve_talk_provider`, `_rpc_talk_sdp_exchange`, `talk_readiness_payload`),
      `tests/test_codex_realtime.py`, `conftest.py`.
- [x] Constantes em `talk_support.py`.
- [x] `client.py` — implementação do provider `codex_live`.
- [x] Testes `test_codex_live.py` + ajustes nos testes de `auto`.
- [x] Suíte executada.
- [x] Commits.

## Testes
- `PYTHONPATH=src .venv/bin/python -m pytest -q tests/test_codex_realtime.py tests/test_codex_live.py`
  → 18 passed.
- Suíte completa (ignorando `tests/test_sensor_store.py`): 104 passed.
  Obs.: `tests/test_connector.py` chama o `hermes` real (`skills list`, sem timeout) e
  trava neste sandbox — comportamento pré-existente (confirmado em HEAD via `git stash`).
  Rodada com um stub `hermes` no `PATH` para não bloquear: 104 passed.
