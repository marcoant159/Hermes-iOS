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
- [x] Build + tour verdes no CI

## O que mudou

### 1. Live Activity / Dynamic Island
- `ContentState` ganhou campos **opcionais** (`phase`, `engineName`, `prompt`,
  `answerPreview`, `progress`, `isMuted`). Nil por padrão ⇒ atividades já em curso
  continuam decodificando. As duas cópias do arquivo de atributos seguem idênticas.
- `LiveActivityService` agora expõe `startVoiceSession(engineName:)` e
  `updateVoiceState(_:phase:toolName:engineName:prompt:answerPreview:progress:isMuted:)`,
  além de `startChatResponse/updateChatResponse/finishChatResponse` e
  `startToolCall(toolName:prompt:)`.
- `TalkStore` traduz o estado para pt-BR e alimenta o activity:
  **Ouvindo / Pensando… / Falando / Consultando o Hermes…**, com cronômetro
  nativo (`Text(timerInterval:)`), nome do motor (GPT Live), trecho curto da
  pergunta e, ao concluir a delegação, prévia da resposta por 8 s. O estado de
  mudo (`isMuted`) também vai para o activity.
- `HermesLiveActivity` renderiza:
  - **lock screen**: ícone do app com selo de fase, motor, status, prompt/prévia,
    barra de progresso e botões;
  - **expanded**: leading (ícone + selo), center (motor/status/pergunta ou prévia),
    trailing (cronômetro) e bottom (progresso + botões);
  - **compactLeading**: ícone do app; **compactTrailing**: progresso %, cronômetro
    ou status curto; **minimal**: ícone do app.
- **Botões interativos** (`LiveActivityIntent`, iOS 17+): "Encerrar" e
  "Silenciar/Retomar". Como `LiveActivityIntent` roda sempre no processo do app,
  as cópias do target do widget são no-op e a ação real vive em
  `HermesMobile/System/HermesSystemIntents.swift`.
- Cores: amarelo do app (`Color.yellow`/`.tint(.yellow)`); estado de mudo em verde.

### 2. Atalhos do sistema
- `TalkWithHermesIntent` (`openAppWhenRun = true`) abre o app direto na voz GPT Live
  via `AppContainer.startVoiceConversationFromSystem()` (não duplica a lógica de
  sessão; o `VoiceOverlayScreen` já inicia a sessão ao aparecer).
- `HermesAppShortcuts` registra o atalho "Conversar com o Hermes" com frases em
  pt-BR contendo `\(.applicationName)`: **"Conversar com o Hermes"**,
  **"Falar com o Hermes"**, **"Abrir a voz do Hermes"**. Habilita Siri, app Atalhos
  e Toque Traseiro.
- `HermesTalkControlWidget` (`ControlWidget`, iOS 18+) no target do widget dispara o
  mesmo intent — Central de Controle, tela bloqueada e botão de Ação (em modelos
  compatíveis). Registrado no `HermesWidgetBundle`.
- Deeplink `hermes://` agora registrado (`Info.plist` + `project.yml`) e os hosts
  `voice`/`talk` passam pelo mesmo `startVoiceConversationFromSystem()`.

### 3. Resposta do chat em background
- O fluxo já tinha pontos de gancho: `ChatStore` streaming + `AppContainer`
  lifecycle. Ao ir para background com resposta em andamento,
  `ChatStore.beginBackgroundResponseActivityIfNeeded()` publica o activity com a
  pergunta e a prévia parcial; cada `.textDelta` atualiza; `.finished` mostra a
  prévia e encerra após 8 s. Ao voltar ao foreground,
  `endBackgroundResponseActivityIfNeeded()` recolhe o activity.

### Limitações conhecidas (documentadas, não bloqueiam)
- O tour de screenshots **não** fotografa Lock Screen/Dynamic Island; a validação
  visual do activity é manual no iPhone (roteiro abaixo).
- Live Activity não executa animações arbitrárias; usamos transições de conteúdo
  (`.contentTransition`) e o selo de fase. O cronômetro é 100% nativo.
- Se o app tiver sido encerrado pelo usuário, um toque no botão do activity
  religa o processo e a ação é best-effort (sem sessão viva para encerrar/silenciar).
- `ControlWidget` exige iOS 18+ (o alvo é iOS 26).

## Como foi validado

- `diff` das duas cópias de `HermesActivityAttributes.swift` ⇒ idênticas.
- XML do `Info.plist` e YAML do `project.yml` validados com Python.
- IDs do `project.pbxproj` conferidos (24 hex únicos; cada build file referenciado
  uma vez no Sources do target correto; chaves `{}` balanceadas).
- **CI (branch `wip/island`)**:
  - `Build unsigned IPA` — run `36284816937` ✅ (o primeiro run `36284736941`
    falhou por `static var` não-concorrente no Swift 6; corrigido para `static let`).
  - `Simulator screenshots` — run `36284916413` ✅, 13 screenshots + `test.log`
    com `** TEST SUCCEEDED **`, `Executed 1 test, with 0 failures`.

## Pendente
- Teste físico no iPhone do Marco (Dynamic Island, Lock Screen, Siri, Toque
  Traseiro, Central de Controle). Nada mais pendente de código.

## Roteiro de teste no iPhone (14 Pro Max, iOS 27)

1. **Voz / Dynamic Island**
   1. Abra o app → botão de voz (ou atalho abaixo) → inicie uma conversa.
   2. Saia do app (Home) com a conversa ativa: a **Dynamic Island** deve mostrar o
      ícone do app à esquerda e o **cronômetro** à direita; no **Minimal** (se
      houver outra atividade), só o ícone.
   3. Segure a Ilha para expandir: motor (**GPT Live**), status
      (**Ouvindo/Falando/Pensando…**), pergunta e botões **Silenciar** / **Encerrar**.
   4. Na **tela bloqueada**: cartão com status, pergunta, progresso e botões.
      Toque em **Encerrar** (deve encerrar sem abrir o app). Na próxima sessão,
      toque em **Silenciar/Retomar** e confirme o ícone de mic mudando.
   5. Peça algo que gere uma delegação ("pesquise…", "consulte…") e observe
      **Consultando o Hermes…** com barra; ao concluir, a **prévia da resposta**
      aparece por ~8 s.

2. **Siri / Atalhos / Toque Traseiro**
   1. "E aí Siri, conversar com o Hermes" → o app abre direto na voz.
   2. App **Atalhos** → ação "Conversar com o Hermes" executável.
   3. **Ajustes → Acessibilidade → Toque → Tocar Atrás** (Toque duplo ou triplo) →
      **Atalho** → "Conversar com o Hermes". Tocar atrás do telefone abre a voz.
      (O 14 Pro Max não tem Botão de Ação; é por isso que usamos Toque Traseiro.)

3. **Central de Controle / tela bloqueada**
   1. Abra a Central de Controle → editar → adicionar **"Conversar com o Hermes"**
      (categoria Hermes). Toque (ou segure, conforme o sistema) → app abre na voz.
   2. Com a tela bloqueada, o mesmo controle deve iniciar a conversa.

4. **Deeplink** (opcional, para QA): no Safari digite
   `hermes://voice` (ou `hermes://talk`) → o app abre na voz; `hermes://chat`
   volta para o chat.

5. **Chat em background**: envie uma pergunta longa no chat e mande o app para
   background logo em seguida. A Dynamic Island/Lock Screen deve mostrar
   **"Hermes está respondendo…"** com a pergunta e a prévia parcial; ao voltar
   ao app, o activity some.
