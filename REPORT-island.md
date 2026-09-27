# REPORT island — Dynamic Island / Live Activities ricas + atalhos do sistema

Branch: `wip/island`
Objetivo: integração com o sistema (Dynamic Island, Lock Screen, App Intents,
App Shortcuts, Toque Traseiro, Control Center) usando o que o app já tem
(`LiveActivityService`, `TalkStore`, deeplink `hermes://`).

## Progresso

- [x] Leitura do estado atual (LiveActivityService, TalkStore, AppContainer, widget)
- [x] ContentState evoluído (2 cópias idênticas — conferido com `diff`)
- [x] Intents de Live Activity (encerrar voz / silenciar) + AppIntent "Conversar com o Hermes"
- [x] AppShortcutsProvider (frases pt-BR contendo `\(.applicationName)`)
- [x] ControlWidget na Central de Controle / tela bloqueada
- [x] Render rico no widget (compact/minimal/expanded/lock screen + botões)
- [x] Hook de resposta do chat em background
- [x] Deeplink `hermes://` registrado no Info.plist + `project.yml`
- [x] Arquivos registrados no `project.pbxproj`
- [ ] Build + tour verdes no CI

## Arquivos alterados/criados

Novos:
- `HermesMobile/System/HermesSystemIntents.swift` (app target): `EndVoiceSessionIntent`,
  `ToggleVoiceMuteIntent` (`LiveActivityIntent`), `TalkWithHermesIntent` (`openAppWhenRun`)
  e `HermesAppShortcuts` (`AppShortcutsProvider`, frases em pt-BR).
- `HermesMobileWidgets/HermesSystemIntents.swift` (widget target): cópias no-op dos
  mesmos tipos, necessárias só para o widget compilar `Button(intent:)` e o
  `ControlWidgetButton`. Por contrato, `LiveActivityIntent` roda no processo do app.
- `HermesMobileWidgets/HermesTalkControlWidget.swift`: `ControlWidget` que dispara
  `TalkWithHermesIntent` (Central de Controle / tela bloqueada, iOS 18+).

Alterados:
- `HermesMobile/Models/HermesActivityAttributes.swift` e
  `HermesMobileWidgets/HermesActivityAttributes.swift`: `ContentState` ganhou campos
  opcionais (`phase`, `engineName`, `prompt`, `answerPreview`, `progress`, `isMuted`),
  compatíveis com atividades em curso (nil por padrão).
- `HermesMobile/Services/Live/LiveActivityService.swift`: API mais rica para voz e
  chat em background, encerramento com prévia (`finishChatResponse`).
- `HermesMobile/Stores/TalkStore.swift`: estados em pt-BR (Ouvindo / Pensando… /
  Falando / Consultando o Hermes…), prompt do usuário, prévia da resposta ao fim da
  delegação (8 s), nome do motor e estado de mudo.
- `HermesMobile/Stores/ChatStore.swift`: hook de resposta em background + prompt nos
  estados de ferramenta.
- `HermesMobile/Stores/AppContainer.swift`: injeta nome do motor no `TalkStore`,
  `startVoiceConversationFromSystem()` e ganchos de background/foreground do chat.
- `HermesMobile/AppEntry.swift`: deeplink `hermes://voice|talk` usa o caminho único.
- `HermesMobile/Resources/Info.plist` + `project.yml`: registra o esquema `hermes`.
- `HermesMobileWidgets/HermesLiveActivity.swift`: render rico + botões.
- `HermesMobileWidgets/HermesWidgetBundle.swift`: inclui o `ControlWidget`.
- `HermesMobile.xcodeproj/project.pbxproj`: registra os 3 arquivos novos.

(seções de validação e roteiro de teste serão preenchidas ao final)
