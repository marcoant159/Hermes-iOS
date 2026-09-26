# REPORT — actions-node24

Branch: `wip/actions-node24`
Objetivo: eliminar o aviso "Node.js 20 is deprecated ... forced to run on Node.js 24"
atualizando as actions dos 3 workflows de iOS para versões que rodam em Node 24.

## 1. Versões atuais (consultado via `gh api .../releases/latest`)

| Action | Usada hoje | Latest estável | Runtime do action.yml |
| --- | --- | --- | --- |
| `actions/checkout` | v4 | **v7.0.1** (2026-07-20) | `using: node24` |
| `actions/upload-artifact` | v4 | **v7.0.1** (2026-04-10) | `using: 'node24'` |

Nenhuma outra action é usada nos 3 workflows (grep por `uses:` confirmou só essas duas).

### Breaking changes relevantes (README/changelog)

`actions/checkout`:
- v5.0.0: passou a rodar em Node 24; exige runner >= v2.327.1 (hosted runners já atendem).
- v6.0.0: `persist-credentials` agora guarda a credencial em arquivo separado sob
  `$RUNNER_TEMP`, em vez de escrever direto no `.git/config`; melhora de segurança.
- v7.0.0: mudança para ESM, bloqueio de checkout de fork em `pull_request_target`/`workflow_run`,
  escaping de valores em `--unset`. Não usamos PR de fork nem `persist-credentials`
  customizado — os workflows só fazem checkout do próprio repo. Impacto: nenhum.

`actions/upload-artifact`:
- v5.0.0: suporte a Node 24 (tratado como breaking).
- v6.0.0: runtime padrão Node 24; exige runner >= v2.327.1.
- v7.0.0: novo parâmetro `archive: false` (upload direto de 1 arquivo), ESM.
- Arquivos ocultos: continuam **ignorados por padrão** (`include-hidden-files` default false,
  comportamento desde v4.4.0). Nossos artifacts (`Payload/` do IPA; `screenshots/`,
  `tour.mp4`, `test.log`) não contêm arquivos ocultos. Impacto: nenhum.

Decisão: usar a **tag major `@v7`** (recebe patches, padrão da comunidade).

## 2. Mudanças aplicadas

Somente linhas `uses:` dos 3 arquivos:

- `.github/workflows/ios-unsigned-ipa.yml`: `actions/checkout@v4` → `@v7`; `actions/upload-artifact@v4` → `@v7`
- `.github/workflows/ios-testflight.yml`: `actions/checkout@v4` → `@v7`
- `.github/workflows/ios-simulator-screenshots.yml`: `actions/checkout@v4` → `@v7`; `actions/upload-artifact@v4` → `@v7`

Nada mais foi alterado. `git diff` confirmou 5 linhas `uses:` alteradas, mais nada.

## 3. Validação

- [ ] `Build unsigned IPA` (workflow_dispatch, ref wip/actions-node24): verde, artifact presente, sem aviso Node 20
- [ ] `Simulator screenshots` (workflow_dispatch, ref wip/actions-node24): verde, artifact presente, sem aviso Node 20
- [ ] `TestFlight`: apenas leitura (mesmas actions; NÃO disparar)

(pendente — aguardando push/CI)
