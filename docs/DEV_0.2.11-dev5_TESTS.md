# Matriz focal 0.2.11-dev5

DEV5 continúa en DRY RUN: incluso `WOULD_RESTORE` solo escribe evidencia y nunca crea, borra, mueve ni restaura objetos.

## Preparación y debug exacto

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

Mantener apagado `>>> DETALLE: diagnóstico detallado de cadáveres` / `>>> DETAIL: verbose corpse diagnostics`; activarlo solo para un caso dirigido. Conservar `console.txt` del dedicado y cliente y los cinco ficheros persistentes. DEV5 mantiene sus nombres y usa `schema=4`.

## 1. CLIENT_ONLY_VISUAL y reporte death tardío

Matar zombis vestidos hasta reproducir PRE/DEATH/cadáver vacíos mientras el cliente conserva el outfit. No tocar el cuerpo y esperar 45 segundos después de la última muerte.

Esperado:

- `CLIENT_ONLY_VISUAL`, correlación `onlineID/exact` y `confirmedClientServerDesync=true`.
- Si `death` llega después de `TIMELINE_STARTED`: `CLIENT_REPORT_LATE_LINKED` y `lateReports>0`.
- La evaluación final usa la muestra más reciente o rica, no una copia congelada al crear el cuerpo.
- `compositionStable=true` y `appearanceStable=true`. `stateStable=false` es admisible y debe mostrar `stateTransitions>1`.
- Si todas las prendas se resuelven de forma única y son elegibles: `WOULD_RESTORE ... mutation=false`. Si no, `WOULD_SKIP` con blocker concreto.

## 2. Resolución de InventoryItem y mochila

Buscar un caso con ropa y otro con mochila. En `recovery_simulation`, revisar `resolution=item_visual_inventory`, `resolution=client_item_unique_match` o `resolution=visual_only`.

- Una coincidencia única debe aportar clase, slot, condición e ID observado.
- Dos objetos indistinguibles no se enlazan arbitrariamente: permanecen `visual_only`.
- Una mochila con contenido conocido registra `childContent` y continúa fuera de restauración automática.
- Una mochila solo visual nunca declara contenido ni es elegible.

## 3. Cadáver exclusivo en grupo denso

Matar entre 20 y 50 zombis juntos, incluidos varios con outfits parecidos. Esperar 45 segundos.

- Cada `bodyKey` solo puede tener un `BODY_CLAIMED` efectivo.
- Un segundo intento produce una sola línea `BODY_ALREADY_CLAIMED` por caso y aumenta `bodyClaims.duplicateRejected`.
- No deben existir dos timelines con el mismo `bodyKey`.
- Un outfit distinto con correlación por proximidad es `PROXIMITY_OUTFIT_MISMATCH`, nunca `OUTFIT_REPLACED` recuperable.

## 4. Regresión y balance final

Repetir una muestra pequeña en SP real, host y dedicado. En SP no habrá canal CLI/SRV, pero la auditoría autoritativa debe cerrar. Tras 45 segundos:

```text
deathFlow=...inFlight:0,unaccounted:0,overaccounted:0,terminalPct:100.00
timeline=...active:0,unaccounted:0,overaccounted:0
pending=0 clientReports=0 rechecks=0 earlyBodies=0
```

En builds sin `OnDeadBodySpawn`, se acepta `bodyEvents.seen=0` cuando el fallback cierra todos los casos. Verificar además que `clientVisualRecovery.restore + skip = candidates` y que no queda ningún reporte tardío huérfano.
