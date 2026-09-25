# REPORT-fixes (branch wip/fixes)

Registro cronológico das correções feitas nesta worktree.

## Etapa 1 — Teste quebrado do connector

**Problema:** `connector/tests/test_connector.py::test_talk_session_create_normalizes_client_secret_payload`
falhava porque `_google_api_key_for_state()` encontrava `GOOGLE_API_KEY`/`GEMINI_API_KEY`
no `.env` do `HERMES_HOME` (na máquina, `~/.hermes/.env`), escolhendo o caminho Gemini Live
em vez do OpenAI Realtime que o teste exercita (o teste mocka `_create_openai_realtime_session`).

**Correção (somente teste, sem mudar produção):** no início do teste, remover as variáveis
de ambiente com `monkeypatch.delenv(...)` e apontar `HERMES_HOME` para um `tmp_path` sem `.env`.

**Comando:** `cd connector && PYTHONPATH=src .venv/bin/python -m pytest -q tests/test_connector.py`
**Resultado:** 32 passed (8s).

## Etapa 2 — Hunks do `STALE-UNCOMMITTED-2026-09-24.patch`

Revisão hunk a hunk. Aplicado com edições manuais (o base do patch divergia do HEAD
em `services.py::record_voice_turn`).

**App (aplicado):**
- `LiveVoiceSessionService.swift`: flag `geminiTapInstalled` para só remover o tap de áudio
  quando ele existe (remover tap inexistente lança exceção); ao falhar o socket, ignorar
  socket antigo já substituído (`socket === geminiSocket`), só agendar resume se não houver
  resume em voo, marcar `canStartSession = false` no fracasso definitivo; acumular
  `inputTranscription` até `turnComplete` (antes finalizava a cada chunk, criando vários itens);
  `defer` limpa `geminiResumeTask` em todos os caminhos.
- `LiveWakeWordService.swift`: novo `isSuspendedForExternalCapture`; `start()`/`stop()` resetam
  `isSuspended` (evita herdar suspensão de execução anterior e perder a arbitragem do microfone).
- `SettingsScreen.swift`: mostra "Paused while another voice capture is active." quando a wake
  word está suspensa por captura externa (antes exibia "Starting the listener…" eternamente
  porque `phase` lê `.off` nesse estado).

**Relay (aplicado — todos cobertos por testes):**
- `apns.py`: apaga o arquivo temporário da chave `.p8` em `finally` (não vaza chave privada em /tmp).
- `security.py`: comparação da chave interna com `secrets.compare_digest` (tempo constante).
- `main.py`: em produção (`environment` fora de dev/test) exige `CONNECTOR_SETUP_SECRET`;
  em dev/test mantém só o warning.
- `services.py::_claim_single_use_code`: claim atômico de códigos de uso único via UPDATE
  condicional (`redeemed_at IS NULL`), fechando a corrida entre duas redenções concorrentes
  (PairingInvite, PhonePairingCode, HostEnrollmentInvite).
- `services.py::upsert_device` e `record_voice_turn`: movem `db.add()`/`flush()` para dentro do
  `begin_nested()` (savepoint), tratando `IntegrityError` por corrida sem 500/PendingRollbackError.

Nada foi considerado "duvidoso" o suficiente para recusar. O raise de produção do
`CONNECTOR_SETUP_SECRET` é comportamento novo, mas consistente com a checagem já existente do
`INTERNAL_API_KEY`, e os testes usam `environment="test"`.

**Comando:** `cd relay && .venv/bin/python -m pytest -q`
**Resultado:** 59 passed (nenhum F/E; a última linha do resumo é cortada no log capturado,
mas a barra chegou a 100% com 59 pontos). Observação: a máquina está com vários agentes
rodando em paralelo (load ~6 em 4 cores), então a suíte leva minutos.

## Etapa 3 — Imagem que "trava" (anexos)

**Fluxo verificado** (`connector/src/hermes_mobile_connector/client.py`):
1. `_handle_job` roda **antes** da seleção de runtime: `_build_cli_attachment_context()` grava cada
   anexo em `state_dir/attachment_staging/<jobId>/<filename>` e injeta no `latestUserMessage` uma
   instrução ("Image attachment available at <path> ... use vision_analyze with image_url: <path>"),
   zerando `job["attachments"]`.
2. `_handle_job_streaming` passa `attachments=job.get("attachments")` (None) para o runtime. Foi
   decisão deliberada (commit `f97bc8a`): o API server do Hermes não suporta `content` multipart
   (`image_url` é descartado), então o caminho suportado é o arquivo local + `vision_analyze`.
3. O cleanup do staging é no `finally` de `_handle_job`, **depois** de o streaming terminar.

**Verificações:**
- Teste novo `test_handle_job_forwards_staged_attachment_to_api_executor` com `HermesAPIExecutor`
  mockado (via `HermesAPIRuntimeAdapter`) confirma que o arquivo **existe durante o streaming**
  (não é apagado antes do Hermes ler), que a mensagem leva o caminho + `vision_analyze`, e que o
  staging some só no fim.
- O timeout do executor é `connect=10s`/`read=300s` (por leitura). Não há corte total do job; o
  loop principal do connector continua mandando heartbeat ao relay durante o job (desde o commit
  `7ca4e92`), então jobs longos de visão não são derrubados pelo timeout de 30s do relay.

**Bug encontrado e corrigido:** o staging estava **fora** do `try/except` de `_handle_job`. Se
`_build_cli_attachment_context` falhasse (ex.: erro de escrita no disco), a exceção subia até
`_handle_job_serialized`, que só logava — nenhum `job.failed` era enviado e a resposta nunca
chegava (job ficava "running" até o lease expirar). Agora todo o corpo de `_handle_job` está no
`try`, com um `except` que envia `job.failed` (retryable conforme o erro). Teste novo
`test_handle_job_staging_failure_sends_job_failed` cobre isso.

**Comando:** `cd connector && PYTHONPATH=src .venv/bin/python -m pytest -q tests/test_streaming.py`
**Resultado:** 19 passed (17 antes + 2 novos).

**Pendência/dúvida:** o `README`/config não expõe um teto total de duração do job. Se o API server
do Hermes mantiver a conexão SSE aberta com keepalives (`:` no stream, que o executor ignora), o
job pode ficar pendurado além dos 300s de read timeout. Não adicionei um timeout total porque o
`timeoutSeconds` do relay (180s, lease) é menor que o read timeout e usá-lo como deadline do job
poderia matar análises de visão legítimas. Fica registrado como melhoria futura (ex.: deadline
por job configurável via `timeoutSeconds` com piso maior).

---

# Resumo final

## Arquivos alterados (por commit)
- `2d03a94` `connector/tests/test_connector.py` — isola o teste de sessão realtime do ambiente
  Gemini do host.
- `9e56c58` `FORK-NOTES.md` — documenta o transporte Gemini Live e renumera as seções.
- `cf8a076` `HermesMobile/Features/Settings/SettingsScreen.swift`,
  `HermesMobile/Services/Live/LiveVoiceSessionService.swift`,
  `HermesMobile/Services/Live/LiveWakeWordService.swift` — robustez do Gemini Live + status
  "Paused" da wake word.
- `57c7432` `relay/app/apns.py` — remoção do arquivo temporário da chave APNs.
- `054c245` `relay/app/security.py`, `relay/app/main.py` — comparação em tempo constante +
  exigência de `CONNECTOR_SETUP_SECRET` em produção.
- `8ae846b` `relay/app/services.py` — claim atômico de códigos de uso único + savepoints em
  `upsert_device`/`record_voice_turn`.
- `1ac024d` `connector/src/hermes_mobile_connector/client.py`,
  `connector/tests/test_streaming.py` — `job.failed` em falha de staging de anexo + 2 testes.
- `3d44690` `REPORT-fixes.md` — este relatório.
- `STALE-UNCOMMITTED-2026-09-24.patch` — aplicado e **apagado** (não commitado).

## Testes rodados e resultado
- `cd connector && PYTHONPATH=src .venv/bin/python -m pytest -q tests/test_streaming.py`
  → **19 passed**.
- `... tests/test_connector.py::test_talk_session_create_normalizes_client_secret_payload`
  → **1 passed**.
- `... tests/test_connector.py -k "not rpc_commands_catalog"` → **28 passed** (exclui 4 testes que
  invocam o CLI `hermes`).
  - Observação: num momento de menor carga, `tests/test_connector.py` inteiro passou **32 passed
    em 8s**. Depois, com vários agentes em paralelo (load ~6 em 4 cores), os 4 testes do catálogo
    de RPC (que sobem o CLI `hermes`) travam por minutos; a suíte inteira estourava o timeout.
    Não é regressão do código — o teste alvo e os demais passam.
- `cd relay && .venv/bin/python -m pytest -q` → **59 passed** (0 F/E).
- Não rodei nada de iOS (sem Xcode). Mudanças Swift foram revisadas linha a linha contra o patch.

## Pendências / dúvidas
1. **Timeout total de job no connector** (ver Etapa 3): pode hangar se o API server mantiver SSE
   com keepalives; não corrigido por ser mudança de comportamento arriscada.
2. **`test_sensor_store.py`**: ignorado, como instruído (datas fixas de abril/2026).
3. A verificação dos Swift depende do build em outra máquina; não compilei.
4. A suíte do relay e do connector está lenta por contenção da máquina (outros agentes/worktrees).
