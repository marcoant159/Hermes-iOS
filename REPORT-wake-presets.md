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
