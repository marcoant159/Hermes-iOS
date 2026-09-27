# REPORT — session-reuse (branch wip/session-reuse)

Objetivo: fazer turnos seguintes da mesma conversa reutilizarem a sessão do Hermes
(API server) e enviarem só a mensagem nova; limitar o histórico no caminho API quando
não há sessão. Diagnóstico com evidência real (código dos dois lados + Postgres/logs).

## Log de progresso

- [x] Início: worktree `wip/session-reuse`, base feat/own-identity (df7544e).
- [x] Contexto lido (`.tmp/REPORT-speed-anterior.md`, connector, relay, `.tmp/hermes-src`).
- [x] Evidência real: Postgres (conversations/message_jobs/audit_log) + logs relay/connector.
- [x] Causa-raiz determinada (abaixo).
- [ ] Implementação + testes.
- [ ] CI verde (build IPA + screenshots).

## Causa-raiz (com evidência)

### A cadeia de sessão já está ligada de ponta a ponta

| Elo | Arquivo:linha | O que faz |
|---|---|---|
| Relay monta o job com a sessão da conversa | `relay/app/main.py:1833` | `session_id_snapshot=conversation.hermes_session_id` |
| Relay envia o id ao connector | `relay/app/main.py:612` | `job_data["sessionId"] = job.session_id_snapshot` |
| Connector repassa o id ao executor | `connector/src/.../client.py:924` | `session_id=job.get("sessionId")` |
| Executor manda o header ao Hermes | `connector/src/.../hermes_api_executor.py:249` | `X-Hermes-Session-Id` |
| Servidor reusa e devolve o id (stream) | `.tmp/hermes-src/gateway/platforms/api_server_openai_routes.py:659,685,851-852` | lê o header, carrega o histórico do `state.db` e ecoa o id |
| Executor captura o id da resposta | `hermes_api_executor.py:271` | `response.headers.get("X-Hermes-Session-Id")` |
| Connector devolve no `job.result` | `client.py:961` | `"sessionId": session_id` |
| Relay persiste na conversa | `relay/app/services.py:1416` | `conversation.hermes_session_id = session_id or ...` |

### O que o banco realmente mostra

`docker exec hermes-mobile-relay-postgres-1 psql ... SELECT`:

- `conversations`: 6 linhas, **0/6** com `hermes_session_id` preenchido.
- `message_jobs`: 14 jobs, **6 com `result_session_id`** (ex.: `api-cfb2573867d91325`,
  `api-3f8c3d08ff3c534d`). Ou seja, o id **volta** do connector.
- Conversa `f2cab8af` teve 3 turnos (15:38, 15:39, 15:40). O 1º job tem
  `session_id_snapshot` nulo; o **2º e o 3º têm `session_id_snapshot = api-cfb2573867d91325`**
  — prova de que o id foi **persistido na conversa e reenviado** no job seguinte.
- `audit_log`: `chat.conversation.create` em `f2cab8af` (21:07), `35d20802` (00:18) etc.;
  `chat.conversation.select` em 35d20802/9a2f3d64.

### Por que hoje aparece 0/6

Não é falha de plumbing: **toda conversa com sessão foi depois arquivada por "Nova conversa"**,
e `archive_current_conversation` zera a sessão de propósito:

- `relay/app/services.py:1089` — `conversation.hermes_session_id = None`
- chamada por `create_empty_conversation` (`services.py:1102`) no fluxo de nova conversa.

Isso é o comportamento desejado (nova conversa = sessão nova, como pede a tarefa). Ex.:
`f2cab8af` guardou a sessão por 3 turnos e a perdeu só quando `35d20802` foi criada; o mesmo
com `35d20802` (sessão `api-3f8c...`) quando `9a2f3d64` foi criada.

### O bug real que resta (caminho API)

Mesmo com a sessão viva, o connector **sempre reenvia o histórico inteiro** e o caminho API
**não aplica `hermes_history_limit`** (o CLI aplica em `hermes_runner.py:228`):

- `hermes_api_executor.py:63-125` (`_messages_payload`) usa `history or []` sem limite;
- `client.py:2330-2333` constrói `HermesAPIExecutor` **sem** passar `hermes_history_limit`
  (só o CLI recebe via `settings.hermes_history_limit`).

Efeito: requisição grande a cada turno; quando o servidor reusa a sessão ele **ignora** o
histórico do corpo (`api_server_openai_routes.py:685` substitui por `state.db`), então o
reenvio é desperdício; quando não há sessão (1º turno), o histórico vai sem limite.

## Implementação

Fix no **connector** (única ponta que faltava; o relay já persistia/reenviava):

| # | Arquivo | Mudança |
|---|---|---|
| 1 | `connector/src/hermes_mobile_connector/hermes_api_executor.py` | Novo campo `history_limit`; `_messages_payload(..., session_id=...)` não reenvia histórico quando há sessão e poda a cauda (`[-history_limit:]`) quando não há; `_build_payload`/`send_message`/`stream_message` encaminham `session_id`. |
| 2 | `connector/src/hermes_mobile_connector/client.py:2330` | Constrói `HermesAPIExecutor(..., history_limit=settings.hermes_history_limit)` (antes o caminho API não recebia o limite que o CLI já usa). |

Nenhuma mudança no relay (a cadeia `session_id_snapshot` → `sessionId` → `job.result.sessionId`
→ `conversation.hermes_session_id` já está correta e testada) nem no app iOS (a sessão é
zerada só em "Nova conversa", via `archive_current_conversation`, como desejado).

Os `replace(runtime.executor, ...)` dos caminhos de override de modelo e de voz preservam o
novo campo, então o limite vale para chat e delegação.

## Testes

Connector (`connector/tests/test_streaming.py`, +4):
- `test_messages_payload_omits_history_when_session_id_present` — com sessão, só a mensagem nova.
- `test_messages_payload_limits_history_tail_without_session` — sem sessão, poda para `history_limit`.
- `test_build_payload_forwards_session_id_to_messages` — `_build_payload` encaminha a sessão e omite histórico.
- `test_executor_sends_session_header_and_reads_returned_session_id` — header `X-Hermes-Session-Id`
  enviado, histórico omitido e id devolvido pelo servidor capturado (httpx `MockTransport`).

Relay (`relay/tests/test_hosts.py::test_connected_host_gets_job_and_preserves_session_resume`, já existente):
- 1º job de conversa nova: `sessionId is None` (sessão nova).
- `job.result` com `sessionId="session-123"` → 2º job recebe `sessionId == "session-123"`
  (recebido → persistido → reenviado).

## Estimativa (antes/depois)

Seja `B` o baseline (system+tools, ~20k tokens observado), `e` o tamanho médio de um turno e
`N` o número de turnos.

- **Corpo enviado connector→Hermes (upload):**
  - Antes: a cada turno o histórico inteiro (Σ_{i<k} e_i). Total em N turnos ≈ e·N(N-1)/2.
  - Depois: turno 1 sem sessão envia no máx. `history_limit` (=20) mensagens; turnos 2..N
    com sessão enviam **só a mensagem nova**. Total ≈ e·N. Redução ≈ (N-1)/2.
- **Prompt do LLM:** com sessão viva, o servidor carrega o histórico do `state.db` e ignora o
  corpo (`api_server_openai_routes.py:685`), então o prompt já era `B + Σ e_i` e continua igual
  — o ganho aqui é de **cache de prefixo** (prefixo estável por sessão) e de não reconstruir a
  sessão a cada turno. Sem sessão, o replay agora é **limitado**, evitando picos como o job
  `f1f2b336` (3.605.743 tokens de prompt) observado no Postgres.

Exemplo numérico (N=5, e≈700, B≈20k):
- Antes: upload ≈ 700·(0+1+2+3+4)=7.000 tokens; pior caso de replay sem limite já visto 3,6M.
- Depois: upload ≈ 700·5=3.500 tokens; replay sem sessão ≤ 20 mensagens.

## O que exige deploy vs. build

- **Deploy do connector** (Marco), em `/root/hermes-mobile` — itens #1 e #2. É o único necessário
  para ativar o reuso efetivo (o relay e o app já suportam).
- **Sem deploy do relay** e **sem build do app** para esta correção. (O CI build/tour é rodado
  só para manter a branch verde, conforme exigido.)

## Roteiro curto de teste no iPhone (Marco)

1. Reinicie o connector após o deploy (`systemctl restart hermes-mobile-connector`).
2. Abra o app, toque em **New conversation**, mande "Oi, tudo bem?" e cronometre.
3. Mande uma 2ª mensagem na mesma conversa ("e qual é a capital da França?") e cronometre;
   a 3ª também. Espera-se que a 2ª/3ª não fiquem mais lentas que a 1ª por reenvio de histórico
   (a sessão do Hermes é reaproveitada).
4. Confirme no Postgres que a conversa passou a ter `hermes_session_id`:
   `SELECT id, hermes_session_id FROM conversations ORDER BY updated_at DESC LIMIT 3;`
5. Toque em **New conversation** e confirme que a nova conversa começa com
   `hermes_session_id` nulo (sessão nova), como esperado.
