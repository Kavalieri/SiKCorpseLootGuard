--[[
	SiK Corpse Loot Guard - Configuracion
	Autor: SiK
	Descripcion: funcionalidad EXCLUSIVAMENTE diagnostica. La simulacion de
	recuperacion solo clasifica evidencia y escribe un plan DRY RUN; no crea,
	borra, mueve ni restaura objetos. Una reparacion real sigue reservada para
	una version futura tras validar casos reproducibles e idempotentes.
]]

require "SCLG_Sandbox"

SCLG_Config = SCLG_Config or {}

--- Fuente unica de verdad para la version mostrada en consola. Debe
--- coincidir SIEMPRE con modversion en el unico mod.info de 42/ -
--- antes se repetia el numero como string suelto en varios sitios y se
--- desincronizaba (visto: mod.info decia 0.1.2 y la consola anunciaba
--- v0.1.1 porque el mensaje de carga tenia el numero escrito a mano).
SCLG_Config.MOD_VERSION = "0.2.11"

--- ID de modulo para sendClientCommand/Events.OnClientCommand (telemetria
--- ligera de cliente, ver SCLG_ClientVisualReport.lua / SCLG_Server.lua).
--- Debe coincidir EXACTO con el "id" de mod.info.
SCLG_Config.MOD_ID = "SiKCorpseLootGuard"

--- Indica si el proceso actual es responsable de la captura y auditoria.
--- En B42, SP real devuelve false tanto para isServer() como para isClient();
--- por eso solo se excluye al cliente remoto puro. Esta funcion es la unica
--- fuente de verdad para que todos los modulos server carguen con la misma
--- matriz: dedicado=true, host=true, SP=true, cliente remoto=false.
---@return boolean
function SCLG_Config.isAuthoritative()
	local client = isClient and isClient()
	local server = isServer and isServer()
	return not (client and not server)
end

--- Tiempo (ms) que se conserva una entrada "death stage" en espera de que
--- llegue OnDeadBodySpawn (o el respaldo de escaneo la encuentre) antes de
--- darla por perdida (el cadaver pudo no llegar a crearse, chunk
--- descargado, etc).
SCLG_Config.CORPSE_AUDIT_TTL_MS = 45 * 1000

--- Radio (en tiles) para correlacionar un IsoDeadBody con una entrada
--- pendiente por POSICION, cuando no se puede correlacionar por online ID
--- (ver nota en SCLG_CorpseAudit.lua sobre getCharacterOnlineID sin
--- confirmar en vanilla).
SCLG_Config.CORPSE_MATCH_RADIUS_TILES = 3

--- Cada cuanto (ms) se revisa el escaneo de respaldo de IsoDeadBody (ver
--- SCLG_CorpseAudit.scanForUnauditedCorpses) - throttle general del barrido.
SCLG_Config.CORPSE_SCAN_FALLBACK_INTERVAL_MS = 1000

--- Maximo de muertes pendientes cuyo entorno se inspecciona en cada pase
--- del fallback. Cada entrada puede consultar hasta (radio*2+1)^2 casillas;
--- el cursor rotatorio de CorpseAudit evita tanto picos como inanicion.
SCLG_Config.CORPSE_SCAN_MAX_PENDING_PER_PASS = 12

--- Edad minima (ms) de una entrada "death stage" antes de que el escaneo de
--- respaldo la considere - da tiempo de sobra a que Events.OnDeadBodySpawn
--- actue primero si existe, para que el escaneo sea solo la red de
--- seguridad y no compita con el camino normal.
SCLG_Config.CORPSE_SCAN_MIN_AGE_MS = 1500

--- Cada cuantas llamadas a OnZombieUpdate se procesa una (resto se
--- descartan sin coste). Valor de respaldo si SandboxVars no esta
--- disponible todavia (ver SCLG_Sandbox.getZombieUpdateSampleRate).
SCLG_Config.ZOMBIE_UPDATE_SAMPLE_RATE = 40

--- Tiempo minimo (ms) entre dos capturas de fallback (OnZombieUpdate) del
--- MISMO zombie, para no reescribir su snapshot en cada muestreo.
SCLG_Config.MIN_RECAPTURE_INTERVAL_MS = 3000

--- Tiempo minimo (ms) entre dos reportes de "preHit" del CLIENTE para el
--- mismo zombie (ver SCLG_ClientVisualReport.lua) - antes se enviaba UNA
--- sola vez por zombie y nunca se reintentaba; si ese unico paquete se
--- perdia (o llegaba antes de que el outfit estuviera materializado del
--- todo), el servidor se quedaba sin ningun dato de cliente para ese
--- cadaver. Ahora se reenvia en cada golpe sucesivo mientras pase este
--- intervalo desde el ultimo envio, sin llegar a saturar la red en un
--- combate con muchos golpes seguidos.
SCLG_Config.CLIENT_HIT_REPORT_MIN_INTERVAL_MS = 1500

--- TTL de los identificadores vistos en el cliente. Evita que zombies que
--- se descargan sin OnZombieDead dejen tablas crecientes durante horas.
SCLG_Config.CLIENT_REPORT_TRACK_TTL_MS = 10 * 60 * 1000

--- Limites defensivos del payload visual cliente -> servidor.
SCLG_Config.CLIENT_REPORT_MAX_TYPES = 128
SCLG_Config.CLIENT_REPORT_MAX_BYTES = 12000
SCLG_Config.CLIENT_REPORT_MAX_TYPE_BYTES = 256

--- DEV4/DEV5 añaden descriptores de ItemVisual, resolución opcional contra
--- InventoryItem cliente y huellas separadas. Se transportan en un
--- segundo string plano con limites independientes: nunca se aceptan tablas
--- anidadas ni payloads sin cota desde un cliente.
SCLG_Config.CLIENT_REPORT_MAX_DESCRIPTORS = 32
SCLG_Config.CLIENT_REPORT_MAX_DESCRIPTOR_BYTES = 48000
SCLG_Config.CLIENT_REPORT_MAX_DESCRIPTOR_FIELD_BYTES = 4096

--- El servidor liga cada observacion a la posicion real del jugador que la
--- envio. Un cliente fuera de este radio respecto al zombie que afirma ver no
--- aporta evidencia de recuperacion (aunque el reporte simple de tipos siga
--- siendo util para diagnostico).
SCLG_Config.CLIENT_REPORT_OBSERVER_RADIUS_TILES = 35

--- Compatibilidad espacial/temporal exigida a la muestra seleccionada para
--- convertir CLIENT_ONLY_VISUAL en candidato recuperable en DRY RUN.
SCLG_Config.CLIENT_RECOVERY_MAX_DEATH_DISTANCE_TILES = 3
SCLG_Config.CLIENT_RECOVERY_MAX_REPORT_AGE_MS = 30000

--- Tiempo (ms) tras el cual una entrada de la cache sin OnZombieDead
--- asociado se considera huerfana (el zombie se alejo, se descargo el
--- chunk, etc.) y se libera.
SCLG_Config.ENTRY_TTL_MS = 5 * 60 * 1000

--- Cada cuanto (ms) se intenta una barrida de limpieza de la cache.
SCLG_Config.SWEEP_INTERVAL_MS = 60 * 1000

--- Cada cuanto (ms) se imprime el resumen periodico de estadisticas.
SCLG_Config.SUMMARY_INTERVAL_MS = 5 * 60 * 1000

--- Delegado a SCLG_Sandbox (ver sandbox-options.txt, opcion VerboseDebug):
--- se mantiene esta funcion como punto unico de entrada para no tener que
--- tocar cada fichero que ya la llama.
---@return boolean
function SCLG_Config.enableDebug()
	return SCLG_Sandbox.isVerboseDebug()
end
