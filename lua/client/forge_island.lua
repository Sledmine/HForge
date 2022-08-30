------------------------------------------------------------------------------
-- Forge Island Client Script
-- Sledmine
-- Client side script for Forge Island
------------------------------------------------------------------------------
-- Constants
clua_version = 2.042

-- Script name must be the base script name, without variants or extensions
scriptName = script_name:gsub(".lua", ""):gsub("_dev", ""):gsub("_beta", "")
defaultConfigurationPath = "config"
defaultMapsPath = "fmaps"

-- Lua libraries
local inspect = require "inspect"
local redux = require "lua-redux"
local glue = require "glue"
local ini = require "lua-ini"

-- Halo Custom Edition libraries
blam = require "blam"
-- Bind legacy Chimera printing to lua-blam printing
console_out = blam.consoleOutput
-- Create global reference to tagClasses
objectClasses = blam.objectClasses
tagClasses = blam.tagClasses
cameraTypes = blam.cameraTypes

-- Forge modules
local interface = require "forge.interface"
local features = require "forge.features"
local commands = require "forge.commands"
local core = require "forge.core"
actions = require "forge.redux.actions"

-- Reducers importation
local playerReducer = require "forge.reducers.playerReducer"
local eventsReducer = require "forge.reducers.eventsReducer"
local forgeReducer = require "forge.reducers.forgeReducer"
local votingReducer = require "forge.reducers.votingReducer"
local generalMenuReducer = require "forge.reducers.generalMenuReducer"

-- Reflectors importation
local forgeReflector = require "forge.reflectors.forgeReflector"
local votingReflector = require "forge.reflectors.votingReflector"
local generalMenuReflector = require "forge.reflectors.generalMenuReflector"

-- Forge default configuration
config = {}

config.forge = {
    debugMode = false,
    autoSave = false,
    autoSaveTime = 15000,
    snapMode = false,
    objectsCastShadow = false
}

-- Load forge configuration at script load time
core.loadForgeConfiguration()

-- Internal functions and variables
-- Buffer to store all the debug printing
debugBuffer = ""
drawTextCalls = {}
-- Tick counter until next text draw refresh
textRefreshCount = 0

lastProjectileId = nil
local lastHighlightedObjectIndex
local lastPlayerBiped
local lastInBoundsCoordinates
loadingFrame = 0

--- Function to send debug messages to console output
---@param message string
---@param color string
function dprint(message, color)
    if (config.forge.debugMode) then
        local message = message
        if (type(message) ~= "string") then
            message = inspect(message)
        end
        debugBuffer = (debugBuffer or "") .. message .. "\n"
        if (color == "category") then
            console_out(message, 0.31, 0.631, 0.976)
        elseif (color == "warning") then
            console_out(message, blam.consoleColors.warning)
        elseif (color == "error") then
            console_out(message, blam.consoleColors.error)
        elseif (color == "success") then
            console_out(message, blam.consoleColors.success)
        else
            console_out(message)
        end
    end
end

--- Function to automatically save a current Forge map
function autoSaveForgeMap()
    local isPlayerOnMenu = read_byte(blam.addressList.gameOnMenus) == 0
    if (config.forge.autoSave and core.isPlayerMonitor() and not isPlayerOnMenu) then
        ---@type forgeState
        local forgeState = forgeStore:getState()
        local currentMapName = forgeState.currentMap.name
        if (currentMapName and currentMapName ~= "Unsaved") then
            core.saveForgeMap()
        end
    end
end

function OnMapLoad()
    -- Dinamically load constants for the current Forge map
    const = require "forge.constants"

    -- Like Redux we have some kind of store baby!! the rest is pure magic..
    playerStore = redux.createStore(playerReducer)
    -- Isolated store for all the Forge core data
    forgeStore = redux.createStore(forgeReducer)
    -- Store to process Forge events across client and server
    eventsStore = redux.createStore(eventsReducer)
    -- Storage for all the state of map voting
    votingStore = redux.createStore(votingReducer)
    -- Storage for the general menu state
    generalMenuStore = redux.createStore(generalMenuReducer)
    generalMenuStore:subscribe(generalMenuReflector)

    local forgeState = forgeStore:getState()

    -- TODO Migrate this into a feature or something
    local sceneriesTagCollection = blam.tagCollection(const.tagCollections.forgeObjectsTagId)
    local forgeObjectsList = core.getForgeSceneries(sceneriesTagCollection)
    -- Iterate over all the sceneries available in the sceneries tag collection
    for _, tagId in pairs(forgeObjectsList) do
        local tag = blam.getTag(tagId)
        if (tag and tag.path) then
            local sceneryPath = tag.path
            local sceneriesSplit = glue.string.split(sceneryPath, "\\")
            local sceneryFolderIndex
            for folderNameIndex, folderName in pairs(sceneriesSplit) do
                if (folderName == "scenery") then
                    sceneryFolderIndex = folderNameIndex + 1
                    break
                end
            end
            local fixedSplittedPath = {}
            for l = sceneryFolderIndex, #sceneriesSplit do
                fixedSplittedPath[#fixedSplittedPath + 1] = sceneriesSplit[l]
            end
            sceneriesSplit = fixedSplittedPath
            local sceneriesSplitLast = sceneriesSplit[#sceneriesSplit]

            forgeState.forgeMenu.objectsDatabase[sceneriesSplitLast] = sceneryPath
            -- Set first level as the root of available current objects
            -- Make a tree iteration to append sceneries
            local treePosition = forgeState.forgeMenu.objectsList.root
            for currentLevel, categoryLevel in pairs(sceneriesSplit) do
                -- TODO This is horrible, remove this "sort" implementation
                if (categoryLevel:sub(1, 1) == "_") then
                    -- categoryLevel = glue.string.fromhex(tostring((0x2))) .. categoryLevel:sub(2, -1)
                    categoryLevel = categoryLevel:sub(2, -1)
                end
                if (not treePosition[categoryLevel]) then
                    treePosition[categoryLevel] = {}
                end
                treePosition = treePosition[categoryLevel]
            end
        end
    end

    -- Set current menu elements to objects list
    forgeState.forgeMenu.elementsList = glue.deepcopy(forgeState.forgeMenu.objectsList)

    -- Subscribed function to refresh forge state into the game!
    forgeStore:subscribe(forgeReflector)

    -- Dispatch forge objects list update
    forgeStore:dispatch({
        type = "UPDATE_FORGE_ELEMENTS_LIST",
        payload = {forgeMenu = forgeState.forgeMenu}
    })

    votingStore:subscribe(votingReflector)
    -- Dispatch forge objects list update
    votingStore:dispatch({type = "FLUSH_MAP_VOTES"})

    local isForgeMap = core.isForgeMap(map)
    if (isForgeMap) then
        core.loadForgeConfiguration()
        core.loadForgeMaps()

        -- Start autosave timer
        if (not autoSaveTimer and server_type == "local") then
            local autoSaveTime = config.forge.autoSaveTime
            autoSaveTimer = set_timer(autoSaveTime, "autoSaveForgeMap")
        end

        set_callback("tick", "OnTick")
        set_callback("preframe", "OnPreFrame")
        set_callback("rcon message", "OnRcon")
        set_callback("command", "OnCommand")

    else
        error("This is not a compatible Forge CE map.")
    end
end

function OnPreFrame()
    local isGameOnMenu = read_byte(blam.addressList.gameOnMenus) == 0
    if (drawTextBuffer and not isGameOnMenu) then
        draw_text(table.unpack(drawTextBuffer))
    end
    for drawTextIndex, drawTextCall in pairs(drawTextCalls) do
        if not drawTextCall.drawOnMenus and not isGameOnMenu then
            draw_text(table.unpack(drawTextCall.buffer))
        end
    end
    -- Menu, UI Handling
    if (isGameOnMenu) then
        ---@type playerState
        local playerState = playerStore:getState()

        -- Get mouse input to interact with menus
        local mouse = features.getMouseInput()
        local currentWidgetId = features.getCurrentWidget()
        -- Maps Menu
        if (currentWidgetId == const.uiWidgetDefinitions.mapsMenu.id) then
            local pressedButton = interface.triggers("maps_menu", 11)
            if (mouse.scroll > 0) then
                pressedButton = 10
            elseif (mouse.scroll < 0) then
                pressedButton = 9
            end
            if (pressedButton) then
                dprint(" -> [ Maps Menu ]")
                if (pressedButton == 9) then
                    -- Dispatch an event to increment current page
                    forgeStore:dispatch({type = "DECREMENT_MAPS_MENU_PAGE"})
                elseif (pressedButton == 10) then
                    -- Dispatch an event to decrement current page
                    forgeStore:dispatch({type = "INCREMENT_MAPS_MENU_PAGE"})
                else
                    local elementsList = blam.unicodeStringList(const.unicodeStrings.mapsListTagId)
                    local mapName = elementsList.stringList[pressedButton]:gsub(" ", "_")
                    core.loadForgeMap(mapName)
                end
                dprint("Button " .. pressedButton .. " was pressed!", "category")
            end
        elseif (currentWidgetId == const.uiWidgetDefinitions.actionsMenu.id) then
            -- FIXME This needs its own trigger
            local pressedButton = interface.triggers("maps_menu", 11)
            if (pressedButton == 11) then
                core.saveForgeMap()
            end
            -- Forge Objects Menu
        elseif (currentWidgetId == const.uiWidgetDefinitions.forgeMenu.id) then
            local pressedButton = interface.triggers("forge_menu", 9)
            if (mouse.scroll > 0) then
                pressedButton = 8
            elseif (mouse.scroll < 0) then
                pressedButton = 7
            end
            if (pressedButton) then
                dprint(" -> [ Forge Menu ]")
                local forgeState = forgeStore:getState()
                if (pressedButton == 9) then
                    if (forgeState.forgeMenu.desiredElement ~= "root") then
                        forgeStore:dispatch({type = "UPWARD_NAV_FORGE_MENU"})
                    else
                        dprint("Closing Forge menu...")
                        interface.close(const.uiWidgetDefinitions.forgeMenu)
                    end
                elseif (pressedButton == 8) then
                    forgeStore:dispatch({type = "INCREMENT_FORGE_MENU_PAGE"})
                elseif (pressedButton == 7) then
                    forgeStore:dispatch({type = "DECREMENT_FORGE_MENU_PAGE"})
                else
                    if (playerState.attachedObjectId) then
                        local elementsList = blam.unicodeStringList(const.unicodeStrings
                                                                        .forgeMenuElementsTagId)
                        local selectedElement = elementsList.stringList[pressedButton]
                        if (selectedElement) then
                            local elementsFunctions = features.getObjectMenuFunctions()
                            local buttonFunction = elementsFunctions[selectedElement]
                            if (buttonFunction) then
                                buttonFunction()
                            else
                                forgeStore:dispatch({
                                    type = "DOWNWARD_NAV_FORGE_MENU",
                                    payload = {desiredElement = selectedElement}
                                })
                            end
                        end
                    else
                        local elementsList = blam.unicodeStringList(const.unicodeStrings
                                                                        .forgeMenuElementsTagId)
                        local selectedSceneryName = elementsList.stringList[pressedButton]
                        local sceneryPath =
                            forgeState.forgeMenu.objectsDatabase[selectedSceneryName]
                        if (sceneryPath) then
                            playerStore:dispatch({
                                type = "CREATE_AND_ATTACH_OBJECT",
                                payload = {path = sceneryPath}
                            })
                            interface.close(const.uiWidgetDefinitions.forgeMenu)
                        else
                            forgeStore:dispatch({
                                type = "DOWNWARD_NAV_FORGE_MENU",
                                payload = {desiredElement = selectedSceneryName}
                            })
                        end
                    end
                end
                dprint(" -> [ Forge Menu ]")
                dprint("Button " .. pressedButton .. " was pressed!", "category")

            end
        elseif (currentWidgetId == const.uiWidgetDefinitions.voteMenu.id) then
            local pressedButton = interface.triggers("map_vote_menu", 5)
            if (pressedButton) then
                local voteMapRequest = {
                    requestType = const.requests.sendMapVote.requestType,
                    mapVoted = pressedButton
                }
                core.sendRequest(core.createRequest(voteMapRequest))
                dprint("Vote Map menu:")
                dprint("Button " .. pressedButton .. " was pressed!", "category")
            end
            -- Settings Menu
        elseif (currentWidgetId == const.uiWidgetDefinitions.generalMenu.id) then
            ---@type generalMenuState
            local state = generalMenuStore:getState()
            -- FIXME Rename these triggers on hsc
            if (mouse.scroll > 0) then
                generalMenuStore:dispatch({type = "FORWARD_PAGE"})
            elseif (mouse.scroll < 0) then
                generalMenuStore:dispatch({type = "BACKWARD_PAGE"})
            end
            local pressedButton = interface.triggers("settings_menu", 8)
            if (state.menu.format == "settings") then
                if (pressedButton) then
                    dprint("Settings menu:")
                    dprint("Button " .. pressedButton .. " was pressed!", "category")

                    local configOptions = {"fcast", "fsave", "fdebug", "fsnap"}
                    commands(configOptions[pressedButton])
                    features.createSettingsMenu()
                end
            elseif (state.menu.format == "bipeds") then
                if (pressedButton) then
                    dprint("Bipeds menu:")
                    dprint("Button " .. pressedButton .. " was pressed!", "category")
                    local currentBipeds = actions.getGeneralElements()
                    local bipedTagId = const.bipedNames[currentBipeds[pressedButton]]
                    -- FIXME Finish this
                    if (blam.isGameDedicated()) then
                        core.sendRequest(core.createRequest({
                            requestType = const.requests.selectBiped.requestType,
                            bipedTagId = bipedTagId
                        }))
                    elseif (blam.isGameHost()) then
                        features.swapBiped(bipedTagId)
                    end
                    features.createBipedsMenu()
                end
            end
        elseif (currentWidgetId == const.uiWidgetDefinitions.warningDialog.id) then
            -- features.animateDialogLoading()
        end
    else
        ---@type playerState
        local playerState = playerStore:getState()
        -- Get mouse input to interact with menus
        local mouse = features.getMouseInput()
        if (core.isPlayerMonitor() and playerState.attachedObjectId) then
            if (mouse.scroll > 0) then
                playerStore:dispatch({
                    type = "STEP_ROTATION_DEGREE",
                    payload = {substraction = true, multiplier = mouse.scroll}
                })
                playerStore:dispatch({type = "ROTATE_OBJECT"})
                features.printHUD(playerState.currentAngle:upper() .. ": " ..
                                      playerState[playerState.currentAngle])
            elseif (mouse.scroll < 0) then
                playerStore:dispatch({
                    type = "STEP_ROTATION_DEGREE",
                    payload = {substraction = false, multiplier = mouse.scroll}
                })
                playerStore:dispatch({type = "ROTATE_OBJECT"})
                features.printHUD(playerState.currentAngle:upper() .. ": " ..
                                      playerState[playerState.currentAngle])
            end
        end
    end
end

function OnTick()
    local player = blam.biped(get_dynamic_player())
    if (player) then
        ---@type playerState
        local playerState = playerStore:getState()
        -- Prevent players from getting outside map limits
        features.mapLimit()
        if (lastPlayerBiped ~= player.tagId) then
            lastPlayerBiped = player.tagId
            dprint("Biped has changed!")
            dprint(blam.getTag(player.tagId).path)
            -- Hide spawning related Forge objects
            features.hideReflectionObjects()
            features.showForgeKeys()
            features.swapFirstPerson()
        end
        -- Reposition player if needed
        local oldPosition = playerState.position
        if (oldPosition) then
            player.x = oldPosition.x
            player.y = oldPosition.y
            player.z = oldPosition.z + 0.1
            playerStore:dispatch({type = "RESET_POSITION"})
        end
        -- Reset latest hilighted object
        if (lastHighlightedObjectIndex) then
            features.unhighlightObject(lastHighlightedObjectIndex)
            lastHighlightedObjectIndex = nil
        end
        if (core.isPlayerMonitor()) then
            -- Check if monitor has an object attached
            local playerAttachedObjectId = playerState.attachedObjectId
            if (playerAttachedObjectId) then
                features.printHUDRight("Flashlight Key - Object properties",
                                       "Crouch Key - Undo object changes")
                -- Unhighlight objects
                features.unhighlightAll()
                -- Calculate player point of view
                playerStore:dispatch({type = "UPDATE_OFFSETS"})
                -- Change rotation angle
                if (player.flashlightKey) then
                    features.openForgeObjectPropertiesMenu()
                elseif (player.actionKey) then
                    playerStore:dispatch({type = "CHANGE_ROTATION_ANGLE"})
                    features.printHUD("Rotating in " .. playerState.currentAngle)
                elseif (player.weaponPTH and player.jumpHold) then
                    features.printHUD("Restoring current object...")
                    local forgeObjects = eventsStore:getState().forgeObjects
                    local forgeObject = forgeObjects[playerAttachedObjectId]
                    if (forgeObject) then
                        -- Update object position
                        local object = blam.object(get_object(playerAttachedObjectId))
                        object.x = forgeObject.x
                        object.y = forgeObject.y
                        object.z = forgeObject.z
                        core.rotateObject(playerAttachedObjectId, forgeObject.yaw,
                                          forgeObject.pitch, forgeObject.roll)
                        playerStore:dispatch({type = "DETACH_OBJECT", payload = {undo = true}})
                        return true
                    end
                elseif (player.meleeKey) then
                    playerStore:dispatch({
                        type = "SET_LOCK_DISTANCE",
                        payload = {lockDistance = not playerState.lockDistance}
                    })
                    local distance = glue.round(playerState.distance)
                    features.printHUD("Distance from object is " .. distance .. " units")
                    if (playerState.lockDistance) then
                        features.printHUD("Push n pull")
                    else
                        features.printHUD("Closer or further")
                    end
                elseif (player.jumpHold) then
                    playerStore:dispatch({type = "DESTROY_OBJECT"})
                elseif (player.weaponSTH) then
                    local object = blam.object(get_object(playerAttachedObjectId))
                    if (not core.isObjectOutOfBounds({
                        playerState.xOffset,
                        playerState.yOffset,
                        playerState.zOffset
                    })) then
                        playerStore:dispatch({type = "DETACH_OBJECT"})
                    end
                end

                if (not playerState.lockDistance) then
                    playerStore:dispatch({type = "UPDATE_DISTANCE"})
                    playerStore:dispatch({type = "UPDATE_OFFSETS"})
                end

                local object = blam.object(get_object(playerAttachedObjectId))

                -- Update crosshair
                local isObjectOutOfBounds = core.isObjectOutOfBounds({
                    playerState.xOffset,
                    playerState.yOffset,
                    playerState.zOffset
                })
                if (isObjectOutOfBounds) then
                    features.setCrosshairState(4)
                else
                    features.setCrosshairState(3)
                    lastInBoundsCoordinates = {
                        playerState.xOffset,
                        playerState.yOffset,
                        playerState.zOffset
                    }
                end

                -- Update object position
                if (object) then
                    if (isObjectOutOfBounds) then
                        if (lastInBoundsCoordinates) then
                            -- dprint("Preventing out of bounds...")
                            object.x = lastInBoundsCoordinates[1]
                            object.y = lastInBoundsCoordinates[2]
                            object.z = lastInBoundsCoordinates[3]
                        end
                    else
                        -- dprint("Normal positioning...")
                        object.x = playerState.xOffset
                        object.y = playerState.yOffset
                        object.z = playerState.zOffset
                    end
                end

            else
                features.printHUDRight("Flashlight Key - Objects menu", "Crouch Key - Spartan mode")
                -- Set crosshair to not selected state
                features.setCrosshairState(1)

                local objectIndex, forgeObject, projectile = core.getForgeObjectFromPlayerAim()
                -- Player is taking the object
                if (objectIndex) then
                    if (objectIndex ~= lastHighlightedObjectIndex) then
                        lastHighlightedObjectIndex = objectIndex
                    end
                    -- Hightlight object that the player is looking at
                    features.highlightObject(objectIndex, 1)
                    features.setCrosshairState(2)

                    -- Get and parse object path
                    local tagId = blam.object(get_object(objectIndex)).tagId
                    local tagPath = blam.getTag(tagId).path
                    local splitPath = glue.string.split(tagPath, "\\")
                    local objectPath = table.concat(glue.shift(splitPath, 1, -3), "\\")
                    local objectCategory = splitPath[#splitPath - 2]

                    -- Get Forge object info
                    local eventsState = actions.getEventsState()
                    local forgeObject = eventsState.forgeObjects[objectIndex]
                    if (forgeObject) then
                        features.printHUD("NAME:  " .. objectPath,
                                          "DATA INDEX:  " .. forgeObject.teamIndex, 25)
                    else
                        features.printHUD("NAME:  " .. objectPath, nil, 25)
                    end

                    if (player.weaponPTH and not player.jumpHold) then
                        playerStore:dispatch({
                            type = "ATTACH_OBJECT",
                            payload = {
                                objectId = objectIndex,
                                attach = {
                                    x = 0, -- projectile.x,
                                    y = 0, -- projectile.y,
                                    z = 0 -- projectile.z
                                },
                                fromPerspective = true
                            }
                        })
                        local object = blam.object(get_object(objectIndex))
                        dprint(object.x .. " " .. object.y .. " " .. object.z)
                    elseif (player.actionKey) then
                        local tagId = blam.object(get_object(objectIndex)).tagId
                        local tagPath = blam.getTag(tagId).path
                        -- TODO Add color copy from object
                        playerStore:dispatch({
                            type = "CREATE_AND_ATTACH_OBJECT",
                            payload = {path = tagPath}
                        })
                        playerStore:dispatch({
                            type = "SET_ROTATION_DEGREES",
                            payload = {
                                yaw = forgeObject.yaw,
                                pitch = forgeObject.pitch,
                                roll = forgeObject.roll
                            }
                        })
                        playerStore:dispatch({type = "ROTATE_OBJECT"})
                    end
                end
                -- Open Forge menu by pressing "Q"
                if (player.flashlightKey) then
                    dprint("Opening Forge menu...")
                    local forgeState = forgeStore:getState()
                    forgeState.forgeMenu.elementsList =
                        glue.deepcopy(forgeState.forgeMenu.objectsList)
                    forgeStore:dispatch({
                        type = "UPDATE_FORGE_ELEMENTS_LIST",
                        payload = {forgeMenu = forgeState.forgeMenu}
                    })
                    features.openMenu(const.uiWidgetDefinitions.forgeMenu.path)
                elseif (player.crouchHold and server_type == "local") then
                    playerStore:dispatch({type = "DETACH_OBJECT"})
                    features.swapBiped()
                end
            end
        else
            features.regenerateHealth()
            features.setCrosshairState(0)
            -- Convert into monitor
            if (player.flashlightKey and not player.crouchHold) then
                features.swapBiped()
            elseif (config.forge.debugMode and player.actionKey and player.crouchHold and
                server_type == "local") then
                -- TODO Refactor this into a different module for debug tools
                local bipedTag = blam.getTag(player.tagId)
                testBipedId = core.spawnObject(bipedTag.class, bipedTag.path, player.x, player.y,
                                               player.z)
            end
        end
    end

    -- Attach respective hooks for menus
    interface.hook("maps_menu_hook", interface.stop, const.uiWidgetDefinitions.mapsList)
    interface.hook("forge_menu_hook", interface.stop, const.uiWidgetDefinitions.objectsList)
    interface.hook("forge_menu_close_hook", interface.stop, const.uiWidgetDefinitions.forgeMenu)
    interface.hook("loading_menu_close_hook", interface.stop, const.uiWidgetDefinitions.loadingMenu)
    interface.hook("settings_menu_hook", features.createSettingsMenu, true)
    interface.hook("bipeds_menu_hook", features.createBipedsMenu, true)
    interface.hook("general_menu_forced_event_hook", interface.stop,
                   const.uiWidgetDefinitions.generalMenuList)

    -- Update text refresh tick count
    textRefreshCount = textRefreshCount + 1

    -- We need to draw new text, erase older text
    if (textRefreshCount > 30) then
        textRefreshCount = 0
        drawTextBuffer = nil
    end
    for drawTextMessage, drawTextCall in pairs(drawTextCalls) do
        if drawTextCall.ticks > 0 then
            drawTextCall.ticks = drawTextCall.ticks - 1
        else
            drawTextCalls[drawTextMessage] = nil
        end
    end

    -- Safe passive features
    features.hudUpgrades()
    features.meleeMagnetism()
end

function OnRcon(message)
    local request = string.gsub(message, "'", "")
    local splitData = glue.string.split(request, const.requestSeparator)
    local incomingRequest = splitData[1]
    local actionType
    local currentRequest
    for requestName, request in pairs(const.requests) do
        if (incomingRequest and incomingRequest == request.requestType) then
            currentRequest = request
            actionType = request.actionType
        end
    end
    if (actionType) then
        return core.processRequest(actionType, request, currentRequest)
    end
    return true
end

function OnCommand(command)
    return commands(command)
end

function OnMapUnload()
    -- Flush all the forge objects
    core.flushForge()

    -- Save configuration
    core.saveConfiguration()
end

if (server_type == "local") then
    OnMapLoad()
end
-- Prepare event callbacks
set_callback("map load", "OnMapLoad")
set_callback("unload", "OnMapUnload")
