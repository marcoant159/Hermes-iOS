# REPORT — tour-mock-chat

Branch: `wip/tour-mock-chat` (worktree). Tarefa: no UI test de screenshots em
`UITEST_PAIRING_MODE=mock`, o `06-chat-reply` não mostra a mensagem enviada.

## Plano
1. Achar a causa-raiz lendo o caminho do envio (`ChatStore.sendMessage` → client),
   qual client é usado no mock e o que acontece com a mensagem otimista.
2. Correção mínima e escopada ao modo mock/Debug (sem alterar produção).
3. Validar no CI (workflow "Simulator screenshots") lendo o `test.log`.

## Investigação (arquivo:linha)
- `AppContainer.swift:154-167`: em mock ainda se usa
  `ResilientHermesClient(primary: LiveHermesClient(...), fallback: MockHermesClient())`,
  com `allowsFallback = allowMockFallbacks && (isPaired != true || usesMockPairingService)`.
- `AppContainer.swift:158-165`: `LiveHermesClient(... allowDemoFallback: allowMockFallbacks && usesMockPairingService ...)`.
  Em Debug `allowMockFallbacks == true` (`UserSettings.swift:206-211`) e o relay alvo é
  `http://127.0.0.1:8000/v1` (default de `RelayConfiguration.defaultValue`, `UserSettings.swift:69-75`),
  que não existe no runner → POST falha.
- `ChatStore.swift:645` `sendMessage`: cria mensagem otimista `.user` (status `.sending`) e um
  placeholder Hermes `.isStreaming`, e chama `hermesClient.sendStreaming(...)`.
- `ResilientHermesClient.swift:47-49` `sendStreaming`: **só** encaminha para `primary`
  (`LiveHermesClient`). Ao contrário de `send` (`:39-45`), `loadConversation` (`:51-55`) e
  `connect` (`:28-31`), **não usa o fallback**. Ou seja, em mock o streaming tenta o relay
  real e recebe `.failed` (`LiveHermesClient.swift:186-189`).
- Com `.failed` e `acceptedJobID == nil`, `ChatStore` troca o placeholder por uma mensagem de
  sistema e marca a mensagem do usuário como `.failed` (`ChatStore.swift:193-207`).
- O polling de pendências (`ChatStore.swift:426-455`) dispara 2 s depois (foi agendado antes do
  `await` do stream). Ele chama `loadConversation()` e faz
  `mergeConversationMetadata(from: local, into: fresh)` (`ChatStore.swift:470-536`). Esse merge
  **descarta** mensagens otimistas locais que não existem no servidor (só preserva placeholders
  `isStreaming`, `:531-535`).
- No mock, `MockHermesClient.loadConversation()` (`MockHermesClient.swift:96-100`) sempre
  reinicia para `DemoData.sampleConversation`, apagando o que foi enviado. Logo o refresh de 2 s
  joga fora a mensagem do usuário e a resposta/erro → no `06` só sobra a conversa de exemplo.

### Causa-raiz
1. `ResilientHermesClient.sendStreaming` não faz fallback para o `MockHermesClient`; em mock o
   envio vai ao relay real e falha.
2. `MockHermesClient.loadConversation` não persiste a conversa corrente, então o refresh do
   polling descarta a mensagem otimista (que o merge não preserva).

## Correção
- `ResilientHermesClient.sendStreaming`: quando `allowsFallback()`, segurar um `.failed` inicial
  do primary e, se nada útil foi emitido, reencaminhar o stream para o fallback. Se o primary já
  emitiu output (`.messageSent`/deltas), mantém o `.failed` (sem mudar produção; quando
  `allowsFallback()` é falso o stream do primary é devolvido intacto).
- `MockHermesClient.loadConversation`: devolver `currentConversation` se já existir, só criando o
  `DemoData.sampleConversation` na primeira vez (comportamento de backend que persiste).

## Progresso
- [x] Investigação concluída.
- [x] Correção aplicada.
- [x] Validação no CI.

## Validação
- `git push fork HEAD:wip/tour-mock-chat` + `gh workflow run "Simulator screenshots"
  -R marcoant159/Hermes-iOS --ref wip/tour-mock-chat`.
- Run `36277911628` (`screenshots`), conclusão `success` em 8m26s.
- `test.log` (artifact): `t = 43.00s Type 'Como estão os rese...'` → `t = 46.29s Find the
  "Send message" Button` → `t = 53.14s Added attachment named '06-chat-reply'`; sem `error:`;
  `Test Case '-[HermesMobileUITests.ScreenshotTourUITests testScreenshotTour]' passed`.
- `06-chat-reply.png` agora mostra a mensagem enviada **"Como estão os reservatórios?"**
  (entregue, 11:05 PM) seguida da resposta simulada
  **"I've been thinking about this. Here are a few options we could consider."**
  com o badge "Used 1 tool".

## O que mudou
- `HermesMobile/Services/Support/ResilientHermesClient.swift` (`sendStreaming`): com
  `allowsFallback()`, segura um `.failed` inicial do primary e reencaminha o stream ao fallback
  (mock) se nada útil foi emitido; se o primary já emitiu output, propaga o `.failed` como antes.
  Sem `allowsFallback()` o stream do primary é devolvido intacto (produção inalterada).
- `HermesMobile/Services/Mocks/MockHermesClient.swift` (`loadConversation`): mantém a conversa
  em memória entre reloads, em vez de sempre voltar ao `DemoData.sampleConversation`.

## Como foi validado
- Único caminho de build/run iOS é o CI. Tour de screenshots no Simulator (Debug, mock),
  confirmado pela imagem `06-chat-reply` e pelo `test.log` do run.

## Pendente / observações
- Testes unitários Swift (`HermesMobileTests`) não rodam localmente (Linux) nem no workflow de
  screenshots; não foram executados. A mudança em `MockHermesClient` é usada apenas por mocks.
- Nada foi alterado em `ScreenshotTourUITests.swift` nem em `.github/workflows/`.
- Não foi necessário `XCTAssert`/print temporário: a evidência veio do screenshot + test.log.
