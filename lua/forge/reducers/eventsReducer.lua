-- Lua libraries
local glue = require "glue"
local inspect = require "inspect"
local json = require "json"

-- Forge modules
local core = require "forge.core"
local features = require "forge.features"

-- Optimizations
local getIndexById = core.getIndexById
local rotateObject = core.rotateObject

-- TODO Test this class structure
---@class forgeObject
---@field x number
---@field y number
---@field z number
---@field yaw number
---@field pitch number
---@field roll number
---@field remoteId number
---@field reflectionId number
---@field teamIndex  number
---@field color number

---@class eventsState
---@field forgeObjects forgeObject[]
---@field cachedResponses string[]
local defaultState = {forgeObjects = {}, cachedResponses = {}, playerVotes = {}, mapVotesGroup = 0}

---@param state eventsState
local function eventsReducer(state, action)
    -- Create default state if it does not exist
    if (not state) then
        state = glue.deepcopy(defaultState)
    end
    if (action.type) then
        dprint("-> [Events Store]")
        dprint("Action: " .. action.type, "category")
    end
    if (action.type == const.requests.spawnObject.actionType) then
        local requestObject = action.payload.requestObject

        -- Create a new object rather than passing it as "reference"
        local forgeObject = glue.update({}, requestObject)
        local tagPath = blam.getTag(requestObject.tagId or requestObject.tagIndex).path

        -- Spawn object in the game
        local objectId = core.spawnObject(tagClasses.scenery, tagPath, forgeObject.x, forgeObject.y,
                                          forgeObject.z)
        dprint("objectId: " .. objectId)

        local objectIndex = getIndexById(objectId)
        dprint("objectIndex: " .. objectIndex)

        if (not objectIndex or not objectId) then
            error("Object index/id could not be found for tag: " .. tagPath)
        end

        if (server_type == "sapp") then
            -- SAPP functions can't handle object indexes
            -- TODO This requires some refactor and testing to use ids instead of indexes on the client side
            objectIndex = objectId
            features.hideReflectionObjects()
        elseif (blam.isGameDedicated()) then
            features.hideReflectionObjects()
        end

        -- Set object rotation after creating the object
        rotateObject(objectIndex, forgeObject.yaw, forgeObject.pitch, forgeObject.roll)

        -- We are the server so the remote id is the local objectId/objectIndex
        if (server_type == "local" or server_type == "sapp") then
            forgeObject.remoteId = objectIndex
        end

        -- Apply color to the object
        if (server_type ~= "sapp" and requestObject.color) then
            local tempObject = blam.object(get_object(objectIndex))
            features.setObjectColor(const.colorsNumber[requestObject.color], tempObject)
        end

        dprint("objectIndex: " .. objectIndex)
        dprint("remoteId: " .. forgeObject.remoteId)

        -- Check and take actions if the object is a special netgame object
        if (tagPath:find("spawning")) then
            dprint("-> [Reflecting Spawn]", "warning")
            if (tagPath:find("gametypes")) then
                -- Make needed modifications to game spawn points
                core.updatePlayerSpawn(tagPath, forgeObject)
            elseif (tagPath:find("vehicles") or tagPath:find("objects")) then
                core.updateVehicleSpawn(tagPath, forgeObject)
            elseif (tagPath:find("weapons")) then
                core.updateNetgameEquipmentSpawn(tagPath, forgeObject)
            end
        elseif (tagPath:find("objectives") or tagPath:find("teleporters")) then
            dprint("-> [Reflecting Flag]", "warning")
            core.updateNetgameFlagSpawn(tagPath, forgeObject)
        end

        -- As a server we have to send back a response/request to the players in the server
        if (server_type == "sapp") then
            local response = core.createRequest(forgeObject)
            state.cachedResponses[objectIndex] = response
            if (forgeMapFinishedLoading) then
                core.sendRequest(response)
            end
            features.hideReflectionObjects()
        end

        -- Clean and prepare object to store it
        forgeObject.tagId = nil
        forgeObject.requestType = nil

        -- Store the object in our state
        state.forgeObjects[objectIndex] = forgeObject

        -- Update the current map information
        forgeStore:dispatch({type = "UPDATE_MAP_INFO", payload = {loadingObjectPath = tagPath}})
        forgeStore:dispatch({type = "UPDATE_BUDGET"})

        return state
    elseif (action.type == const.requests.updateObject.actionType) then
        local requestObject = action.payload.requestObject
        local targetObjectId = core.getObjectIndexByRemoteId(state.forgeObjects,
                                                             requestObject.objectId)
        local forgeObject = state.forgeObjects[targetObjectId]

        if (forgeObject) then
            dprint("UPDATING object from store...", "warning")

            forgeObject.x = requestObject.x
            forgeObject.y = requestObject.y
            forgeObject.z = requestObject.z
            forgeObject.yaw = requestObject.yaw
            forgeObject.pitch = requestObject.pitch
            forgeObject.roll = requestObject.roll
            forgeObject.color = requestObject.color
            forgeObject.teamIndex = requestObject.teamIndex

            -- Update object rotation
            core.rotateObject(targetObjectId, forgeObject.yaw, forgeObject.pitch, forgeObject.roll)

            -- Update object position
            local tempObject = blam.object(get_object(targetObjectId))
            tempObject.x = forgeObject.x
            tempObject.y = forgeObject.y
            tempObject.z = forgeObject.z

            if (requestObject.color) then
                features.setObjectColor(const.colorsNumber[requestObject.color], tempObject)
            end

            -- Check and take actions if the object is reflecting a netgame point
            if (forgeObject.reflectionId) then
                local tempObject = blam.object(get_object(targetObjectId))
                local tagPath = blam.getTag(tempObject.tagId).path
                if (tagPath:find("spawning")) then
                    dprint("-> [Reflecting Spawn]", "warning")
                    if (tagPath:find("gametypes")) then
                        -- Make needed modifications to game spawn points
                        core.updatePlayerSpawn(tagPath, forgeObject)
                    elseif (tagPath:find("vehicles") or tagPath:find("objects")) then
                        core.updateVehicleSpawn(tagPath, forgeObject)
                    elseif (tagPath:find("weapons")) then
                        core.updateNetgameEquipmentSpawn(tagPath, forgeObject)
                    end
                elseif (tagPath:find("objectives") or tagPath:find("teleporters")) then
                    dprint("-> [Reflecting Flag]", "warning")
                    core.updateNetgameFlagSpawn(tagPath, forgeObject)
                end
            end

            -- As a server we have to send back a response/request to the players in the server
            if (server_type == "sapp") then
                print(inspect(requestObject))
                local response = core.createRequest(requestObject)
                core.sendRequest(response)

                -- Create cache for incoming players
                local instanceObject = glue.update({}, forgeObject)
                instanceObject.requestType = const.requests.spawnObject.requestType
                instanceObject.tagId = blam.object(get_object(targetObjectId)).tagId
                local response = core.createRequest(instanceObject)
                state.cachedResponses[targetObjectId] = response
            end
        else
            dprint("ERROR!!! The required object with Id: " .. requestObject.objectId ..
                       "does not exist.", "error")
        end
        return state
    elseif (action.type == const.requests.deleteObject.actionType) then
        local requestObject = action.payload.requestObject
        local targetObjectId = core.getObjectIndexByRemoteId(state.forgeObjects,
                                                             requestObject.objectId)
        local forgeObject = state.forgeObjects[targetObjectId]

        if (forgeObject) then
            if (forgeObject.reflectionId) then
                local tempObject = blam.object(get_object(targetObjectId))
                local tagPath = blam.getTag(tempObject.tagId).path
                if (tagPath:find("spawning")) then
                    dprint("-> [Reflecting Spawn]", "warning")
                    if (tagPath:find("gametypes")) then
                        -- Make needed modifications to game spawn points
                        core.updatePlayerSpawn(tagPath, forgeObject, true)
                    elseif (tagPath:find("vehicles") or tagPath:find("objects")) then
                        core.updateVehicleSpawn(tagPath, forgeObject, true)
                    elseif (tagPath:find("weapons")) then
                        core.updateNetgameEquipmentSpawn(tagPath, forgeObject, true)
                    end
                elseif (tagPath:find("teleporters")) then
                    dprint("-> [Reflecting Flag]", "warning")
                    core.updateNetgameFlagSpawn(tagPath, forgeObject, true)
                end
            end

            dprint("Deleting object from store...", "warning")
            delete_object(targetObjectId)
            state.forgeObjects[targetObjectId] = nil
            dprint("Done.", "success")

            -- As a server we have to send back a response/request to the players in the server
            if (server_type == "sapp") then
                local response = core.createRequest(requestObject)
                core.sendRequest(response)

                -- Delete cache of this object for incoming players
                state.cachedResponses[targetObjectId] = nil

            end
        else
            dprint("ERROR!!! The required object with Id: " .. requestObject.objectId ..
                       "does not exist.", "error")
        end
        -- Update the current map information
        forgeStore:dispatch({type = "UPDATE_MAP_INFO"})
        forgeStore:dispatch({type = "UPDATE_BUDGET"})

        return state
    elseif (action.type == const.requests.setMapAuthor.actionType) then
        local requestObject = action.payload.requestObject

        local mapAuthor = requestObject.mapAuthor

        forgeStore:dispatch({
            type = const.requests.setMapAuthor.actionType,
            payload = {mapAuthor = mapAuthor}
        })

        return state
    elseif (action.type == const.requests.setMapDescription.actionType) then
        local requestObject = action.payload.requestObject

        local mapDescription = requestObject.mapDescription

        forgeStore:dispatch({
            type = const.requests.setMapDescription.actionType,
            payload = {mapDescription = mapDescription}
        })

        return state
    elseif (action.type == const.requests.loadMapScreen.actionType) then
        local requestObject = action.payload.requestObject

        local expectedObjects = requestObject.objectCount
        local mapName = requestObject.mapName

        forgeStore:dispatch({
            type = "UPDATE_MAP_INFO",
            payload = {expectedObjects = expectedObjects, mapName = mapName}
        })
        forgeStore:dispatch({type = "UPDATE_BUDGET"})

        -- Function wrapper for timer
        forgeAnimation = features.animateForgeLoading
        forgeAnimationTimer = set_timer(250, "forgeAnimation")

        features.openMenu(const.uiWidgetDefinitions.loadingMenu.path)

        return state
    elseif (action.type == const.requests.flushForge.actionType) then
        if blam.isGameHost() then
            local forgeObjects = state.forgeObjects
            if (#glue.keys(forgeObjects) > 0 and #blam.getObjects() > 0) then
                for objectId, forgeObject in pairs(forgeObjects) do
                    -- dprint(blam.getTag(blam.object(get_object(objectId)).tagId).path)
                    delete_object(objectId)
                end
            end
        end
        state.cachedResponses = {}
        state.forgeObjects = {}
        return state
    elseif (action.type == const.requests.loadVoteMapScreen.actionType) then
        if (server_type ~= "sapp") then
            function preventClose()
                features.openMenu(const.uiWidgetDefinitions.voteMenu.path)
                return false
            end
            set_timer(5000, "preventClose")
        else
            -- Send vote map menu open request
            local loadMapVoteMenuRequest = {
                requestType = const.requests.loadVoteMapScreen.requestType
            }
            core.sendRequest(core.createRequest(loadMapVoteMenuRequest))

            local forgeState = forgeStore:getState()
            if (forgeState and forgeState.mapsMenu.mapsList) then
                -- Remove all the current vote maps
                votingStore:dispatch({type = "FLUSH_MAP_VOTES"})
                -- TODO This needs testing and probably a better implementation
                local mapGroups = glue.chunks(forgeState.mapsMenu.mapsList, 4)
                state.mapVotesGroup = state.mapVotesGroup + 1
                local currentGroup = mapGroups[state.mapVotesGroup]
                if (not currentGroup) then
                    state.mapVotesGroup = 1
                    currentGroup = mapGroups[state.mapVotesGroup]
                end
                for index, mapName in pairs(currentGroup) do
                    local availableGametypes = {}
                    ---@type forgeMap
                    local mapPath = (defaultMapsPath .. "\\%s.fmap"):format(mapName):gsub(" ", "_")
                                        :lower()
                    local mapData = json.decode(read_file(mapPath))
                    for _, forgeObject in pairs(mapData.objects) do
                        local tagPath = forgeObject.tagPath
                        if (tagPath:find("spawning")) then
                            if (tagPath:find("ctf")) then
                                availableGametypes["CTF"] = true
                            elseif (tagPath:find("slayer") or tagPath:find("generic")) then
                                availableGametypes["Slayer"] = true
                                availableGametypes["Team Slayer"] = true
                            elseif (tagPath:find("oddball")) then
                                availableGametypes["Oddball"] = true
                                availableGametypes["Juggernautº"] = true
                            end
                        end
                    end
                    console_out("Map Path: " .. mapPath)
                    local gametypes = glue.keys(availableGametypes)
                    console_out(inspect(gametypes))
                    math.randomseed(os.time())
                    local randomGametype = gametypes[math.random(1, #gametypes)]
                    local finalGametype = randomGametype or "Slayer"
                    console_out("Final Gametype: " .. finalGametype)
                    votingStore:dispatch({
                        type = const.requests.appendVoteMap.actionType,
                        payload = {map = {name = mapName, gametype = finalGametype, mapIndex = 1}}
                    })
                end
            end
            -- Send list of all available vote maps
            local votingState = votingStore:getState()
            for mapIndex, map in pairs(votingState.votingMenu.mapsList) do
                local voteMapOpenRequest = {requestType = const.requests.appendVoteMap.requestType}
                glue.update(voteMapOpenRequest, map)
                core.sendRequest(core.createRequest(voteMapOpenRequest))
            end
        end
        return state
    elseif (action.type == const.requests.appendVoteMap.actionType) then
        if (server_type ~= "sapp") then
            local params = action.payload.requestObject
            votingStore:dispatch({
                type = const.requests.appendVoteMap.actionType,
                payload = {map = {name = params.name, gametype = params.gametype}}
            })
        end
        return state
    elseif (action.type == const.requests.sendTotalMapVotes.actionType) then
        if (server_type == "sapp") then
            local mapVotes = {0, 0, 0, 0}
            for playerIndex, mapIndex in pairs(state.playerVotes) do
                mapVotes[mapIndex] = mapVotes[mapIndex] + 1
            end
            -- Send vote map menu open request
            local sendTotalMapVotesRequest = {
                requestType = const.requests.sendTotalMapVotes.requestType

            }
            for mapIndex, votes in pairs(mapVotes) do
                sendTotalMapVotesRequest["votesMap" .. mapIndex] = votes
            end
            core.sendRequest(core.createRequest(sendTotalMapVotesRequest))
        else
            local params = action.payload.requestObject
            local votesList = {
                params.votesMap1,
                params.votesMap2,
                params.votesMap3,
                params.votesMap4
            }
            votingStore:dispatch({type = "SET_MAP_VOTES_LIST", payload = {votesList = votesList}})
        end
        return state
    elseif (action.type == const.requests.sendMapVote.actionType) then
        if (action.playerIndex and server_type == "sapp") then
            local playerName = get_var(action.playerIndex, "$name")
            if (not state.playerVotes[action.playerIndex]) then
                local params = action.payload.requestObject
                state.playerVotes[action.playerIndex] = params.mapVoted
                local votingState = votingStore:getState()
                local votedMap = votingState.votingMenu.mapsList[params.mapVoted]
                local mapName = votedMap.name
                local mapGametype = votedMap.gametype

                grprint(playerName .. " voted for " .. mapName .. " " .. mapGametype)
                eventsStore:dispatch({type = const.requests.sendTotalMapVotes.actionType})
                local playerVotes = state.playerVotes
                if (#playerVotes > 0) then
                    local mapsList = votingState.votingMenu.mapsList
                    local mapVotes = {0, 0, 0, 0}
                    for playerIndex, mapIndex in pairs(playerVotes) do
                        mapVotes[mapIndex] = mapVotes[mapIndex] + 1
                    end
                    local mostVotedMapIndex = 1
                    local topVotes = 0
                    for mapIndex, votes in pairs(mapVotes) do
                        if (votes > topVotes) then
                            topVotes = votes
                            mostVotedMapIndex = mapIndex
                        end
                    end
                    local mostVotedMap = mapsList[mostVotedMapIndex]
                    local winnerMap = core.toSnakeCase(mostVotedMap.name)
                    local winnerGametype = core.toSnakeCase(mostVotedMap.gametype)
                    cprint("Most voted map is: " .. winnerMap)
                    forgeMapName = winnerMap
                    execute_script("sv_map " .. map .. " " .. winnerGametype)
                end
            end
        end
        return state
    elseif (action.type == const.requests.flushVotes.actionType) then
        state.playerVotes = {}
        return state
    elseif (action.type == const.requests.selectBiped.actionType) then
        if (blam.isGameSAPP()) then
            local bipedTagId = action.payload.requestObject.bipedTagId
            PlayersBiped[action.playerIndex] = bipedTagId
        end
        return state
    else
        if (action.type == "@@lua-redux/INIT") then
            dprint("Default events store state has been created!")
        else
            dprint("Error, dispatched event does not exist.", "error")
        end
        return state
    end
    return state
end

return eventsReducer
