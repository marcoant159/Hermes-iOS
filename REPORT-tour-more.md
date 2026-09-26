# Relatório: tour-more

Branch: `wip/tour-more` — estende `HermesMobileUITests/ScreenshotTourUITests.swift` com
telas de conversas, nova conversa, seletor de modelo e voz (numeração a partir de 10).

## Seletores descobertos (lendo o SwiftUI)

- Lista de conversas: `app.buttons["Conversations"]` (`ChatScreen.swift:230`, `GlassCircleButton`).
- Nova conversa: `app.buttons["New conversation"]` (`ChatScreen.swift:233`); a sheet da lista
  também tem toolbar `Button("New")` (`ChatScreen.swift:139`).
- Seletor de modelo: chip de status no `topBarLeading` (`ChatScreen.swift:226`, `modelStatusChip`).
  Sem `accessibilityLabel`; o rótulo do Button é o nome do modelo. No modo mock o host expõe
  `hermesModel: "gpt-5.4-mini"` (`MockHermesHostService.swift:13`), então o rótulo é
  `gpt-5.4-mini`. Popover mostra "Model for new messages" (`ChatScreen.swift:343`).
- Voz: `app.buttons["Start voice mode"]` (`ChatInputBar.swift:153`) apresenta `VoiceOverlayScreen`
  via `router.isVoiceOverlayPresented` (`ContentView.swift:19`). Fechar:
  `app.buttons["End voice session"]` / `app.buttons["Close"]` (`VoiceOverlayScreen.swift:259,274`).
- Voltar do host para o chat após o passo 09: botão back da navigation bar
  (`ConnectHermesHostScreen` é empilhado após dispensar a sheet de Settings).

## Passos

- [x] Edição do teste: adiciona voltar do host para o chat e os passos 10–13
  (`10-conversations`, `11-new-conversation`, `12-model-picker`, `13-voice-mode`),
  mantendo o estilo tolerante (`tapIfExists`, `continueAfterFailure = true`).
  `import CoreGraphics` para o `CGVector` usado ao dispensar o popover de modelo.
- [x] Validação no CI light — run `36277944106` (branch `wip/tour-more`), success.
  `Executed 1 test, with 0 failures`. Cada passo novo achou o elemento:
  `Tap "BackButton" Button`, `Tap "list.bullet" Button` (Conversations),
  `Tap "Done" Button`, `Tap "square.and.pencil" Button` (New conversation),
  `Tap "gpt-5.4-mini" Button` (model chip, via `matching(...).firstMatch`),
  `Tap "waveform" Button` (Start voice mode), `Tap "xmark" Button` (End voice session).
  Nenhum `error:` no log.
- [x] Validação no CI dark — run `36279532171` (branch `wip/tour-more`, `-f appearance=dark`), success.
  Todos os 13 passos gerados e cada novo achou o elemento:
  `Tap "BackButton" Button`, `Tap "list.bullet" Button` (Conversations),
  `Tap "Done" Button`, `Tap "square.and.pencil" Button` (New conversation),
  `Tap "gpt-5.4-mini" Button`, `Tap "waveform" Button` (Start voice mode),
  `Tap "xmark" Button` (End voice session). `Executed 1 test, with 0 failures`.

  Observação: a 1ª tentativa dark (`36278813791`) teve flakiness pré-existente do pareamento
  (após "Connect Hermes" o "Continue" não apareceu, o app ficou na tela de pareamento e o tour
  só gerou `01`,`02`,`04`). Reexecução passou limpa. O artifact do run dark de sucesso também
  contém um `Crash Log ...ips` do **SpringBoard** (não do app), sem impacto no teste.

### Screenshots gerados (`.tmp/run-<id>/*/screenshots/`)

Light `36277944106` e dark `36279532171` geraram os mesmos nomes:

`01-onboarding.png`, `02-pairing-code.png`, `03-after-pairing.png`, `04-chat.png`,
`05-chat-typing.png`, `06-chat-reply.png`, `07-settings.png`, `08-settings-scrolled.png`,
`09-host.png`, `10-conversations.png`, `11-new-conversation.png`, `12-model-picker.png`,
`13-voice-mode.png`.

Novos passos (confirmados visualmente nos PNGs):
- `10-conversations`: sheet "Conversations" com toolbar New/Done.
- `11-new-conversation`: chat após acionar o compose.
- `12-model-picker`: popover com "MODEL FOR NEW MESSAGES" e Context Window.
- `13-voice-mode`: `VoiceOverlayScreen` ("Hermes Voice", orb, "Listening").

### Notas de implementação

- Após `09-host` o app está em `ConnectHermesHostScreen` (empilhado). O teste toca o
  botão back (`app.navigationBars.buttons["Back"]`, fallback `firstMatch`) para voltar ao chat.
- Passo 10: `Conversations` abre a sheet; fecha com `Done` antes do próximo passo.
- Passo 11: `New conversation` (cria conversa via mock).
- Passo 12: o chip é um Button cujo rótulo é o nome do modelo; usa-se
  `app.buttons.matching(NSPredicate(label CONTAINS "gpt-5.4-mini")).firstMatch`.
  Dispensa-se o popover com um tap em coordenada (evita casar com os botões de modelo do popover).
- Passo 13: `Start voice mode` apresenta `VoiceOverlayScreen`, que auto-inicia sessão mock.
  `app.tap()` aciona o interruption monitor (caso apareça alerta de microfone) e fecha-se com
  `End voice session` (ou `Close`).
