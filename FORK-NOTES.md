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

## 2. Patches no relay (produção, no mesmo clone)

Não são deste repo de app, mas vivem em `/root/hermes-mobile/relay`:

- `relay/app/database.py`: `pool_pre_ping=True` (conexões velhas do pool davam 500 AdminShutdown).
- `relay/app/services.py::upsert_device`: savepoint (`db.begin_nested()`) + re-select no
  `IntegrityError` — corrige a corrida `device/register` + `phone-pairing/redeem`
  (500 `duplicate key devices_installation_id_key` no pareamento).

## 3. Build / CI

- `.github/workflows/ios-unsigned-ipa.yml` gera IPA **sem assinatura** em runner `macos-26`
  (Xcode 26.6) — repo público usa runner grátis; a assinatura fica no Sideloadly (Windows,
  conta Apple grátis, perfil de 7 dias).
- Triggers: `master`, `feat/**` e `workflow_dispatch`.

## 4. Arquivos de deploy locais (não versionados)

`relay/docker-compose.deploy.yml`, `relay/.env` — fora do git via `.git/info/exclude`.
