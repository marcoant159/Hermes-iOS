# REPORT — speed (branch wip/speed)

Objetivo: agilizar as respostas do Hermes no app (chat e voz), medindo antes de mudar.

## Log de progresso

- [x] Início: worktree limpo, branch `wip/speed`, base `feat/own-identity` (ff7d2c6).
- [x] Exploração da arquitetura (relay/connector/app), mapeada em detalhe.
- [x] Medições em produção (somente leitura: SELECT no Postgres do relay + logs copiados).
- [x] Identificação de gargalos com evidência.
- [x] Implementação + testes.
- [x] CI verde (build IPA run 36287489608 + screenshots run 36287635001).

## Arquitetura do caminho de resposta (resumo confirmado)

```
iPhone iOS
  POST /v1/messages ──► relay cria Message(user) + MessageJob(status=queued); responde 202 pending + jobId
  GET  /v1/jobs/{jobId}/events (SSE) ──► relay → async Queue → app (text_delta / tool_activity / done)
relay FastAPI
  WS /v1/hosts/ws: loop faz claim_next_message_job (poll do banco) → envia job.execute
connector (VM, mesma árvore do repo)
  runtime API HTTP local (HERMES_API_SERVER_URL=http://127.0.0.1:8642, configurado em /etc/hermes-mobile-connector.env)
  POST /v1/chat/completions stream=True → emite job.progress (text_delta/tool_activity) e job.result
  voice: RPC talk.delegate → send_message (não-streaming) com modelo rápido fixo
```

Pontos relevantes achados no código:
- Dispatch do job é por **polling do banco** dentro do WS do relay, com timeout `connector_idle_poll_interval_seconds` (default `1.0s`, `relay/app/config.py:48`). Ou seja, um job criado logo após o connector ficar ocioso espera de 0 a ~1s.
- Entrega ao app é **SSE incremental** de verdade (`text_delta`), mas o app só abre o SSE depois que o POST `/v1/messages` retorna (`LiveHermesClient.swift:179-219`).
- Depois do evento `done` (que já traz a mensagem final serializada), o app faz **um GET extra** `conversations/current` **antes** de finalizar a UI (`LiveHermesClient.swift:222-223`, `:484-500`).
- Voz (codex_live): app faz polling da delegação em **intervalo fixo de 2s** por até 10 min (`LiveVoiceSessionService.swift:1024-1056`, `Task.sleep(.seconds(2))` em `:1052`).
- Chat: há polling de segurança de 2s iniciado junto com o envio (`ChatStore.swift:108`, `:419-468`).
- Connector serializa um job de chat por vez (`_job_lock`, `client.py:808-813`).

## Medições em produção (somente leitura)

Fonte: `docker exec hermes-mobile-relay-postgres-1 psql ... SELECT` (user `hermes_relay`, db `hermes_mobile`).
Tabelas: `message_jobs` (`created_at`, `claimed_at`, `completed_at`, `result_text`, `usage_data`), `messages`, `conversations`.

### Estágios por mensagem (chat, jobs concluídos com connector online)

Filtro `claimed_at - created_at < 5s` (exclui janelas em que o connector estava offline/reconectando), n=6:

| Estágio | Medida | Valor |
|---|---|---|
| criação do job → claim pelo connector (dispatch) | p50 | **0.20 s** |
| claim → conclusão no relay (execução Hermes) | p50 | **21.5 s** |
| claim → conclusão | p90 | 32.7 s |
| criação → conclusão (total) | p50 | **21.9 s** |
| `usage.prompt_tokens` | p50 | **46 690** |
| `usage.completion_tokens` | p50 | 405 |

Amostra bruta `created_at → claimed_at → completed_at` (segundos):

```
total(fim-início)=31.9  dispatch=0.10  exec=31.8  prompt=67070
total=21.6              dispatch=0.55  exec=21.0  prompt=79866
total=22.3              dispatch=0.30  exec=22.0  prompt=46690
total=6.7               dispatch=0.10  exec=6.6   prompt=20655
total=9.0               dispatch=0.99  exec=8.0   prompt=20634
total=33.8              dispatch=0.09  exec=33.7  prompt=(sem usage)
```

### Contexto / sessão (evidência de recarga total a cada mensagem)

- `conversations.hermes_session_id`: **0 de 6 conversas** têm sessão persistida.
- Connector executa via API local; o session id só é capturado do header `X-Hermes-Session-Id` (`hermes_api_executor.py:271`); como não há sessão persistida, **todo turno reenvia o histórico inteiro e o Hermes reconstrói o contexto** (baseline ~20k tokens mesmo para pergunta trivial).
- Histórico enviado ao runtime API **não é limitado** por `hermes_history_limit` (`_messages_payload`, `hermes_api_executor.py:63-125`), ao contrário do caminho CLI (`hermes_runner.py:228`).
- `voiceTranscriptContext` (histórico de voz) é prependado à mensagem de chat e cresce sem limite.

### Voz (delegações)

- 7 POST de delegação e **61 GETs de polling** no log de 48h (`relay-docker-48h.log`) ⇒ ~8.7 polls por delegação a 2s.
- O relay responde ao GET a partir de dicionário em memória (`main.py:1287-1314`), então o custo é dominado pela espera fixa de 2s do app.

### Onde os 21s são gastos (inferência com evidência)

- `created_at`→`claimed_at` ≈ 0.2s: relay/connector dispatch.
- `claimed_at`→`completed_at` ≈ 21.5s: chamada `POST /v1/chat/completions` no Hermes local (processo/agente + raciocínio + recarga de contexto ~46k tokens). É **98% do tempo total**.
- O app some ~0.2–0.5s num round-trip extra pós-`done` (Cloudflare) e a voz some 0–2s (média ~1s) por delegação.

## Gargalos identificados (com evidência)

1. **Execução do Hermes domina (p50 21.5s, 98% do total).** Prompt de ~46k tokens (p50), sem sessão reaproveitada (`hermes_session_id` nulo em 6/6). Maior alavanca, porém `Não troque o modelo padrão do Hermes global` e não posso rodar o Hermes para medir mudanças de prompt/modelo.
2. **Dispatch do relay por polling de 1s** (`config.py:48`) — p50 0.2s porque o job costuma cair perto do ciclo; reduzir o intervalo corta a cauda de ~até 1s.
3. **Polling de voz de 2s fixo** (`LiveVoiceSessionService.swift:1052`) — atrasa a fala da resposta em até 2s (média ~1s).
4. **GET extra `conversations/current` após `done`** (`LiveHermesClient.swift:223`) — um round-trip completo (Cloudflare) antes de finalizar a UI, embora o `done` já traga a mensagem final.
5. **Sem reaproveitamento de sessão/contexto no caminho API** — recarga total a cada mensagem (item 1).
6. Serialização de jobs no connector (`_job_lock`) impede paralelismo de duas mensagens de chat.

## Implementação (menor risco / maior ganho)

Alterações escolhidas por serem isoladas e não mudarem semântica de modelo/contexto:

- **Relay**: reduzir o default de `connector_idle_poll_interval_seconds` 1.0 → 0.25 (menos cauda de dispatch). Exige deploy do relay.
- **App (voz)**: polling adaptativo da delegação (começa em 0.5s, backoff até 2s) em vez de 2s fixo. Exige build novo do app.
- **App (chat)**: quando o evento `done` já traz a mensagem final, finalizar a UI imediatamente e atualizar `currentConversation` localmente, deixando o refresh `conversations/current` em background. Exige build novo do app.

### O que foi efetivamente alterado

| # | Arquivo | Mudança | Teste |
|---|---|---|---|
| 1 | `relay/app/config.py` | default `connector_idle_poll_interval_seconds` 1.0 → 0.25 (+ `.env.example`) | `relay/tests/test_config.py::test_connector_idle_poll_interval_is_fast_by_default` |
| 2 | `HermesMobile/Services/Live/LiveVoiceSessionService.swift` | polling de delegação adaptativo (0.5s → backoff até 2s) no lugar de 2s fixo | build + tour (mock) |
| 3 | `HermesMobile/Services/Live/LiveHermesClient.swift` | fast-finish: usa a mensagem do evento `done`, atualiza conversa local e faz `conversations/current` em background | build + tour (mock) |

### Antes/depois estimado por etapa

Chat (p50, n=6 jobs com connector online):

| Etapa | Antes | Depois | Origem da melhoria |
|---|---|---|---|
| criação → claim (dispatch) | 0.20 s (cauda até 1.0 s) | ~0.06 s (cauda até 0.25 s) | #1 |
| claim → conclusão (Hermes) | 21.5 s | 21.5 s | inalterado (modelo+contexto) |
| pós-`done` até UI finalizar | ~0.2–0.5 s (GET extra) | ~0 s (GET em background) | #3 |
| **total percebido** | **~21.9 s** | **~21.6 s** | |

Voz (delegação):

| Etapa | Antes | Depois | Origem |
|---|---|---|---|
| detecção da conclusão | 0–2 s (média ~1.0 s) | 0–0.5 s (média ~0.3 s) | #2 |

> A execução do Hermes (~21.5 s, 98%) não muda com estas alterações: exige reuso de sessão/contexto ou roteamento de modelo, tratado em "Pendências".

## O que exige deploy vs. build

- **Deploy do relay** (Marco): item #1 (`CONNECTOR_IDLE_POLL_INTERVAL_SECONDS`, default 0.25). Sem env explícita, o default já vale.
- **Build novo do app**: itens #2 e #3.
- **Connector**: nenhuma alteração neste trabalho.

## Validação

- Relay: `pytest tests/test_config.py tests/test_streaming.py` (venv em `.tmp/venv-relay`) — verde.
- App: sem `xcodebuild` local (Linux); validado por CI:
  - `Build unsigned IPA` run 36287489608 — **success** (2m46s).
  - `Simulator screenshots` run 36287635001 — **success** (8m50s), 13 screenshots + `test.log` (1 teste, 0 falhas).

## Pendências (maior ganho, exige decisão/mais contexto)

1. **Reaproveitar sessão do Hermes no caminho API**: 0/6 conversas têm `hermes_session_id`; cada turno recarrega o contexto inteiro. Investigar se o API server devolve o session id (hoje só se lê o header `X-Hermes-Session-Id`); se não, usar o `id`/sessão do corpo ou manter no connector.
2. **Limitar histórico no caminho API** ao `hermes_history_limit` (o CLI já limita em `hermes_runner.py:228`; o API em `hermes_api_executor.py:63-125` não) e/ou limitar o `voiceTranscriptContext` — reduz prompt (p50 46k tokens) e tempo.
3. **Roteamento de perguntas simples para modelo rápido**: o app já expõe `ChatModelChoice` (ex.: DeepSeek V4.1 Flash) e a voz já usa `opencode-go/deepseek-v4.1-flash` com `reasoning=low`. Um roteador automático muda o default percebido — requer revisão do Marco.
4. **Streaming SSE de delegação de voz** no lugar do polling — elimina a espera do intervalo por completo.

## Roteiro curto de teste no iPhone (Marco)

1. Pareado, abra o app e mande uma mensagem de chat simples; confirme que o balão do Hermes começa a escrever e finaliza sem "sumir" a resposta (item #3) e que o ícone de "pensando" some rápido após o texto final.
2. Mande uma segunda mensagem em seguida; confirme que o histórico continua correto (merge com `conversations/current` em background).
3. Em voz (codex_live), faça uma pergunta que exija delegação ("Hermes, ...") e confirme que a resposta falada chega visivelmente mais rápido que antes (item #2).
4. Verifique que não há duplicação de mensagens na conversa após 2–3 turnos.
