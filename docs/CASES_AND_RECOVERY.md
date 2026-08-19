# Casos, prioridades y simulación de recuperación

La versión `0.2.11` sigue siendo estrictamente diagnóstica. El simulador solo escribe una decisión; no llama a `instanceItem`, `AddItem`, `Remove`, comandos de inventario ni APIs de sincronización.

## Ciclo correlacionado

Cada captura autoritativa recibe un `session` y un `case` estables. El mismo caso atraviesa:

1. `CLIENT`: apariencia observada por un cliente remoto, con identidad y posición del observador derivadas por el servidor. DEV5 transporta descriptores planos de cada `ItemVisual`, intenta enlazarlos de forma única con `worn`/`attached`/inventario y recalcula en servidor las huellas completa, de composición, apariencia y estado mutable.
2. `DEATH`: snapshot PRE conservado y estado del `IsoZombie` en `OnZombieDead`.
3. `CORPSE`: primer `IsoDeadBody`, enlazado por `onlineID` exacto o por una única proximidad en el mismo nivel Z.
4. `TIMELINE`: checkpoints a 1, 3, 7 y más segundos, hasta el máximo configurado. Una ausencia debe repetirse antes de confirmarse.
5. `LOCATOR`: si falta un ID concreto, búsqueda de solo lectura y acotada en jugadores conectados, contenedores y objetos del suelo cercanos.
6. `RECOVERY_SIM`: decisión en seco, descriptor disponible, grado de fidelidad y evidencia de confirmación.

La consola normal permite seguir la frontera cliente/servidor sin activar el sublog masivo: `[CLI] ... ClientVisual` resume lo enviado por el observador y `[SRV] ... ClientServerCompare` compara una vez los conteos `CLIENT/PRE/DEATH/CORPSE`, junto con el método y confianza de correlación. Los tipos completos permanecen en `DETALLE/DETAIL` y en los ficheros persistentes.

Una proximidad con más de un candidato se marca `AMBIGUOUS_CORPSE_MATCH` y no se consume ningún caso. Un pendiente que vence se marca `PENDING_CORPSE_EXPIRED`. Esto evita convertir una asociación dudosa en una falsa pérdida.

`OnDeadBodySpawn` alimenta una cola temprana acotada; los cuerpos que todavía no pueden enlazarse se reintentan durante cinco segundos. El escaneo de respaldo está espaciado y usa un cursor rotatorio con un máximo de doce muertes pendientes por pase. Así cubre acumulaciones sin revisar de golpe todos los radios de búsqueda en un mismo tick. Las métricas separan eventos vistos, enlaces tempranos, enlaces por escaneo, expiraciones y líneas temporales completadas.

## Prioridades

| Prioridad | Categoría | Interpretación | Simulación predeterminada |
|---|---|---|---|
| P1 | `LOSS_DURING_CORPSE_TRANSFER` | Había inventario autoritativo en DEATH y el cuerpo definitivo quedó vacío. Es la evidencia más fuerte. | `WOULD_RESTORE` solo con enlace exacto; el descriptor aún no representa todo el estado de un objeto moddeado. |
| P2 | `LOSS_DURING_ZOMBIE_REBUILD` | La apariencia PRE existía, pero nunca llegó a materializarse como inventario. | `NEEDS_REVIEW`: solo hay `fullType` visual. |
| P1 | `CONFIRMED_ITEM_REAPPEARED` / `CONFIRMED_ITEM_LATER_MOVED` | Una ausencia ya confirmada fue contradicha por evidencia posterior. | `WOULD_SKIP`; invalida cualquier automatización hasta revisar el caso. |
| P2 | `POST_ANIMATION_LOSS` | El mismo cadáver perdió objetos en varios checkpoints consecutivos y el objeto no fue localizado en otro lugar. | `WOULD_RESTORE` solo si todos los descriptores son completos y elegibles. |
| P2 | `CLOTHING_TOTAL_LOSS` / `LOSS` | Pérdida primaria en DEATH. | `NEEDS_REVIEW` salvo que exista una fuente autoritativa suficiente. |
| P2 | `CLIENT_ONLY_VISUAL` | El cliente vio equipo que el servidor nunca materializó. | `WOULD_RESTORE` en DRY RUN únicamente con `onlineID` exacto, dos o más muestras coherentes, descriptor completo, cadáver inequívoco y timeline sin prendas equivalentes. Cualquier incumplimiento produce `WOULD_SKIP`. |
| P2 | `AMBIGUOUS_CORPSE_MATCH` | Más de un cadáver podría corresponder al caso. | `WOULD_SKIP`. |
| P3 | `EMPTY_POST_NO_BASELINE` / `EMPTY_CORPSE_SUSPECT` | Cadáver vacío sin base autoritativa suficiente. | `WOULD_SKIP`. |
| P3 | `CORPSE_VISUAL_ONLY_LOSS` / `NAKED_VISUAL_BUT_PRESENT` | La apariencia desapareció, pero el inventario sigue presente. | `WOULD_SKIP`: no faltan objetos que restaurar. |
| P3 | `AUTHENTICZ_INSTANCE_FAIL` | La sonda no pudo materializar un tipo Authentic Z. | Evidencia causal; no es por sí sola una orden de restauración. |
| P4 | `OUTFIT_REPLACED` | El conjunto visual cambió por completo, sin demostrar pérdida cuantitativa. | `WOULD_SKIP`. |
| P4 | `PROXIMITY_OUTFIT_MISMATCH` | Un cuerpo enlazado solo por proximidad presenta otro outfit. Prima una correlación incorrecta. | `WOULD_SKIP`; nunca es una sustitución recuperable. |
| P4 | `ITEM_MOVED_AFTER_CORPSE` | El ID ausente del cadáver apareció en un jugador, contenedor u objeto del suelo. | `WOULD_SKIP`: fue movido, no perdido. |
| P4 | `VISUAL_DELTA`, capacidad, jugador cercano, cuerpo no enlazado | Señales contextuales o de calidad de datos. | No restaurar automáticamente. |

P1 es la máxima prioridad. El resumen cuenta casos únicos por su prioridad más alta y también muestra cada categoría observada.

## Límites de una futura restauración

Los snapshots planos conservan `fullType`, ID observado, origen/slot, clase, condición, condición máxima, ubicación corporal, favorito, nombre, usos, recuento y resumen acotado de contenido y un token acotado de `modData` escalar. Para comida, drenables, armas y ropa también registran parte de su estado específico cuando la API lo expone.

DEV5 conserva `sampleHash` completo y añade `compositionHash`, `appearanceHash` y `stateHash`. Composición y apariencia deben permanecer estables; sangre, suciedad, humedad, daño o contenidos pueden cambiar durante el combate y se registran como transiciones sin invalidar por sí solos el outfit. El servidor recalcula todas las huellas. Los reportes `death` que llegan después de crear el cadáver se enlazan con la timeline activa y la evidencia se reconstruye al cerrarla.

`ItemVisual:getInventoryItem()` sigue siendo la primera fuente. Si devuelve `nil`, el cliente busca una coincidencia única por `fullType` y ubicación corporal en `getWornItems`, `getAttachedItems` e inventario. Una coincidencia ambigua no se usa. Una mochila solo es elegible si su objeto real y su contenido se conocen por completo; observar su sprite no permite inventar ni asumir el contenido.

Cada `IsoDeadBody` recibe un `bodyKey` efímero y solo puede reclamarse por un caso durante la sesión. Un segundo intento se registra como `BODY_ALREADY_CLAIMED` y no crea otra auditoría ni timeline.

Los objetos que aparecen después en el cadáver se registran como `lateAddedItems`, con descriptor y contenido acotado. No forman parte del outfit candidato ni demuestran que la ropa se restauró; una cartera generada o abierta tarde queda separada de las prendas. Si aparece cualquier tipo equivalente al outfit candidato, la simulación se bloquea con `WOULD_SKIP`.

El descriptor clasifica además `descriptorComplete`, `recoveryEligible`, `transient` e `ineligibleReason`. Armas, ropa, comida, drenables y contenedores se consideran incompletos mientras no se pueda demostrar que todo su estado se serializa; por tanto pasan a `NEEDS_REVIEW`. Tipos naturales transitorios, como larvas o cucarachas, se excluyen de una restauración. `WOULD_RESTORE` queda reservado a evidencia fuerte, ausencia confirmada y descriptores completos; sigue sin ser una reparación real.

El aviso sobre la cabeza del observador distingue candidato, pérdida confirmada y objeto localizado como movido. Es una ayuda para comparar el registro con lo visto en pantalla, no una prueba suficiente ni una autorización para mutar inventario.

No se habilitará reparación real mientras los casos P1/P2 no demuestren una fuente reproducible y una operación idempotente sin duplicados. La salida de referencia de DEV5 es `source=CLIENT_MULTI_SAMPLE_DESCRIPTOR confidence=exact_onlineid_consistent_samples reason=client_outfit_never_materialized_server_side mutation=false`.

## Compatibilidad de logs y extracción

DEV5 no crea ni retira ficheros: mantiene `losses`, `summary`, `cases`, `recovery_simulation` y `spawns`. Eleva el contrato a `schema=4` por las huellas separadas, reportes tardíos y propiedad exclusiva del cadáver. El script privado de descarga/limpieza conserva la misma lista, pero cualquier importador que valide el esquema debe aceptar `schema=4` y los nuevos bloques `bodyClaims` y `lateReports`. Sistemas debe seguir archivando antes de vaciar y conservar propietario/permisos.

## Señal externa `ItemPickInfo`

`ItemPickInfo -> cannot get ID for container: inventorymale/inventoryfemale` es una línea `General` del motor, no de SCLG. La misma familia aparece históricamente para contenedores de vehículos de otros mods, por lo que no prueba por sí sola que Corpse Guard cause el problema. Sí puede ser relevante para la generación de loot del zombi. Los timestamps de `cases.log` permiten comprobar si aparece inmediatamente antes de un P1/P2; conservar el log completo del servidor para esa comparación.
