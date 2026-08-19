# Diagnóstico y logs

SiK Corpse Loot Guard es diagnóstico: no restaura ni mueve inventario. La simulación de recuperación es un DRY RUN y tampoco muta objetos. Sus líneas indican el proceso `[CLI]`, `[SRV]`, `[HOST]` o `[SP]`. El relé del dedicado agrupa las líneas y conserva la marca `[SRV]` en la consola del cliente.

## Opciones sandbox de diagnóstico

| Clave | Español / English | Predeterminado | Función |
|---|---|---:|---|
| `EnableFileLog` | `Escribir logs en disco` / `Write logs to disk` | Sí | Activa pérdidas, resumen, casos, simulación y spawns. |
| `EnableRecoverySimulation` | `>> Simular recuperación de equipo (sin cambios)` / `>> Simulate equipment recovery (no changes)` | Sí | Evalúa qué restauraría una futura protección y por qué lo acepta o rechaza. Nunca muta inventarios. |
| `EnableConsoleLog` | `Diagnóstico en consola (interruptor maestro)` / `Console diagnostics (master switch)` | Sí | Líneas LOSS, WARN e INFO. El fichero persistente se controla por separado. |
| `RelayServerLogsToClients` | `>> Reenviar logs del dedicado a clientes` / `>> Relay dedicated-server logs to clients` | Sí | Replica por lotes acotados las líneas activas del dedicado. |
| `EnablePostAnimationRecheck` | `Activar linea temporal multietapa del cadaver` / `Enable multi-stage corpse timeline` | Sí | Activa los checkpoints acotados y la confirmación repetida de ausencias. |
| `PostAnimationRecheckDelaySeconds` | `>> Linea temporal: checkpoint adicional (segundos)` / `>> Timeline: additional checkpoint (seconds)` | 15 | Añade un checkpoint configurable a los integrados de 1, 3 y 7 segundos. |
| `VerboseDebug` | `>>> DETALLE: diagnóstico detallado de cadáveres` / `>>> DETAIL: verbose corpse diagnostics` | No | Capturas, caché, correlación y rechecks, incluso sin pérdidas. Alto volumen. |
| `EnableFallbackCapture` | `>> Captura: respaldo (OnZombieUpdate)` / `>> Capture: fallback (OnZombieUpdate)` | Sí | Activa el muestreo alternativo para muertes sin golpe de arma. |
| `ZombieUpdateSampleRate` | `>>> Captura: tasa de respaldo (1 de cada N)` / `>>> Capture: fallback sample rate (1 in N)` | 40 | Presupuesto del fallback; un número menor cuesta más. |
| `TimelineMaxSeconds` | `Duración de la línea temporal del cadáver (segundos)` / `Corpse timeline duration (seconds)` | 30 | Ventana máxima durante la que se comprueba si un objeto reaparece, se confirma ausente o se localiza movido. |
| `TimelineConfirmationSamples` | `>>> DETALLE: muestras ausentes consecutivas requeridas` / `>>> DETAIL: consecutive missing samples required` | 2 | Número de checkpoints consecutivos que deben confirmar la ausencia. Subirlo reduce falsos positivos y alarga el diagnóstico. |
| `EnableMovementSearch` | `Buscar objetos desaparecidos que hayan sido movidos` / `Search for moved missing items` | Sí | Busca por ID exacto en inventarios de jugadores, contenedores y objetos del suelo cercanos. Solo lectura y con presupuesto acotado. |
| `MovementSearchRadiusTiles` | `>>> DETALLE: radio de búsqueda de objetos movidos (casillas)` / `>>> DETAIL: moved-item search radius (tiles)` | 5 | Radio físico máximo de la búsqueda acotada. No amplía la búsqueda en inventarios de jugadores conectados. |
| `ShowCaseNotifications` | `Mostrar caso detectado sobre el observador` / `Show detected-case message above observer` | Sí | Muestra sobre el jugador observador candidato, confirmación o localización de un objeto movido. No depende del log de consola. |
| `SummaryIntervalMinutes` | `>> Salida: intervalo del resumen (minutos)` / `>> Output: summary interval (minutes)` | 5 | Cadencia del resumen acumulado. |
| `ClientVisualScanIntervalSeconds` | `>> Escaneo de cliente: intervalo (segundos)` / `>> Client scan: interval (seconds)` | 5 | Frecuencia del reporte visual de respaldo. |
| `ClientVisualScanRadiusTiles` | `>>> Escaneo de cliente: radio (casillas)` / `>>> Client scan: radius (tiles)` | 15 | Radio máximo del escaneo visual. |
| `ClientVisualScanBudgetPerTick` | `>>> Escaneo de cliente: cupo por barrida` / `>>> Client scan: budget per sweep` | 3 | Número máximo de zombis nuevos reportados por barrida. |

Ejemplos:

```text
[42.1s][CLI] [SiKCorpseLootGuard:INFO:ClientVisual] report sent | onlineID=123 kind=preHit visuals=6 pos=...
[42.2s][SRV] [SiKCorpseLootGuard:INFO:ClientServerCompare] case=... onlineID=123 clientReport=received clientKind=preHit clientVisuals=6 serverPreVisuals=6 deathInventory=6 corpseInventory=6 corpseVisuals=6 correlation=onlineID confidence=exact ...
[43.2s][SRV] [SiKCorpseLootGuard:INFO:Timeline] CHECKPOINT case=... checkpoint=2 elapsedMs=3000 missing=1 consecutive=2 moved=0
[42.2s][SRV] [SiKCorpseLootGuard:SYSTEM:Capture] DETAIL sublog enabled; high-volume output may fill console.txt; use only for targeted diagnostics
```

Sin activar `DETALLE/DETAIL`, `ClientVisual` deja una línea `[CLI]` al enviar el primer estado útil o uno más rico, y `ClientServerCompare` deja una sola línea `[SRV]` por cadáver auditado. Esta última distingue `clientReport=received clientVisuals=0` (el cliente sí vio cero) de `clientReport=missing clientVisuals=0` (no llegó reporte). Las listas completas de tipos, reintentos iguales y barridos repetitivos permanecen en `DETALLE/DETAIL`.

Cada reproducción debe indicar las opciones mínimas con sus nombres visibles en español e inglés y conservar `console.txt` más los ficheros persistentes configurados. No actives `DETALLE/DETAIL` para una sesión normal.

## Ficheros del servidor

- `SiKCorpseLootGuard_losses.log`: señales sospechosas o pérdidas, append-only.
- `SiKCorpseLootGuard_summary.log`: último resumen unificado de la sesión.
- `SiKCorpseLootGuard_cases.log`: fases correlacionadas `CLIENT`, `DEATH`, `CORPSE` y `TIMELINE`, incluidos checkpoints y casos `OK`.
- `SiKCorpseLootGuard_recovery_simulation.log`: decisiones `WOULD_RESTORE`, `NEEDS_REVIEW` o `WOULD_SKIP`; nunca es una cola de acciones.
- `SiKCorpseLootGuard_spawns.log`: solicitudes autorizadas del menú de reproducción.

El formato `schema=4` conserva `session`, `case`, `priority`, `phase`, `origin`, `eventMs`, identidad, posición y checkpoints, y añade `compositionHash`, `appearanceHash`, `stateHash`, reportes tardíos enlazados y propiedad exclusiva `bodyKey`. El resumen muestra `bodyClaims=tracked:X,duplicateRejected:Y` y `clientVisualRecovery=...,lateReports:Z`. Los balances `unaccounted` y `overaccounted` deben quedar a cero después de esperar la timeline y el TTL. La hora de pared se antepone al escribir el fichero. Consulta [CASES_AND_RECOVERY.md](CASES_AND_RECOVERY.md) para categorías y prioridades.
