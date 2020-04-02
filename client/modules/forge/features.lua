------------------------------------------------------------------------------
-- Forge Features
-- Author: Sledmine
-- Version: 1.0
-- Forging features
------------------------------------------------------------------------------

local blam = require 'lua-blam'
local constants = require 'forge.constants'

local features = {}

-- Credits to Devieth and IceCrow14
---@param target number
---@param sensitivity number
---@param zOffset number
function features.playerIsLookingAt(target, sensitivity, zOffset)
    local baseline_sensitivity = 0.012 -- Minimum for distance scaling.
    local function read_vector3d(Address)
        return read_float(Address), read_float(Address + 0x4), read_float(Address + 0x8)
    end
    local m_object = get_dynamic_player()
    local m_target_object = get_object(target)
    if m_target_object and m_object then -- Both objects must exist.
        local player_x, player_y, player_z = read_vector3d(m_object + 0xA0)
        local camera_x, camera_y, camera_z = read_vector3d(m_object + 0x230)
        local target_x, target_y, target_z = read_vector3d(m_target_object + 0x5C) -- target Location2
        local distance = math.sqrt((target_x - player_x) ^ 2 + (target_y - player_y) ^ 2 + (target_z - player_z) ^ 2) -- 3D distance
        local local_x = target_x - player_x
        local local_y = target_y - player_y
        local local_z = (target_z + zOffset) - player_z
        local point_x = 1 / distance * local_x
        local point_y = 1 / distance * local_y
        local point_z = 1 / distance * local_z
        local x_diff = math.abs(camera_x - point_x)
        local y_diff = math.abs(camera_y - point_y)
        local z_diff = math.abs(camera_z - point_z)
        local average = (x_diff + y_diff + z_diff) / 3
        local scaler = 0
        if distance > 10 then
            scaler = math.floor(distance) / 1000
        end
        local auto_aim = sensitivity - scaler
        if auto_aim < baseline_sensitivity then
            auto_aim = baseline_sensitivity
        end
        if average < auto_aim then
            return true
        end
    end
    return false
end

-- Changes default crosshair values
---@param state number
function features.setCrosshairState(state)
    local forgeCrosshairAddress = get_tag('weapon_hud_interface', constants.weaponHudInterfaces.forgeCrosshair)
    if (state == 0) then
        blam.weaponHudInterface(
            forgeCrosshairAddress,
            {
                defaultRed = 64,
                defaultGreen = 169,
                defaultBlue = 255,
                sequenceIndex = 1
            }
        )
    elseif (state == 1) then
        blam.weaponHudInterface(
            forgeCrosshairAddress,
            {
                defaultRed = 0,
                defaultGreen = 255,
                defaultBlue = 0,
                sequenceIndex = 2
            }
        )
    elseif (state == 2) then
        blam.weaponHudInterface(
            forgeCrosshairAddress,
            {
                defaultRed = 0,
                defaultGreen = 255,
                defaultBlue = 0,
                sequenceIndex = 3
            }
        )
    elseif (state == 3) then
        blam.weaponHudInterface(
            forgeCrosshairAddress,
            {
                defaultRed = 255,
                defaultGreen = 0,
                defaultBlue = 0,
                sequenceIndex = 4
            }
        )
    else
        blam.weaponHudInterface(
            forgeCrosshairAddress,
            {
                defaultRed = 64,
                defaultGreen = 169,
                defaultBlue = 255,
                sequenceIndex = 0
            }
        )
    end
end

-- Check if current player is using a monitor biped
---@return boolean
function features.isPlayerMonitor()
    local tempObject = blam.object(get_dynamic_player())
    if (tempObject and tempObject.tagId == get_tag_id('bipd', constants.bipeds.monitor)) then
        return true
    end
    return false
end

-- Mod functions
function features.swapBiped()
    features.unhighlightAll()
    if (server_type == 'local') then
        -- Needs kinda refactoring, probably splitting this into LuaBlam
        local globalsTagAddress = get_tag('matg', 'globals\\globals')
        local globalsTagData = read_dword(globalsTagAddress + 0x14)
        local globalsTagMultiplayerBipedTagIdAddress = globalsTagData + 0x9BC + 0xC
        local currentGlobalsBipedTagId = read_dword(globalsTagMultiplayerBipedTagIdAddress)
        for i = 0, 1023 do
            local tempObject = blam.object(get_object(i))
            if (tempObject and tempObject.tagId == get_tag_id('bipd', constants.bipeds.spartan)) then
                write_dword(globalsTagMultiplayerBipedTagIdAddress, get_tag_id('bipd', constants.bipeds.monitor))
                delete_object(i)
            elseif (tempObject and tempObject.tagId == get_tag_id('bipd', constants.bipeds.monitor)) then
                write_dword(globalsTagMultiplayerBipedTagIdAddress, get_tag_id('bipd', constants.bipeds.spartan))
                delete_object(i)
            end
        end
    else
        execute_script('rcon forge #b')
    end
end

function features.unhighlightAll()
    for objectId = 0, #get_objects() do
        local tempObject = blam.object(get_object(objectId))
        -- Object exists
        if (tempObject) then
            local tagType = get_tag_type(tempObject.tagId)
            if (tagType == 'scen') then
                blam.object(get_object(objectId), {health = 0})
            end
        end
    end
end

---@param objectId number
---@param transparency number | "0.1" | "0.5" | "1"
function features.highlightObject(objectId, transparency)
    features.unhighlightAll()
    -- Highlight object
    blam.object(get_object(objectId), {health = transparency})
end

return features
