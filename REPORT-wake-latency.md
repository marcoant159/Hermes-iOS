# REPORT: wake-latency (branch wip/wake-latency)

## Objetivo
Reduzir a latência entre dizer "oi Hermes" (detecção da wake word) e a abertura
efetiva da sessão de voz `codex_live` (bipe + sessão pronta). Sintoma reportado
por Marco no iPhone 14 Pro Max (TestFlight build 6): ao dizer "oi Hermes", o GPT
Live não ativa de imediato.

## Log de progresso

### Passo 0 — setup
- Worktree: `/root/hermes-mobile-wt/wake-latency`, branch `wip/wake-latency`.
- Área temporária: `.tmp/`, `.hstub/` (nunca /tmp).
- Sem xcodebuild local (Linux); compilação só via CI.

### Passo 1 — reconhecimento dos arquivos-chave
- App: `LiveWakeWordService.swift` (listener + detecção + finalize), `TalkStore.swift`
  (startWakeWordSession), `AppContainer.swift` (wiring onWakeActivation/onWakeEvent),
  `LiveVoiceSessionService.swift` (startSession, prepareWebRTC, exchangeRelaySDP).
- Relay: `relay/app/main.py` (talk/session, /sdp, app-state), `relay/app/schemas.py`
  (TalkSessionCreateRequest), `relay/app/talk_mcp.py`.
- Connector: `client.py` (`_rpc_talk_session_create`, `_rpc_talk_sdp_exchange`).

### Passo 2 — medição nos logs de produção (somente leitura)
Os eventos de wake word (`POST /v1/device/app-state` campo `wakeWordEvent`) chegam ao
relay, mas NÃO aparecem em `docker logs`: o `logger = logging.getLogger("hermes.relay")`
usa `.info()` e o uvicorn não configura o root logger (root em WARNING). Recuperei os
eventos na tabela `audit_log` (payload json) do Postgres do relay.

Timeline dos eventos reais de wake word (produção, 26/09):
```
21:07:45.008  wake phrase detected
21:07:50.302  wake activation dispatched (command: present)     -> +5.29 s
21:07:50.283  POST /v1/talk/session -> 422 Unprocessable Entity
21:07:51.010  voice session failed: Relay request failed with status 422
21:07:59.939  wake phrase detected
21:08:03.341  wake activation dispatched (command: present)     -> +3.40 s
21:08:03.297  POST /v1/talk/session -> 422
21:08:19.589  voice session failed: 422
```
Observações:
- O `POST /v1/talk/session` da wake word volta **422** de forma consistente. A causa é
  `relay/app/schemas.py:184-188`: o padrão do campo `provider` aceita
  `auto|codex_realtime|gemini_live|openai_realtime`, mas o app envia `codex_live`
  (`AppContainer.swift:390-392`, `VoiceEngineChoice.codexLive.providerValue == "codex_live"`).
  O connector suporta `codex_live` (`client.py:1262`), então o relay é o gargalo.
- Sessão manual (não wake) que funcionou (provider `auto` → connector resolve para
  `codex_live`):
  - `talk.session.create` em 21:14:21.985
  - `talk.session.sdp` em 21:14:23.715  => ~1.73 s do create ao SDP concluído
  - modelo final `gpt-live-1-codex`/voz `cove` (voice_sessions).
- Erros coexistentes no listener: "Maximum number of recognizers reached",
  `AVFAudio error -10868` / `2003329396` e `OSStatus 560557684` durante rearme de
  segmentos e handover de mic.

### Passo 3 — todas as esperas no caminho detecção → sessão aberta
1. `LiveWakeWordService.swift:69` `silenceToFinishCommand = 1.6 s` — mesmo um "oi hermes"
   puro só fecha a ativação 1,6 s após a última palavra reconhecida
   (`tickSilence` em :385-394, `finalizeCommand` em :396).**principal**
2. `LiveWakeWordService.swift:407` `await suspendForExternalCapture()` antes de chamar
   `onWakeActivation`; `suspendForExternalCapture` (:247-255) → `listener.pause()`
   (:622-628) → `endSegment()` (:790-804) → `analyzer.cancelAndFinishNow()` + `audioEngine.stop()`
   + `setActive(false)`. Serial no caminho.
3. `LiveVoiceSessionService.swift:262-294` bootstrap serial: `configureAudioSession()`
   → `POST talk/session` (relay→connector RPC, Cloudflare) → `prepareWebRTC()` (:1097)
   → `POST talk/session/{id}/sdp` (:1181, relay→connector→ POST chatgpt.com) →
   `setRemoteDescription` (:1138). O comentário em :1095-1096 diz que `prepareWebRTC`
   "Can run in parallel with the relay bootstrap request", mas está sequencial.
4. `LiveVoiceSessionService.swift:950-958` `waitForCodexLiveSession` espera até o evento
   `session.started` antes de injetar o comando (não bloqueia abrir a sessão).
5. `LiveWakeWordService.swift:262` `resumeAfterExternalCapture` dorme 800 ms antes de
   rearmar (pós-sessão, não na ativação).
6. Rearme de segmento: `endSegment` :806-814 usa 250 ms (ou 1000 ms se o segmento durou
   <1 s). `resumeSuppression = 1.0 s` (:73) suprime transcrições ao rearmar.
7. Round-trips relay↔connector via Cloudflare (~200-300 ms create; ~1-1,5 s SDP).

### Passo 4 — causas-raiz e correção escolhida (menor risco)
- **R1 (correção funcional):** relay rejeita `codex_live` (422) → sessão da wake word
  nunca abre em build que força o provider. Corrigir o schema do relay + teste.
- **R2 (latência):** janela fixa de 1,6 s após a detecção antes de sequer iniciar a
  sessão. Abrir imediatamente para ativação "seca" (graça curta), mantendo a janela de
  1,6 s quando já há comando na mesma fala.
- **R3 (latência):** `prepareWebRTC` sequencial com o `POST talk/session`; paralelizar.

### Passo 5 — implementação
- `relay/app/schemas.py:184-188`: `TalkSessionCreateRequest.provider` agora aceita
  `codex_live`. Teste novo `relay/tests/test_hosts.py::test_talk_session_create_forwards_codex_live_provider`.
- `HermesMobile/Services/Live/LiveWakeWordService.swift`:
  - novo `bareWakeSilence = 0.6 s`;
  - `tickSilence()` usa `0.6 s` quando a ativação ainda não capturou nenhum comando
    (`hasCapturedCommand == false`) e `1.6 s` quando há comando — "oi hermes" puro abre
    a sessão ~1 s antes, sem perder o comando falado na mesma frase.
- `HermesMobile/Stores/TalkStore.swift:115-129`: no retry de `startWakeWordSession`, se o
  provider forçado (`codex_live`) não abriu sessão, tenta `auto` (o connector resolve
  `auto` → `codex_live` quando há credenciais Codex). Rede de segurança para relays que
  ainda não aceitam `codex_live`; preserva o fluxo de delegação injetada.
- **R3 não aplicado:** `createOffer` local não espera ICE (sem `iceGatheringComplete`),
  então `prepareWebRTC` é rápido; paralelizar adicionaria risco de concorrência com
  `PreparedWebRTC` (não-`Sendable`) sem ganho mensurável.
- **Prewarm na detecção não aplicado:** `_rpc_talk_session_create` no connector é local e
  não bloqueia no contexto de voz (`schedule_voice_context_refresh_if_stale` é background);
  disparar `refreshReadiness()` concorrente com a captura arrisca atrasar/abortar o
  `startSession` (corrida em `canStartSession`/`connectionState`).

### Passo 6 — validação (testes)
- Relay: `pytest -q -k talk` rodou **17 passed** numa execução; nas seguintes o runner
  travou nos testes `talk_async_delegation_*` / `sdp_exchange` (deadlock de
  `Thread`+`websocket`/pool do TestClient). **É pré-existente**: travei igual com e sem a
  minha mudança de log e com e sem o teste novo. Os testes relevantes passam isolados e em
  conjunto: `-k "talk and not async_delegation"` → **12 passed** (quando não trava).
- Teste novo `test_talk_session_create_forwards_codex_live_provider` passa isolado.
- Connector (sem mudanças): `PYTHONPATH=src pytest -q -k "codex_live or prewarm"` → 12 passed.
- Observação: não há `relay/.venv` nem `connector/.venv` neste worktree; usei os venvs de
  outro worktree somente para rodar os testes (sem instalar nada).

### Passo 7 — validação no CI (compilação iOS)
- `gh workflow run "Build unsigned IPA" -R marcoant159/Hermes-iOS --ref wip/wake-latency`
- Run `36279857648` no commit `9b5113f` → **success** (build + IPA).
- Também verde no run `36278202048` (commit `09fc8cc`, app + schema do relay).

### Passo 8 — o que mudou (resumo), como validar, pendências

**O que mudou**
1. `relay/app/schemas.py`: aceita `provider=codex_live` em `POST /v1/talk/session`
   (+ teste em `relay/tests/test_hosts.py`). **Sem isso a wake word recebia 422** e a
   sessão nunca abria (evidência no audit_log de produção: 21:07:50 e 21:08:03).
2. `HermesMobile/Services/Live/LiveWakeWordService.swift`: "oi hermes" puro agora abre a
   sessão após uma sonda de 0,6 s (antes 1,6 s); se houver comando na mesma fala, mantém
   1,6 s para capturá-lo. Reduz ~1 s do caminho detecção→sessão.
3. `HermesMobile/Stores/TalkStore.swift`: se o provider forçado falhar, o retry usa `auto`
   (o connector resolve `auto` → `codex_live`), rede de segurança para relays antigos.
4. `relay/app/main.py`: handler no logger `hermes.relay` para que eventos (`wake word
   event ...`) apareçam em `docker logs` (antes eram descartados pelo root em WARNING).

**Como foi validado**
- Medição real nos logs/audit de produção (timeline no Passo 2).
- Testes pytest do relay (nova cobertura do provider `codex_live`) e do connector.
- Compilação iOS no CI verde no HEAD `9b5113f`.

**Roteiro de teste no iPhone (fica com o Marco)**
1. Configurações → ativar "Palavra de ativação" e confirmar que o listener está armado.
2. Dizer só "oi Hermes" e soltar: o bipe e a abertura da sessão `codex_live` devem sair
   quase juntos (≈0,6 s + bootstrap do relay/Codex, não mais ~3 s).
3. Dizer "oi Hermes, que horas são?": a sessão abre ao terminar a fala (~1,6 s de pausa) e
   a pergunta é consultada via delegação injetada.
4. Observar no relay (após o fix do log estar deployado):
   `docker logs -f hermes-mobile-relay-relay-1 2>&1 | rg -i "wake word event|talk/session"`
   — esperado: `wake phrase detected` → `wake activation dispatched` → `POST /v1/talk/session 200`
   → `/sdp 200`, sem `422`; e `voice session opened` no audit.
   - Atenção: o relay de produção atual **ainda rejeita `codex_live`**; até o deploy do
     relay, o app cai no fallback `auto` (que o connector resolve para `codex_live`).

**Pendências / riscos**
- **Deploy do relay** com o fix do schema + log é necessário para o caminho primário
  (`provider=codex_live`); o fallback `auto` cobre o intervalo.
- Não instrumentei timestamps on-device para cada etapa (bipe, prepareWebRTC,
  setRemoteDescription) — os `TalkLatencyMetrics` existem, mas não reportam o início da
  wake word. Sugestão: logar `sessionStartRequestedAt`/`realtimeConnectedAt` também nos
  eventos `wake` para medir no dispositivo.
- O listener sofre "Maximum number of recognizers reached" / AVFAudio errors no rearme de
  segmentos e no handover de mic; não mexi nisso (fora do escopo de latência), mas é um
  candidato a instabilidade da wake word.
- Flakiness pré-existente dos testes `talk_async_delegation_*` no runner local.

**Commits (branch `wip/wake-latency`)**
- `9d49fc5` relay: accept codex_live talk provider
- `09fc8cc` app: open the wake session without waiting the command window
- `9b5113f` relay: surface application logs under uvicorn
- + este relatório.
