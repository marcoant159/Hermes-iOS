# REPORT — sessions (branch `wip/sessions`)

Objetivo:
- Tarefa 1: remover o modelo GPT-5.6 Luna (app, relay, connector + testes).
- Tarefa 2: suportar várias conversas (relay endpoints + app: nova conversa, lista, selecionar).

## Log de progresso

- [x] Início: exploração do repositório.
- [x] Tarefa 1: removido `gpt56Luna` de `ChatModelChoice` (decode cai em `.hermesDefault`
      via `ChatModelChoice(rawValue:) ?? .hermesDefault`); removido `openai-codex/gpt-5.6-luna`
      das allowlists do relay e do connector; testes paramétricos agora exigem rejeição.
      - Relay: `pytest -q tests/test_model_overrides.py` → 11 passed.
      - Connector: venv é editable apontando para `/root/hermes-mobile/connector` (repo principal);
        rodei com `PYTHONPATH=src` para usar este worktree → 14 passed.

## Notas de ambiente

- `connector/.venv` está instalado em modo editable apontando para
  `/root/hermes-mobile/connector/src` (fora deste worktree). Para testar este worktree,
  usar `PYTHONPATH=src`.
