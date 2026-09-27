# REPORT — wake-presets

Tarefa: frase de ativação Hands-Free configurável por presets, casamento tolerante
e robustez do listener. Branch `wip/wake-presets`.

## Passo 0 — reconhecimento (2026-09-27)

- Worktree em `/root/hermes-mobile-wt/wake-presets`, base = `feat/own-identity` (ff7d2c6),
  igual ao HEAD inicial (merges de wip/tour-more, wip/wake-latency, etc.).
- Arquivos-chave lidos:
  - `HermesMobile/Services/Live/LiveWakeWordService.swift` (902 linhas) — serviço + `WakeListener`.
  - `HermesMobile/Models/UserSettings.swift` — persistência com `decodeIfPresent` (migração segura).
  - `HermesMobile/Features/Settings/SettingsScreen.swift` — seção "Hands-Free" + toggle.
  - `HermesMobile/Stores/AppContainer.swift` — fiação `onWakeActivation`/`talkStore`.
  - `HermesMobileTests/` — Swift Testing (`@Test`/`#expect`), target de testes.
  - `HermesMobileUITests/ScreenshotTourUITests.swift` — tour de screenshots.
- Não há nenhuma referência a "ermes"/wake phrase nos UI tests; a seção Hands-Free
  aparece nos screenshots 07/08 apenas como seção (o tour não interage com o toggle).
- Plano de implementação registrado abaixo.

## Pendências iniciais
- [ ] Modelo de preset (`WakePhrase`) + persistência em `UserSettings`.
- [ ] Matcher estático/testável + variantes.
- [ ] Integração no `LiveWakeWordService` (frase vinda das settings).
- [ ] UI em Ajustes → Hands-Free (picker + campo personalizado + textos de ajuda).
- [ ] Robustez do listener (recognizers/áudio).
- [ ] Testes unitários + registro no pbxproj.
- [ ] Build + tour verdes no CI.

## Passo 1 — modelo + persistência + service + UI (2026-09-27)

- Novo `HermesMobile/Models/WakePhrase.swift`:
  - `WakePhrasePreset` (oiHermes, eiJarvis, oiAtlas, computador, custom) e
    `WakePhrase` com `match(in:)`.
  - Normalização: minúsculas + `diacriticInsensitive`; variantes por preset
    (hermes/ermes/hermis, jarvis/jarves/jarbas/jarvi, atlas, computador);
    prefixos opcionais (oi/ei/ok/olá/e aí).
  - Regra documentada: a palavra de ativação tem de estar no INÍCIO do segmento
    (prefixo opcional antes); nunca no meio da frase. Custom usa
    Damerau–Levenshtein ≤1 por palavra com ≥5 letras.
  - Prefixo pode ter sido transcrito errado e ainda casa se cair na lista de
    prefixos conhecidos (ex.: "é mesmo" ~ "oi hermes"); caso contrário o prefixo
    pode sumir e só a palavra de ativação no início conta.
- `UserSettings`: `wakePhrasePreset` + `wakePhraseCustomText`, com
  `decodeIfPresent` (migração segura, padrão = Oi Hermes).
- `LiveWakeWordService`: frase configurável (`apply(settings:)`, `currentPhraseText`),
  casa parciais dentro do segmento-gatilho (não só finais), `commandAfterTrigger`
  agora usa `WakePhrase`. Matcher puro/testável em `WakePhrase`.
- `SettingsStore.onWakePhraseChanged` + fiação no `AppContainer`.
- UI em Ajustes → Hands-Free: lista de presets + campo "Personalizada" + textos
  de ajuda/rodapé mostrando a frase escolhida.
- Validação lógica do matcher feita com script Python espelhando o algoritmo
  (`/tmp/opencode/check.py`); resultados esperados.

### Nota sobre "é mesmo"
`fold("é mesmo")` -> `["e","mesmo"]`. Tokens `["e","mesmo"]` casam com a frase
"oi hermes" via prefixo conhecido ("e" está na lista) + "mesmo" a 1 edição de
"hermes" (Damerau). Isso mantém o ganho de sensibilidade pretendido. O falso
positivo "o atlas geográfico" NÃO dispara porque "o" está fora da frase e a
palavra de ativação não está no início.

## Passo 2 — robustez do listener (2026-09-27)

Causas investigadas e correções (mínimas, sem tocar em GPT Live/TalkStore):

1. **"Maximum number of recognizers reached"**
   - Causa A: `startSegment()` criava `DictationTranscriber` + `SpeechAnalyzer`
     novos sem que o teardown anterior tivesse terminado
     (`LiveWakeWordService.swift` `endSegment` não aguardava `cancelAndFinishNow`
     em `start`? e `restartIfNeeded` só checava `isSegmentRunning`, não o
     teardown em andamento). Em `forceRestart`/`recoverIfNeeded` corria tocar
     `startSegment` durante um `cancelAndFinishNow` pendente.
   - Correção: flag `isSegmentTearingDown` serializa os teardowns; `endSegment`
     marca/desmarca e `restartIfNeeded`/`forceRestart`/`recoverIfNeeded` esperam;
     `recoverIfNeeded` passou a comparar com `audioEngine.isRunning` e não só
     `isSegmentRunning`.
   - Causa B: `startSegment` podia preparar o analyzer sem o engine vivo.
     Correção: guard `audioEngine.isRunning` no início de `startSegment`.
2. **AVFAudio (-10868 / 2003329396 / OSStatus 560557684) no rearme e troca de mic**
   - Causa A: `activateSession()` chamava `setCategory(.playAndRecord, ...)`
     **sempre**, mesmo com a sessão já ativa — reconfigurar a categoria repetidas
     vezes gera esses OSStatus. Correção: só reconfigura se categoria/modo
     diferirem (`sessionConfigured`).
   - Causa B: o tap era instalado uma vez com o `converter` capturado; se o
     formato do `inputNode` mudasse (troca de microfone), o buffer saía com
     formato errado. Correção: `updateConverter(for:)` recalcula a cada
     `startSegment` e o tap passa a capturar o converter corrente; guard de
     formato mínimo (sampleRate ≥ 8000).
   - Causa C: `stop()` disparava `analyzer.cancelAndFinishNow()` num Task solto,
     competindo com o próximo start (toggle rápido liga/desliga). Correção:
     `isSegmentTearingDown` é zerado antes de liberar e a tarefa de teardown é
     cancelada.

## Passo 3 — validação CI

- Build unsigned IPA: **verde** (run 36284713893, após corrigir 1 erro de
  compilação: `commandAfterTrigger` marcado `nonisolated` mas lia `wakePhrase`
  isolado ao MainActor).
- Tour de screenshots: em execução (run seguinte).

## Pendente
- Tour de screenshots verde.
- Testes unitários rodam junto do build/test do CI? conferir se o workflow
  executa `HermesMobileTests` (o build compila o target de testes).

## Passo 4 — conclusão (2026-09-27)

Ambos os runs da branch `wip/wake-presets` ficaram **verdes**:
- Build unsigned IPA: run `36284713893` (success).
- Simulator screenshots: run `36284852250` (success, 11m19s);
  `test.log` mostra `ScreenshotTourUITests testScreenshotTour` **passed** e o
  screenshot `08-settings-scrolled` mostra a seção HANDS-FREE com o texto
  'Say "Oi Hermes" …' (padrão preservado).

## O que mudou

| Arquivo | Mudança |
|---|---|
| `HermesMobile/Models/WakePhrase.swift` (novo) | Presets, variantes, normalização, distância de edição e `match(in:)`. |
| `HermesMobile/Models/UserSettings.swift` | `wakePhrasePreset` + `wakePhraseCustomText` (decode seguro, default Oi Hermes). |
| `HermesMobile/Services/Live/LiveWakeWordService.swift` | Frase configurável (`apply(settings:)`), casamento de parciais dentro do segmento-gatilho, robustez do listener. |
| `HermesMobile/Features/Settings/SettingsScreen.swift` | UI de presets + campo personalizado + textos de ajuda com a frase. |
| `HermesMobile/Stores/SettingsStore.swift` | `onWakePhraseChanged`. |
| `HermesMobile/Stores/AppContainer.swift` | Aplica a frase no arm e ao mudar as settings. |
| `HermesMobileTests/WakePhraseTests.swift` (novo) | Testes do matcher (presets, variantes, custom, falsos positivos). |
| `HermesMobile.xcodeproj/project.pbxproj` | Registro à mão dos 2 arquivos novos (app + testes). |

## Como foi validado
- Análise lógica do matcher com script Python espelhando o algoritmo
  (`/tmp/opencode/check.py`).
- `pbxproj` validado com o parser `pbxproj` (parse OK, IDs 24-hex únicos).
- CI: build + tour de screenshots verdes na branch.

## O que ficou pendente
- Testes unitários (`WakePhraseTests`) **não** são executados pelo CI atual: os
  workflows compilam/rodam o app e o tour UI, mas não há step de `xcodebuild test`
  do target `HermesMobileTests`. Os testes foram escritos e registrados, prontos
  para rodar quando houver step de testes; recomendo adicionar um workflow
  "Unit tests" (fora do escopo desta tarefa).
- Validação acústica real (microfone) depende do iPhone do Marco — roteiro abaixo.

## Roteiro curto de teste no iPhone (Marco)
1. Instale o build da branch. Ajustes → Hands-Free → ligue **Wake Word**.
2. Confira que aparece **Activation phrase** com **Oi Hermes** marcado.
3. Diga "oi hermes" e depois "oi ermes" perto do aparelho: o beep + sessão GPT
   Live devem abrir mesmo sem gritar.
4. Diga "oi hermes, que horas são": a pergunta deve ir direto para o Hermes.
5. Troque para **Ei Jarvis**, diga "ei jarvis"/"ei jarbas" (deve abrir) e
   "oi hermes" (não deve abrir).
6. Escolha **Personalizada**, digite um nome seu (ex.: "Bom dia Hermes") e diga
   a frase: deve abrir; diga o nome no meio de outra frase e não deve abrir.
7. Bloqueie/desbloqueie o iPhone, toque uma música e faça uma chamada: ao voltar,
   confira nos Ajustes que o listener voltou para "Listening for …" sem travar.
