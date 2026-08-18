# Casos, prioridades y simulación de recuperación

La versión `0.2.10` sigue siendo estrictamente diagnóstica. El simulador solo escribe una decisión; no llama a `instanceItem`, `AddItem`, `Remove`, comandos de inventario ni APIs de sincronización.

## Ciclo correlacionado

Cada captura autoritativa recibe un `session` y un `case` estables. El mismo caso atraviesa:

1. `CLIENT`: apariencia observada por un cliente remoto, con identidad del observador derivada por el servidor.
2. `DEATH`: snapshot PRE conservado y estado del `IsoZombie` en `OnZombieDead`.
3. `CORPSE`: primer `IsoDeadBody`, enlazado por `onlineID` exacto o por una única proximidad en el mismo nivel Z.
4. `RECHECK`: el mismo cuerpo unos segundos después.
5. `RECOVERY_SIM`: decisión en seco y evidencia disponible.

La consola normal permite seguir la frontera cliente/servidor sin activar el sublog masivo: `[CLI] ... ClientVisual` resume lo enviado por el observador y `[SRV] ... ClientServerCompare` compara una vez los conteos `CLIENT/PRE/DEATH/CORPSE`, junto con el método y confianza de correlación. Los tipos completos permanecen en `DETALLE/DETAIL` y en los ficheros persistentes.

Una proximidad con más de un candidato se marca `AMBIGUOUS_CORPSE_MATCH` y no se consume ningún caso. Un pendiente que vence se marca `PENDING_CORPSE_EXPIRED`. Esto evita convertir una asociación dudosa en una falsa pérdida.

El escaneo de respaldo está espaciado y usa un cursor rotatorio con un máximo de ocho muertes pendientes por pase. Así cubre acumulaciones sin revisar de golpe todos los radios de búsqueda en un mismo tick.

## Prioridades

| Prioridad | Categoría | Interpretación | Simulación predeterminada |
|---|---|---|---|
| P1 | `LOSS_DURING_CORPSE_TRANSFER` | Había inventario autoritativo en DEATH y el cuerpo definitivo quedó vacío. Es la evidencia más fuerte. | `WOULD_RESTORE` solo con enlace exacto; el descriptor aún no representa todo el estado de un objeto moddeado. |
| P2 | `LOSS_DURING_ZOMBIE_REBUILD` | La apariencia PRE existía, pero nunca llegó a materializarse como inventario. | `NEEDS_REVIEW`: solo hay `fullType` visual. |
| P2 | `POST_ANIMATION_LOSS` | El mismo cadáver perdió objetos entre CORPSE y RECHECK sin jugador cercano. | `WOULD_RESTORE` desde el descriptor del primer cuerpo. |
| P2 | `CLOTHING_TOTAL_LOSS` / `LOSS` | Pérdida primaria en DEATH. | `NEEDS_REVIEW` salvo que exista una fuente autoritativa suficiente. |
| P2 | `CLIENT_ONLY_VISUAL` | El cliente vio equipo que el servidor nunca observó. | `WOULD_SKIP`: la evidencia del cliente no autoriza crear objetos. |
| P2 | `AMBIGUOUS_CORPSE_MATCH` | Más de un cadáver podría corresponder al caso. | `WOULD_SKIP`. |
| P3 | `EMPTY_POST_NO_BASELINE` / `EMPTY_CORPSE_SUSPECT` | Cadáver vacío sin base autoritativa suficiente. | `WOULD_SKIP`. |
| P3 | `CORPSE_VISUAL_ONLY_LOSS` / `NAKED_VISUAL_BUT_PRESENT` | La apariencia desapareció, pero el inventario sigue presente. | `WOULD_SKIP`: no faltan objetos que restaurar. |
| P3 | `AUTHENTICZ_INSTANCE_FAIL` | La sonda no pudo materializar un tipo Authentic Z. | Evidencia causal; no es por sí sola una orden de restauración. |
| P4 | `OUTFIT_REPLACED` | El conjunto visual cambió por completo, sin demostrar pérdida cuantitativa. | `WOULD_SKIP`. |
| P4 | `VISUAL_DELTA`, capacidad, jugador cercano, cuerpo no enlazado | Señales contextuales o de calidad de datos. | No restaurar automáticamente. |

P1 es la máxima prioridad. El resumen cuenta casos únicos por su prioridad más alta y también muestra cada categoría observada.

## Límites de una futura restauración

Los snapshots planos conservan `fullType`, ID observado, condición, condición máxima, ubicación corporal y favorito. Eso permite medir qué se perdió, pero no garantiza recrear fielmente `modData`, color, sangre, agujeros, contenido interno, adjuntos o estado propio de clases moddeadas. Por eso `WOULD_RESTORE` significa “candidato fuerte”, no “reparación ya segura”.

No se habilitará reparación real mientras los casos P1/P2 no demuestren una fuente reproducible y una operación idempotente sin duplicados.

## Señal externa `ItemPickInfo`

`ItemPickInfo -> cannot get ID for container: inventorymale/inventoryfemale` es una línea `General` del motor, no de SCLG. La misma familia aparece históricamente para contenedores de vehículos de otros mods, por lo que no prueba por sí sola que Corpse Guard cause el problema. Sí puede ser relevante para la generación de loot del zombi. Los timestamps de `cases.log` permiten comprobar si aparece inmediatamente antes de un P1/P2; conservar el log completo del servidor para esa comparación.
