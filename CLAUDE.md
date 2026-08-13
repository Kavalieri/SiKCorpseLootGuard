# SiKCorpseLootGuard — Instrucciones para Claude

Mod independiente de Project Zomboid Build 42, actualmente en **modo solo-diagnóstico** (v0.1.0): detecta cadáveres de zombie que se quedan sin la ropa/objetos que llevaban al morir (visto sobre todo con outfits de Authentic Z). **No repara nada, no crea/borra/mueve objetos** — solo captura, compara y registra. Ver `../Herramientas/Deploy/SiKCorpseLootGuard/README_DIAGNOSTIC.md` para el diseño completo y el plan de pruebas.

## Reglas críticas

1. **Cero riesgo por diseño**: este mod NO modifica el inventario de ningún cadáver ni de ningún jugador — solo lee y compara. Si se pasa alguna vez a modo "reparación" activa, tratarlo como un cambio de alcance mayor, no un parche menor.
2. **Captura ANTES de morir, comparación DESPUÉS**: `Events.OnWeaponHitCharacter` (o muestreo de respaldo 1/40 en `Events.OnZombieUpdate`) captura ropa/inventario/outfit; `Events.OnZombieDead` (justo tras la reconstrucción del inventario del cadáver por el motor) vuelve a leer y compara. Si se toca esta lógica, mantener ambas rutas de captura (el respaldo cubre casos como muerte por fuego, donde `OnWeaponHitCharacter` no dispara).
3. **Servidor-only para el registro**: la comparación y el log deben procesarse una sola vez en el servidor, no una vez por cliente que observe el cadáver (evitar líneas `LOSS` duplicadas).
4. **Log persistente en fichero**, no solo consola: `SiKCorpseLootGuard_losses.log` (append-only, nunca se borra/sobrescribe) y `SiKCorpseLootGuard_summary.log` (se sobrescribe con el resumen más reciente), ambos en `<carpeta Zomboid>/Lua/` de la máquina que ejecuta el servidor.
5. **Hay 3 puntos sin confirmar documentados en el propio código** (`SCLG_Snapshot.lua`): APIs que no aparecen usadas en ningún script vanilla de la 42.20 (pueden existir vía Java aunque vanilla no las use desde Lua) — no asumir que están mal solo porque no aparecen en Lua vanilla, revisar el comentario en el fichero antes de tocarlas.
