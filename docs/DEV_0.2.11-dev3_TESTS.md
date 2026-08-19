# Matriz de pruebas 0.2.11-dev3

Esta ronda sigue siendo solo diagnóstica. No debe crear, borrar, mover ni restaurar objetos.

## Configuración común

Activar en todas las pruebas:

- `Activar mod` / `Enable mod`.
- `Escribir logs en disco` / `Write logs to disk`.
- `>> Simular recuperación de equipo (sin cambios)` / `>> Simulate equipment recovery (no changes)`.
- `Diagnóstico en consola (interruptor maestro)` / `Console diagnostics (master switch)`.
- En dedicado: `>> Reenviar logs del dedicado a clientes` / `>> Relay dedicated-server logs to clients`.
- `Activar linea temporal multietapa del cadaver` / `Enable multi-stage corpse timeline`.
- `>> Linea temporal: checkpoint adicional (segundos)` / `>> Timeline: additional checkpoint (seconds)`: 15.
- `Duración de la línea temporal del cadáver (segundos)` / `Corpse timeline duration (seconds)`: 30.
- `>>> DETALLE: muestras ausentes consecutivas requeridas` / `>>> DETAIL: consecutive missing samples required`: 2.
- `Activar comprobacion de falso positivo por jugador cercano` / `Enable nearby-player false-positive check`.
- `Buscar objetos desaparecidos que hayan sido movidos` / `Search for moved missing items`.
- `>>> DETALLE: radio de búsqueda de objetos movidos (casillas)` / `>>> DETAIL: moved-item search radius (tiles)`: 5.
- `Mostrar caso detectado sobre el observador` / `Show detected-case message above observer`.
- `>> Captura: respaldo (OnZombieUpdate)` / `>> Capture: fallback (OnZombieUpdate)`.

Mantener apagado `>>> DETALLE: diagnóstico detallado de cadáveres` / `>>> DETAIL: verbose corpse diagnostics`, salvo en los casos que lo pidan expresamente: es un sublog de alto volumen y puede perjudicar el rendimiento.

Antes de arrancar la prueba, usar la herramienta privada de extracción para archivar y vaciar completamente los registros anteriores, de modo que su primera línea de sesión pertenezca a `0.2.11-dev3`. Conservar después el `console.txt` del servidor y de al menos un cliente, además de `SiKCorpseLootGuard_losses.log`, `SiKCorpseLootGuard_summary.log`, `SiKCorpseLootGuard_cases.log`, `SiKCorpseLootGuard_recovery_simulation.log` y `SiKCorpseLootGuard_spawns.log`. La ausencia inicial de `losses` o `recovery_simulation` es normal hasta que exista una señal o decisión.

## Casos

### 1. Cobertura terminal sin saqueo

Matar al menos 50 zombis vestidos, separados y sin tocar sus cadáveres durante 45 segundos. Usar la configuración común, sin DETALLE.

Esperado: cada `DEATH_CAPTURED` termina en `CORPSE` o `PENDING_CORPSE_EXPIRED`; al estabilizarse el resumen, `deathFlow` muestra `terminalPct:100.00`, `inFlight:0`, `unaccounted:0` y `overaccounted:0`. `timeline` debe tener `active:0`, `unaccounted:0`, `overaccounted:0` y `duplicateRejected:0` tras 30 segundos adicionales. `earlyBodies` debe ser siempre un número: puede subir temporalmente y debe volver a `0` al enlazar o expirar la cola temprana.

Los zombis creados accidentalmente ya muertos no validan la captura PRE: separarlos del lote y no contarlos como muertes vivas de aceptación. `snapshots=hit/total` y cada `SNAPSHOT_MISSED` ayudan a interpretar qué alcanzó a observar el servidor, pero un artefacto ya muerto puede haber sido muestreado por otra ruta y no debe clasificarse solo por ese contador. Para aceptar DEV3 se requieren 10–20 zombis observados vivos antes de matarlos; los artefactos ya muertos pueden conservarse como prueba adicional del fallback de cadáver.

### 2. Saqueo legítimo por jugador

Sacar una prenda u objeto del cadáver antes del checkpoint de 3 segundos y conservarlo en el inventario. Repetir dejándolo en el suelo y depositándolo en un contenedor dentro de cinco casillas.

Esperado: aviso verde sobre el observador, `ITEM_MOVED_AFTER_CORPSE`, destino `player`, `world_item` o `world_container`, y simulación `WOULD_SKIP`. Nunca `WOULD_RESTORE` para ese ID.

### 3. Reaparición y contradicción

Durante una prueba dirigida, provocar que un objeto desaparezca temporalmente del cadáver y vuelva antes de concluir la timeline. Activar únicamente para este caso `>>> DETALLE: diagnóstico detallado de cadáveres` / `>>> DETAIL: verbose corpse diagnostics`.

Esperado: `MISSING_CANDIDATE_OPENED` seguido de `MISSING_CANCELLED_REAPPEARED`. Si ya se había confirmado, debe aparecer `CONFIRMED_ITEM_REAPPEARED` P1 y `WOULD_SKIP`; esta contradicción bloquea una futura restauración automática.

### 4. Cadáveres densos y correlación

Matar 20–50 zombis en un área de tres casillas, con varias muertes casi simultáneas. Activar DETALLE solo durante la reproducción.

Esperado: enlaces `onlineID`, `unique_proximity` o `high_proximity` acompañados de `candidateDetails`. Los empates reales quedan como `AMBIGUOUS_CORPSE_MATCH` y no consumen arbitrariamente otro caso. Tras el TTL, `deathFlow` debe cerrar al 100 % aunque parte termine como expirada. Cada `caseId` debe tener un solo `TIMELINE_STARTED` y un único cierre terminal.

### 5. Muertes sin golpe de arma

Repetir con fuego y vehículo. Para esta prueba usar temporalmente `>>> Captura: tasa de respaldo (1 de cada N)` / `>>> Capture: fallback sample rate (1 in N)`: 10; `>> Escaneo de cliente: intervalo (segundos)` / `>> Client scan: interval (seconds)`: 1; `>>> Escaneo de cliente: radio (casillas)` / `>>> Client scan: radius (tiles)`: 15; `>>> Escaneo de cliente: cupo por barrida` / `>>> Client scan: budget per sweep`: 10. Activar DETALLE solo durante la reproducción.

Esperado: `CLIENT_LINK`/`CLIENT_REPORT_LINKED`, historial de captura de servidor y cierre terminal de todas las muertes. Restaurar después los valores normales para no mantener un diagnóstico costoso.

### 6. Fidelidad de simulación

Revisar casos con ropa, armas, comida, drenables, contenedores, objetos genéricos moddeados y tipos naturales transitorios.

Esperado: los estados incompletos producen `NEEDS_REVIEW`; tipos transitorios producen `WOULD_SKIP`; `WOULD_RESTORE` solo aparece con descriptor completo, ID concreto, ausencia repetida, objeto no localizado y sin saqueo posible. Cada línea debe incluir `descriptorComplete`, `descriptorEligible`, `ineligibleReasons` y `mutation=false`.

### 7. Aviso visual e idiomas

Repetir un candidato y un objeto movido con cliente español e inglés.

Esperado: candidato sobre el observador, confirmación en rojo y objeto movido en verde, con el sufijo corto del `case`. El aviso debe aparecer una sola vez por estado/caso y nunca sobre un jugador no relacionado si el observador sigue conectado.

### 8. Matriz de procesos

Ejecutar al menos una muerte limpia y un saqueo legítimo en SP real, host y dedicado con cliente remoto.

Esperado: marcas `[SP]`, `[HOST]`, `[SRV]` y `[CLI]` según el proceso; el dedicado reenvía líneas `[SRV]` sin reenvolverlas ni duplicarlas. No debe aparecer ningún error de autoridad, firma de comando, API Java/Kahlua o referencia de cadáver retenida después de terminar la timeline.

En builds dedicadas donde `OnDeadBodySpawn` no emita callbacks, se acepta el fallback completo si se cumplen simultáneamente `bodyEvents.seen=0`, `scanMatches=corpseAudits`, `pending=0`, `unmatched=0`, `earlyBodies=0` y los balances de muerte/timeline quedan a cero. No se exige actividad artificial de `earlyBodies` cuando el motor no entrega el evento.

## Criterio para avanzar hacia restauración

No habilitar mutación mientras haya `unaccounted>0`, contradicciones sin explicar, asociaciones ambiguas que puedan acabar como P1/P2, o descriptores incompletos clasificados como restaurables. La primera candidata a protección real debe ser idempotente, autoritativa, por `itemId` y limitada a clases cuyo estado pueda reconstruirse sin degradación.
