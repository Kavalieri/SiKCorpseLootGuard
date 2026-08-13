--[[
	SiK Corpse Loot Guard - Spawn de zombies de prueba (solo admin)
	Autor: SiK
	Descripcion: Herramienta de diagnostico. Anade un submenu "SCLG Spawn
	Test" al menu contextual de administrador, con plantillas ya
	preestablecidas de zombies Authentic Z sospechosos de perder loot al
	morir (outfits con mochila garantizada, probabilisticos y un lote
	mixto), para poder reproducir el problema bajo demanda en vez de
	esperar a que aparezca en partida.

	Reusa el mismo camino que la propia herramienta vanilla
	ISSpawnHordeUI/AdminContextMenu (media/lua/client/DebugUIs/): en
	cliente de red se manda "/createhorde2 ..." al servidor via
	SendCommandToServer; en servidor/SP real se llama directamente a
	addZombiesInOutfit(), la misma funcion nativa que usa la UI de
	Zomboid. No se reimplementa logica de spawn propia.
]]

require "SCLG_Config"
require "SCLG_Sandbox"
require "SCLG_Log"

SCLG_SpawnHordeUI = SCLG_SpawnHordeUI or {}

--- outfit, count y radius siguiendo el protocolo de prueba. IMPORTANTE:
--- radius=0 en las plantillas sueltas - con radius=1 (9 casillas posibles)
--- se vieron spawns sucesivos solapandose o cayendo en una casilla poco
--- visible, dificultando saber si un zombie pedido llego a crearse de
--- verdad. Con radius=0 cada zombie cae siempre en la misma casilla
--- exacta, visible y facil de matar antes de pedir el siguiente. El lote
--- mixto (para ver si el patron se sostiene en volumen) mantiene radius=3
--- porque ahi la superposicion es aceptable/esperada.
local TEMPLATES = {
	-- Casos 1-2 del plan de pruebas (README_DIAGNOSTIC.md): baseline vanilla,
	-- sin forzar outfit de ningun addon, para tener punto de comparacion
	-- limpio contra los casos de Authentic Z de abajo.
	{ label = "Vanilla aleatorio x1 (sin outfit forzado)", outfit = nil, count = 1, radius = 0 },
	{ label = "Vanilla aleatorio x5 (sin outfit forzado)", outfit = nil, count = 5, radius = 3 },
	{ label = "B4B Evangelo (mochila garantizada)", outfit = "AuthenticB4BEvangelo", count = 1, radius = 0 },
	{ label = "B4B Holly (mochila garantizada)", outfit = "AuthenticB4BHolly", count = 1, radius = 0 },
	{ label = "B4B Hoffman (mochila garantizada)", outfit = "AuthenticB4BHoffman", count = 1, radius = 0 },
	{ label = "B4B Mom (mochila garantizada)", outfit = "AuthenticB4BMom", count = 1, radius = 0 },
	{ label = "B4B Walker (mochila garantizada)", outfit = "AuthenticB4BWalker", count = 1, radius = 0 },
	{ label = "Santa blanco (bolsa festiva, prob.)", outfit = "AuthenticSantaWhite", count = 1, radius = 0 },
	{ label = "Santa azul (bolsa festiva, prob.)", outfit = "AuthenticSantaBlue", count = 1, radius = 0 },
	{ label = "Lote mixto: B4B Holly x5", outfit = "AuthenticB4BHolly", count = 5, radius = 3 },
	{ label = "Horda grande mixta x10 (sin outfit forzado)", outfit = nil, count = 10, radius = 4 },
}

--- Notifica al servidor que se ha pedido este spawn de prueba, para que
--- quede registrado en SiKCorpseLootGuard_spawns.log junto con hora exacta
--- y coordenadas - permite comparar despues cuantos spawns pedidos
--- llegaron realmente a procesarse como muerte (ver onClientCommand en
--- SCLG_Server.lua). Solo telemetria, no repite ni valida el spawn en si.
---@param template table
---@param x number
---@param y number
---@param z number
local function reportSpawnAttempt(template, x, y, z)
	local player = (getSpecificPlayer and getSpecificPlayer(0)) or (getPlayer and getPlayer())
	if not player then
		return
	end
	pcall(sendClientCommand, player, SCLG_Config.MOD_ID, "spawnAttempt", {
		label = template.label,
		outfit = template.outfit,
		count = template.count,
		x = x, y = y, z = z,
	})
end

---@param square any
---@param player any
---@param template table
local function spawnTemplate(square, player, template)
	local x, y, z = square:getX(), square:getY(), square:getZ()
	reportSpawnAttempt(template, x, y, z)
	if isClient() then
		-- template.outfit puede ser nil (plantillas "vanilla aleatorio", ver
		-- TEMPLATES arriba): string.format con %s y nil lanzaria un error de
		-- Lua directamente, asi que el flag -outfit solo se anade si hay un
		-- outfit concreto que pedir.
		local cmd = string.format(
			"/createhorde2 -x %d -y %d -z %d -count %d -radius %d ",
			x, y, z, template.count, template.radius)
		if template.outfit and template.outfit ~= "" then
			cmd = cmd .. "-outfit " .. template.outfit .. " "
		end
		SendCommandToServer(cmd)
	else
		addZombiesInOutfit(x, y, z, template.count, template.outfit, nil, false, false, false, false, false, false, 1.0, false, 0.0, false, false)
	end
	SCLG_Log.debug("SpawnTest", "Spawn de prueba: " .. template.label .. " en " .. x .. "," .. y .. "," .. z)
end

-- Diagnostico de la propia herramienta: se imprime UNA vez, la primera vez
-- que este cliente abre un menu contextual en el mundo, para poder ver de
-- un vistazo por que no aparece "SCLG Spawn Test" si algun dia vuelve a
-- fallar (admin no reconocido, sin square, etc.) sin tener que adivinar.
local diagnosedOnce = false

---@param player number
---@param context any
---@param worldobjects table
---@param test boolean|nil
local function doMenu(player, context, worldobjects, test)
	local eligible = SCLG_Sandbox.isSpawnMenuEnabled() and SCLG_Sandbox.isModEnabled()
		and isClient() and (isAdmin() or getAccessLevel() == "moderator")
	if not diagnosedOnce then
		diagnosedOnce = true
		-- getAccessLevel() SOLO es seguro con conexion de red activa (cliente
		-- MP/servidor) - en SP real GameClient.connection es null y la
		-- llamada lanza NullPointerException (confirmado en el log real:
		-- "Cannot invoke UdpConnection.getRole() because
		-- GameClient.connection is null"). La linea de "eligible" de arriba
		-- ya estaba a salvo por el cortocircuito de "and", pero este print
		-- de diagnostico la llamaba sin condicion ninguna, incondicional
		-- incluso en SP.
		local accessLevelStr = isClient() and tostring(getAccessLevel()) or "n/a (SP)"
		SCLG_Log.debug("SpawnTest", string.format(
			"doMenu diagnostico | isClient=%s isAdmin=%s accessLevel=%s eligible=%s worldobjects=%d",
			tostring(isClient()), tostring(isAdmin()), accessLevelStr, tostring(eligible), #worldobjects))
	end
	if not eligible then
		return true
	end
	if test and ISWorldObjectContextMenu.Test then
		return true
	end

	local square = nil
	for _, v in ipairs(worldobjects) do
		square = v:getSquare()
		break
	end
	if not square then
		SCLG_Log.debug("SpawnTest", "doMenu: sin square (worldobjects vacio en este click), no se añade el menu")
		return true
	end

	local playerObj = getSpecificPlayer(player)
	-- addOption (NO addDebugOption): addDebugOption solo anade la entrada
	-- cuando el MODO DEBUG del juego (Options > Debug, o -debug al lanzar)
	-- esta activo - no tiene nada que ver con ser admin/moderador. Confirmado
	-- como causa real de "el menu no aparece": un admin en una partida normal,
	-- sin Debug Mode activado, nunca veia la opcion aunque `eligible` diera
	-- true. addOption si respeta unicamente nuestra propia comprobacion de
	-- arriba (isAdmin()/moderator), visible siempre que el que hace clic
	-- tenga permisos, este o no en modo debug.
	local topOption = context:addOption("SCLG Spawn Test", worldobjects, nil)
	local subMenu = ISContextMenu:getNew(context)
	context:addSubMenu(topOption, subMenu)

	for i = 1, #TEMPLATES do
		local template = TEMPLATES[i]
		subMenu:addOption(template.label, square, spawnTemplate, playerObj, template)
	end
end

Events.OnFillWorldObjectContextMenu.Add(doMenu)
