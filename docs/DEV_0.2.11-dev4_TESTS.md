# Matriz focal 0.2.11-dev4

DEV4 continúa en DRY RUN. Ningún resultado, incluido `WOULD_RESTORE`, crea, borra, mueve ni restaura objetos.

## Preparación y logs

Activar:

- `Activar mod` / `Enable mod`.
- `Escribir logs en disco` / `Write logs to disk`.
- `>> Simular recuperación de equipo (sin cambios)` / `>> Simulate equipment recovery (no changes)`.
- `Diagnóstico en consola (interruptor maestro)` / `Console diagnostics (master switch)`.
- En dedicado, `>> Reenviar logs del dedicado a clientes` / `>> Relay dedicated-server logs to clients`.
- `Activar linea temporal multietapa del cadaver` / `Enable multi-stage corpse timeline`.
- `>> Linea temporal: checkpoint adicional (segundos)` / `>> Timeline: additional checkpoint (seconds)`: 15.
- `Duración de la línea temporal del cadáver (segundos)` / `Corpse timeline duration (seconds)`: 30.
- `Activar comprobacion de falso positivo por jugador cercano` / `Enable nearby-player false-positive check`.
- `Buscar objetos desaparecidos que hayan sido movidos` / `Search for moved missing items`.
- `Mostrar caso detectado sobre el observador` / `Show detected-case message above observer`.
- `>> Captura: respaldo (OnZombieUpdate)` / `>> Capture: fallback (OnZombieUpdate)`.

Mantener apagado `>>> DETALLE: diagnóstico detallado de cadáveres` / `>>> DETAIL: verbose corpse diagnostics` salvo que una prueba falle. Es un sublog masivo y puede perjudicar el rendimiento.

Antes de la ronda, descargar y vaciar los cinco logs mediante la herramienta privada. Conservar `console.txt` del dedicado y de un cliente, más `losses`, `summary`, `cases`, `recovery_simulation` y `spawns`. DEV4 no cambia nombres ni `schema=3`.

## 1. Patrón de referencia CLIENT_ONLY_VISUAL

Matar zombis vestidos hasta obtener un caso donde el cliente ve el outfit pero PRE, DEATH y el cadáver quedan vacíos. No tocar el cuerpo durante 35 segundos.

Esperado en `cases`:

- `category=CLIENT_ONLY_VISUAL` y `confirmedClientServerDesync=true`.
- `correlation=onlineID`, `confidence=exact`, `candidates=1`.
- `clientSamples>=2`, `distinctKinds>=2` y `sampleHash` estable.
- `descriptorCount=N`, `descriptorComplete=N` y `descriptorEligible=N`.
- `CLIENT_ONLY_VISUAL_RECOVERY_EVALUATED` después del último checkpoint.

Esperado en `recovery_simulation`:

```text
decision=WOULD_RESTORE source=CLIENT_MULTI_SAMPLE_DESCRIPTOR confidence=exact_onlineid_consistent_samples reason=client_outfit_never_materialized_server_side count=N mutation=false
```

La consola debe distinguir el envío `[CLI] ClientVisual` de la comparación y decisión `[SRV]`. El aviso sobre la cabeza sigue siendo un candidato diagnóstico, no una reparación.

## 2. Muestra insuficiente o cambiante

Repetir un caso donde solo llegue una muestra rica, o donde cambie el outfit/huella entre `periodic`, `preHit` y `death`. Para investigar el motivo puede activarse temporalmente `>>> DETALLE: diagnóstico detallado de cadáveres` / `>>> DETAIL: verbose corpse diagnostics`.

Esperado: `WOULD_SKIP`, con uno de `insufficient_consistent_client_samples`, `insufficient_distinct_sample_kinds`, `client_descriptor_changed` o `client_outfit_changed_or_missing`. Nunca `WOULD_RESTORE`.

## 3. Descriptor incompleto

Buscar ropa dañada, ensangrentada, mojada, con parches, un wearable contenedor con contenido o un objeto moddeado cuyo estado visual no pueda serializarse por completo.

Esperado: `descriptorComplete` o `descriptorEligible` menor que `descriptorCount`, `ineligibleReasons` explícito y `WOULD_SKIP`. El payload inválido, sobredimensionado o cuyo hash no coincide se rechaza en `[SRV] [SiKCorpseLootGuard:WARN:Network]` sin crear caso recuperable.

## 4. Loot tardío separado

Dejar que el motor añada o revele una cartera u otro loot después del primer snapshot; también abrir un contenedor wearable si aparece. No mover prendas candidatas.

Esperado: `lateAddedItems>0`, `lateAddedTypes` y `lateAddedDescriptors` con el contenido acotado. Ese loot no aumenta `descriptorEligible`, no cuenta como outfit y no impide por sí solo `WOULD_RESTORE`. Si aparece una prenda equivalente del conjunto candidato, `corpseEquivalentCount>0`, blocker `candidate_clothing_materialized_on_corpse` y `WOULD_SKIP`.

## 5. Ambigüedad e identidad

Matar varios zombis juntos y provocar, si es posible, una correlación por proximidad o con más de un candidato.

Esperado: todo `CLIENT_ONLY_VISUAL` sin `onlineID` exacto y único termina en `WOULD_SKIP` con `correlation_not_exact_onlineid` o `competing_corpse`. La coincidencia visual nunca resuelve por sí sola la identidad del cadáver.

## 6. Balance final y regresión

Matar 20 zombis vestidos vivos —no contar zombis spawneados ya muertos— y esperar 45 segundos. Repetir una muestra pequeña en SP real, host y dedicado.

Esperado:

```text
deathFlow=terminal:<N>,inFlight:0,unaccounted:0,overaccounted:0,terminalPct:100.00
timeline=...active:0,unaccounted:0,overaccounted:0
pending=0 clientReports=0 rechecks=0 earlyBodies=0
```

En una build donde `OnDeadBodySpawn` no se dispare se acepta `bodyEvents.seen=0` si `scanMatches=corpseAudits`, no quedan pendientes y todos los balances cierran. Verificar además `clientVisualRecovery=candidates:X,restore:Y,skip:Z,lateAdded:W` y que `Y + Z = X` al terminar todas las timelines.
