ThingsLoaderController = Controller:new()

local filename = nil
local loaded = false

function setFileName(name)
    filename = name
end

function isLoaded()
    return loaded
end

-- The three feature flags that change how a .dat is laid out. Which ones are on must
-- match how the file was written, otherwise loading fails with "corrupt data ...".
local datFlags = { GameSpritesU32, GameEnhancedAnimations, GameIdleAnimations }
local datFlagNames = { 'GameSpritesU32', 'GameEnhancedAnimations', 'GameIdleAnimations' }

local function setDatFlags(state)
    for i, flag in ipairs(datFlags) do
        if state[i] then
            g_game.enableFeature(flag)
        else
            g_game.disableFeature(flag)
        end
    end
end

local function describeDatFlags(state)
    local parts = {}
    for i, name in ipairs(datFlagNames) do
        parts[#parts + 1] = name .. '=' .. (state[i] and 'on' or 'off')
    end
    return table.concat(parts, ', ')
end

local function tryLoadDatWithFallbacks(datPath)
    local original = {}
    for i, flag in ipairs(datFlags) do
        original[i] = g_game.getFeature(flag)
    end

    -- 1) Exactly as configured for this client version. Errors stay visible here: they
    --    say whether the file is missing or has a different layout.
    if g_things.loadDat(datPath) then
        return true
    end

    -- 2) Every other layout, switching flags OFF as well as on. (The previous code could
    --    only switch flags on, so it could never find a layout with fewer flags set.)
    g_logger.warning('[game_things] ' .. datPath .. '.dat did not load with ' .. describeDatFlags(original) ..
        '; trying the other layouts')
    g_logger.setLevel(5) -- hide the expected failures of wrong guesses
    local layouts = {
        { false, false, false },
        { true,  false, false },
        { true,  true,  false },
        { true,  true,  true  },
        { false, true,  true  },
        { true,  false, true  },
        { false, true,  false },
        { false, false, true  },
    }
    for _, layout in ipairs(layouts) do
        local same = true
        for i = 1, #datFlags do
            if layout[i] ~= original[i] then
                same = false
            end
        end

        if not same then
            setDatFlags(layout)
            if g_things.loadDat(datPath) then
                g_logger.setLevel(1)
                g_logger.info('[game_things] ' .. datPath .. '.dat loaded with ' .. describeDatFlags(layout))
                return true
            end
        end
    end

    g_logger.setLevel(1)
    setDatFlags(original)
    g_logger.warning('[game_things] could not read ' .. datPath .. '.dat with any combination of ' ..
        table.concat(datFlagNames, ', '))
    return false
end

local function load(version)
    local errorList = {}

    -- If version is 0 (not set), default to 860 where the files actually are
    if version == 0 then
        version = 860
    end

    if version >= 1281 and not g_game.getFeature(GameLoadSprInsteadProtobuf) then
        local filePath = resolvepath(string.format('/things/%d/', version))
        if not g_things.loadAppearances(filePath) then
            errorList[#errorList + 1] = "Couldn't load assets"
        end
        if not g_things.loadStaticData(filePath) then
            errorList[#errorList + 1] = "Couldn't load staticdata"
        end
    else
        local datPath, sprPath
        if filename then
            datPath = resolvepath('/data/things/' .. filename)
            sprPath = resolvepath('/data/things/' .. filename)
        else
            datPath = resolvepath('/data/things/' .. version .. '/Tibia')
            sprPath = resolvepath('/data/things/' .. version .. '/Tibia')
        end

        if not tryLoadDatWithFallbacks(datPath) then
            errorList[#errorList + 1] = tr('Unable to load dat file, please place a valid dat in \'%s.dat\'', datPath)
        end
        g_logger.setLevel(1)

        if not g_sprites.loadSpr(sprPath) then
            errorList[#errorList + 1] = tr('Unable to load spr file, please place a valid spr in \'%s.spr\'', sprPath)
        end
        if g_game.getFeature(GameLoadSprInsteadProtobuf) and version >= 1281 then
            local staticPath = resolvepath(string.format('/things/%d/appearances', version))
            if not g_things.loadAppearances(staticPath) then
                g_logger.warning(string.format(
                    "[game_things.load()] Couldn't load /things/%d/appearances.dat, possible packets error.", version))
            end
        end
    end

    loaded = #errorList == 0
    if loaded then
        g_sounds.loadClientFiles(resolvepath(string.format('/sounds/%d/', version)))
        return
    end

    local messageBox = displayErrorBox(tr('Error'), table.concat(errorList, "\n"))
    addEvent(function()
        messageBox:raise()
        messageBox:focus()
    end)

    g_game.setClientVersion(0)
    g_game.setProtocolVersion(0)
end

function ThingsLoaderController:onInit()
    self:registerEvents(g_game, {
        onClientVersionChange = load
    })
    -- If version was already set before we registered (e.g. in init.lua),
    -- the event already fired and we missed it. Load now.
    local v = g_game.getClientVersion()
    if v ~= 0 then
        load(v)
    end
end
