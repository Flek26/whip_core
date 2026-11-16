-- Developer-mode commands: run only while developer mode is on (/w); anyone else is told so. The client twin of
-- server/commands.lua's devCommand; the server re-checks anything it does behind one.
-- Satellites can't register a command through whip_core (it would outlive them), so they ask HasDevTools() in their own handler.

--- Register a client command that works only with developer mode on.
---@param name string
---@param fn fun(source: number, args: table, raw: string)
function DevCommand(name, fn)
    RegisterCommand(name, function(source, args, raw)
        if not (DevToolsOn and DevToolsOn()) then
            UI.Notify('/' .. name .. ' is a developer tool: turn developer mode on in /w', 'error')
            return
        end
        return fn(source, args, raw)
    end, false)
end

-- ============================================
-- /tp and /tpm: the move (server/commands.lua decides, checks the permission and logs)
-- ============================================

local teleporting = false

--- The ground at x, y: GTA only knows the ground where collision has streamed in, and streams it around the entity,
--- so the entity is lowered from high up and asked at each height. Nil when there is none (the open sea).
---@param ent number
---@param x number
---@param y number
---@return number|nil
local function findGroundZ(ent, x, y)
    for probe = 1000.0, -100.0, -100.0 do
        SetEntityCoordsNoOffset(ent, x, y, probe, false, false, false)
        RequestCollisionAtCoord(x, y, probe)
        local giveUp = GetGameTimer() + 300
        repeat
            local found, z = GetGroundZFor_3dCoord(x, y, probe, false)
            if found then return z end
            Wait(0)
        until GetGameTimer() > giveUp
    end
    return nil
end

--- Move the player (and the car they drive) to x, y, z behind a fade; no z means onto the ground there. Every wait is
--- bounded, so the screen always comes back.
---@param x number
---@param y number
---@param z number|nil
---@param heading number|nil
---@return number|nil landedZ  nil when it did not run (one already under way)
local function devTeleport(x, y, z, heading)
    if teleporting then return nil end
    teleporting = true

    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    -- Only the driver takes the car: a passenger would steal it from under the driver.
    local ent = (veh ~= 0 and GetPedInVehicleSeat(veh, -1) == ped) and veh or ped

    DoScreenFadeOut(250)
    local t = GetGameTimer() + 1000
    while not IsScreenFadedOut() and GetGameTimer() < t do Wait(0) end

    -- Frozen while the world there loads, or they fall through it. Its own hold, so a downed player stays frozen
    -- (client/ped_hold.lua).
    PedHold.set('devTeleport', { frozen = true })
    if ent ~= ped then FreezeEntityPosition(ent, true) end

    local landed = z
    if landed then
        SetEntityCoordsNoOffset(ent, x, y, landed, false, false, false)
        t = GetGameTimer() + 3000
        while not HasCollisionLoadedAroundEntity(ent) and GetGameTimer() < t do
            RequestCollisionAtCoord(x, y, landed)
            Wait(0)
        end
    else
        landed = findGroundZ(ent, x, y)
        if landed then
            landed = landed + (ent == ped and 1.0 or 0.5)   -- the ped's origin is at its hips
        else
            UI.Notify('No ground found there: you are over water or out of the map', 'error')
            landed = 200.0
        end
        SetEntityCoordsNoOffset(ent, x, y, landed, false, false, false)
    end
    if heading then SetEntityHeading(ent, heading) end

    if ent ~= ped then
        FreezeEntityPosition(ent, false)
        SetVehicleOnGroundProperly(ent)
    end
    PedHold.release('devTeleport')

    DoScreenFadeIn(250)
    teleporting = false
    return landed
end

-- From the server only (/tp): RegisterNetEvent, as other clients cannot send to this one.
RegisterNetEvent('whip_core:client:devTeleport', function(x, y, z, heading)
    x, y = tonumber(x), tonumber(y)
    if not (x and y) then return end
    devTeleport(x + 0.0, y + 0.0, tonumber(z), tonumber(heading))
end)

-- /tpm: the waypoint is this client's own, so it is read here; the server is told where it went, for the log.
RegisterNetEvent('whip_core:client:devTeleportToWaypoint', function()
    local blip = GetFirstBlipInfoId(8)   -- 8: the player's map waypoint
    if not DoesBlipExist(blip) then
        UI.Notify('Set a waypoint on the map first', 'error')
        return
    end
    local at = GetBlipInfoIdCoord(blip)
    local landed = devTeleport(at.x, at.y, nil, nil)
    if landed then
        TriggerServerEvent('whip_core:server:devTeleportedToWaypoint', at.x, at.y, landed)
    end
end)
-- /car: into the driver's seat of the car the server just made (server/commands.lua). From the server only: other
-- clients cannot send to this one. The car exists here only once it has streamed in, so it is waited for (5 s).
RegisterNetEvent('whip_core:client:devSeatInCar', function(netId)
    netId = tonumber(netId)
    if not netId then return end

    local veh, giveUp = 0, GetGameTimer() + 5000
    while GetGameTimer() < giveUp do
        if NetworkDoesNetworkIdExist(netId) then
            veh = NetworkGetEntityFromNetworkId(netId)
            if veh ~= 0 and DoesEntityExist(veh) then break end
        end
        Wait(100)
    end
    if veh == 0 or not DoesEntityExist(veh) then return end

    SetPedIntoVehicle(PlayerPedId(), veh, -1)

end)
--- For satellites: is developer mode on for this player? Only for what a client tool shows; the server's HasDevTools(source) is authoritative.
exports('HasDevTools', function()
    return (DevToolsOn and DevToolsOn()) == true
end)

-- /whiperrors [resource]: this game's error log, grouped by resource, in F8 (the server console's is whiperrors there).
DevCommand('whiperrors', function(_, args)
    local only = args[1]
    local logged = ErrorTap.read({ max = 200 })
    local by, order = {}, {}
    for _, e in ipairs(logged and logged.entries or {}) do
        local res = tostring(e.resource or '?')
        if not only or res == only then
            if not by[res] then by[res] = {}; order[#order + 1] = res end
            table.insert(by[res], e)
        end
    end
    if #order == 0 then print(only and ('[whip] no errors from %s in this game'):format(only) or '[whip] no errors in this game') return end
    table.sort(order, function(a, b) return #by[a] > #by[b] end)
    for _, res in ipairs(order) do
        local list = by[res]
        print(('[whip] ^1%s^0: %d'):format(res, #list))
        for i = math.max(1, #list - 4), #list do
            local text = tostring(list[i].text):gsub('\n.*', '')
            print('[whip]     ' .. text:sub(1, 300))
        end
    end
    UI.Notify('Errors printed in F8', 'info')
end)