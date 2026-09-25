# Notas do fork (`marcoant159/Hermes-iOS`)

Divergências locais em relação ao upstream `dylan-buck/Hermes-iOS`.
**Tudo aqui pode se perder num `git pull`/merge do upstream — conferir depois de atualizar.**

## 1. Wake word "oi hermes" / "hey hermes" (branch `feat/wake-word`)

Escuta contínua on-device + comando de voz com resposta falada.

- **Novo**: `HermesMobile/Services/Live/LiveWakeWordService.swift` — listener contínuo
  (`DictationTranscriber` + `SpeechAnalyzer`, rearmando o segmento em vez de parar no 1º
  resultado final), matcher da frase de ativação e `SpeechAnnouncer`
  (`AVSpeechSynthesizer`, voz pt-BR, markdown/código limpos).
- **Alterados**: `Stores/AppContainer.swift` (wiring/start), `Stores/ChatStore.swift`
  (`onAssistantReplyFinished`), `Models/UserSettings.swift` (`wakeWordEnabled`),
  `Features/Settings/SettingsScreen.swift` (toggle Hands-Free), `Services/Live/LiveSpeechService.swift`
  (arbitragem do microfone: ditado suspende o listener), `HermesMobile.xcodeproj/project.pbxproj`
  (registro do arquivo novo — **o CI compila o pbxproj commitado, não roda xcodegen**),
  `.github/workflows/ios-unsigned-ipa.yml` (passou a buildar `feat/**`).
- **Constantes para calibrar** (topo de `LiveWakeWordService.swift`):
  `silenceToFinishCommand` 1,6 s · `silenceBeforeCommand` 5 s · `maxCommandSeconds` 20 s ·
  `cooldownAfterCommand` 1,2 s · `replyTimeout` 90 s · `wakePrefixes`.
- **Uso**: Settings → Hands-Free → Wake Word. O app precisa estar rodando (foreground ou
  background com o indicador laranja); force-quit não é reaberto pelo iOS.

## 2. Transporte de voz "Gemini Live" (mesma branch `feat/wake-word`)

Quando o relay devolve `bootstrap.provider == "gemini_live"` (em vez do WebRTC/OpenAI
Realtime), o app não usa WebRTC: abre um `URLSessionWebSocketTask` direto pro endpoint
`BidiGenerateContentConstrained` do Gemini, com uma única tool `hermes_delegate` pra delegar
pedidos ao Hermes via MCP do relay. O app agora usa esse caminho por padrão.

- **Novo grosso da lógica**: `HermesMobile/Services/Live/LiveVoiceSessionService.swift` —
  `connectGeminiLive(...)` (setup da sessão, `sessionResumption`/`goAway` com
  `scheduleGeminiResume()` pra reconectar), captura/reprodução de áudio via `AVAudioEngine`
  (entrada 16 kHz PCM, saída 24 kHz), transcrição de entrada/saída em pt-BR e
  `callHermesDelegate` (POST JSON-RPC `tools/call` no `relayMcpURL`).
- **Alterados**: `HermesMobile/Models/UserSettings.swift` — enum `ChatModelChoice`
  (`.hermesDefault`/`.gemini38Flash`), campo `chatModelChoice`, e o default (init e decode)
  mudou pra `.gemini38Flash`. `HermesMobile/Features/Chat/ChatScreen.swift` — seletor de
  modelo no popover do chip de modelo. `HermesMobile/Services/Live/LiveHermesClient.swift` —
  `modelOverride` no corpo do job. `HermesMobile/Stores/AppContainer.swift` — provider de
  `chatModelChoice`.
- **Connector**: `connector/src/hermes_mobile_connector/client.py` — `_google_api_key_for_state`
  (lê `GOOGLE_API_KEY`/`GEMINI_API_KEY` do env ou do `.env` do `HERMES_HOME`) e
  `_create_gemini_live_session` (~143 linhas): cunha token efêmero em `v1beta/auth_tokens` com
  `bidiGenerateContentSetup` (modelo `gemini-3.8-live`, voz Aoede, `systemInstruction`, tool
  `hermes_delegate`) e devolve `provider == "gemini_live"`. `talk/readiness` passa a reportar
  provider/preferredModels/voz do Gemini quando há chave Google.
- **Relay**: poucas linhas cada em `relay/app/database.py` (coluna `model_override`),
  `main.py` (repassa `provider`/`relayMcpURL`/`systemInstruction` no bootstrap e
  `modelOverride` no job), `models.py`/`schemas.py` (campo com pattern `^gemini-3\.8-flash$`)
  e `services.py` (persiste no job).
- **Aviso — arbitragem de microfone**: este caminho NÃO chama `suspendForExternalCapture()`
  por conta própria. A suspensão da wake word (seção 1) só acontece indiretamente via
  `TalkStore.onSessionStateChanged` em `AppContainer.swift`, deixando uma janela de corrida
  entre a wake word ainda segurando o microfone e o Gemini Live reconfigurando a sessão de
  áudio. Testar com Hands-Free e Talk ligados ao mesmo tempo.

## 3. Patches no relay (produção, no mesmo clone)

Não são deste repo de app, mas vivem em `/root/hermes-mobile/relay`:

- `relay/app/database.py`: `pool_pre_ping=True` (conexões velhas do pool davam 500 AdminShutdown).
- `relay/app/services.py::upsert_device`: savepoint (`db.begin_nested()`) + re-select no
  `IntegrityError` — corrige a corrida `device/register` + `phone-pairing/redeem`
  (500 `duplicate key devices_installation_id_key` no pareamento).

## 4. Build / CI

- `.github/workflows/ios-unsigned-ipa.yml` gera IPA **sem assinatura** em runner `macos-26`
  (Xcode 26.6) — repo público usa runner grátis; a assinatura fica no Sideloadly (Windows,
  conta Apple grátis, perfil de 7 dias).
- Triggers: `master`, `feat/**` e `workflow_dispatch`.

## 5. Arquivos de deploy locais (não versionados)

`relay/docker-compose.deploy.yml`, `relay/.env` — fora do git via `.git/info/exclude`.
