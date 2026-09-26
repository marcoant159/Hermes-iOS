# REPORT — Bug 422 em `POST /v1/device/sensor/health`

Branch: `wip/health422` (worktree)

## Sintoma

O app faz `POST /v1/device/sensor/health` e o relay responde **422 Unprocessable Entity**
em todas as tentativas (78x em 2h). Nenhum dado de HealthKit chega ao connector.

## Payload real do app

Em `HermesMobile/Services/Live/SensorUploadService.swift`:

- `SensorHealthBody` (`:95-105`) → `{"samples":[{metric,value,unit,startAt,endAt}]}`
- `uploadHealth` (`:338-352`) envia **todos** os `outboxState.pendingHealthSamples`
  de uma vez, **sem chunking**.
- `drainOutboxIfPossible` (`:270-275`) só limpa o outbox quando o upload retorna
  `deliveryState == "delivered"`; em erro o outbox **nunca** é limpo.
- Amostras são acumuladas via `enqueue` e deduplicadas, então o array cresce
  indefinidamente enquanto os uploads falham (útil: era por isso que "sempre" falhava).

Métricas possíveis (`LiveHealthService.makeMetricDescriptors`, `:352-567`):
`steps, active_calories, distance_walking, heart_rate, resting_heart_rate,
blood_oxygen, respiratory_rate, body_mass, workout_minutes, stand_hours,
sleep_duration` + `user_activity` (motion). Todas as unidades são não vazias.

## Divergência encontrada

Schema do relay (`relay/app/schemas.py:164-173`):

```python
class SensorHealthSample(BaseModel):
    metric: str = Field(min_length=1, max_length=64)
    value: float
    unit: str = Field(min_length=1, max_length=32)
    startAt: str
    endAt: str | None = None

class SensorHealthRequest(BaseModel):
    samples: list[SensorHealthSample] = Field(min_length=1, max_length=100)
```

O app tem 12 métricas → envia até 12 amostras por snapshot, o que é **≤100**. O app
em si está coerente (nomes, datas ISO8601 com fração de segundo, unidades preenchidas).

**Causa raiz:** `Field(max_length=100)` em uma lista de **modelos aninhados** é
interpretado pelo Pydantic 2.13 como "máximo 100 itens **após validação**". Como cada
`Sample` é validado (com defaults aplicados, ex. `endAt=None`), `len(payload.samples)`
nunca é igual ao número de itens de entrada → o validador espera que `len == 100`
para ter sucesso e falha caso contrário. Confirmado:

```
101 itens → {'type':'too_long', ..., 'ctx': {'max_length':100, 'actual_length':101}}
 1..99/101 itens → FAIL  (só payload com exatamente 100 itens passa)
```

Ou seja: **qualquer batch com número de amostras diferente de 100 retorna 422.**
Isso explica as falhas sistemáticas — inclusive o caso de ~12 métricas.

## Correções

1. **Relay tolerante** (`schemas.py`): trocar `Field(min_length=1, max_length=100)` por
   `pydantic.conlist` e/ou validar tamanho num `field_validator` antes da validação dos
   itens. Assim `samples` aceita 1..100 itens de fato.
2. **App robusto** (`SensorUploadService.swift`): dividir em lotes de ≤100 amostras e
   drenar em loop, evitando que o outbox cresça e que o app dependa de um único request.

## Caminho downstream (connector)

`relay/app/main.py:721-743` repassa `{"type":"sensor.health","samples":[...]}` via
websocket. O connector (`connector/src/.../client.py:757-782`) converte para
`HealthSample(metric, value, unit, start_at, end_at)` e chama
`sensor_store.store_health_samples`. Métricas de janela (`steps`, etc.) são colapsadas
via `_collapse_windowed_duplicate`. O connector já aceita listas de qualquer tamanho;
basta o relay validar corretamente.

## Progresso

- [x] Localizar endpoint/schema do relay
- [x] Localizar payload real do app
- [x] Confirmar causa raiz (Pydantic nested limit)
- [x] Corrigir relay (conlist + normalização)
- [x] Corrigir app (chunking ≤100)
- [x] Testes no relay
- [ ] Rodar pytest
- [x] Commits

## Testes

`relay/tests/test_sensor_health.py` reproduz o payload do app (12 métricas, datas
com fração de segundo, `endAt: null`), regressão para 1..100 e 101+ amostras,
lista vazia e unidade vazia.

Resultado:

```
tests/test_sensor_health.py ............ 6 passed
tests/test_api.py + test_conversations.py + test_pairing.py +
tests/test_streaming.py + test_sensor_health.py ........ 40 passed
```

`tests/test_hosts.py` trava (timeout) — problema pré-existente, não relacionado a
esta mudança; conforme instruções, os demais arquivos foram rodados.
`-k health` em `test_hosts.py` não seleciona nenhum teste (exit 5).
