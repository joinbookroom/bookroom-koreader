local Credentials = {}

local BOOKROOM_SERVER = "https://sync.joinbookroom.com"
local BOOKROOM_HOST = "sync.joinbookroom.com"

local function nonBlank(value)
    return type(value) == "string" and value:match("%S") ~= nil
end

local function trim(value)
    if type(value) ~= "string" then
        return nil
    end
    return value:gsub("^%s+", ""):gsub("%s+$", "")
end

-- Reduce KOSync settings immediately to non-secret state. In particular, the
-- userkey is never copied into the returned status object.
function Credentials.evaluate(settings)
    settings = type(settings) == "table" and settings or {}

    local configured_server = trim(settings.custom_server)
    local server_matches = configured_server == BOOKROOM_SERVER
    local username_configured = nonBlank(settings.username)
    local userkey_configured = nonBlank(settings.userkey)

    return {
        status = "ok",
        connected = server_matches and username_configured and userkey_configured,
        serverConfigured = nonBlank(configured_server),
        serverMatchesBookRoom = server_matches,
        usernameConfigured = username_configured,
        userkeyConfigured = userkey_configured,
    }
end

local function unavailable(reason)
    return {
        status = "unavailable",
        connected = false,
        reason = reason,
        serverConfigured = false,
        serverMatchesBookRoom = false,
        usernameConfigured = false,
        userkeyConfigured = false,
    }
end

local function readSettings(dependencies)
    local DataStorage
    local LuaSettings

    if dependencies then
        DataStorage = dependencies.DataStorage
        LuaSettings = dependencies.LuaSettings
    else
        local storage_ok, storage_or_error = pcall(require, "datastorage")
        local settings_ok, settings_or_error = pcall(require, "luasettings")
        if not storage_ok or not settings_ok then
            return nil, "settings_api_unavailable"
        end
        DataStorage = storage_or_error
        LuaSettings = settings_or_error
    end

    if type(DataStorage) ~= "table" or type(DataStorage.getSettingsDir) ~= "function"
        or type(LuaSettings) ~= "table" or type(LuaSettings.open) ~= "function" then
        return nil, "settings_api_unavailable"
    end

    local directory_ok, settings_directory = pcall(DataStorage.getSettingsDir, DataStorage)
    if not directory_ok or type(settings_directory) ~= "string" then
        return nil, "settings_unavailable"
    end

    local open_ok, settings_object = pcall(
        LuaSettings.open,
        LuaSettings,
        settings_directory .. "/kosync.lua"
    )
    if not open_ok or type(settings_object) ~= "table"
        or type(settings_object.readSetting) ~= "function" then
        return nil, "settings_unavailable"
    end

    local read_ok, settings = pcall(
        settings_object.readSetting,
        settings_object,
        "settings",
        {}
    )
    if not read_ok or type(settings) ~= "table" then
        return nil, "settings_unavailable"
    end

    return settings
end

-- KOReader 2026.07.1 stores KOSync configuration in
-- <settings directory>/kosync.lua under the "settings" key. Opening and
-- reading LuaSettings is side-effect free unless flush() is explicitly called;
-- this module never calls flush or any network API.
function Credentials.read(dependencies)
    local settings, reason = readSettings(dependencies)
    if not settings then return unavailable(reason) end
    return Credentials.evaluate(settings)
end

-- The KOReader-owned settings table, including the wire userkey, exists only
-- inside this callback. Neither the userkey nor username is copied into the
-- returned status/result structures.
function Credentials.withConnection(callback, dependencies)
    local settings, reason = readSettings(dependencies)
    if not settings then return unavailable(reason) end

    local status = Credentials.evaluate(settings)
    if not status.connected then return status end
    if type(callback) ~= "function" then return unavailable("consumer_unavailable") end

    local callback_ok, operation = pcall(callback, settings)
    if not callback_ok then return unavailable("consumer_error") end
    return status, operation
end

function Credentials.formatStatus(result)
    if type(result) == "table" and result.connected then
        return table.concat({
            "Book Room sync",
            "Connected",
            "Server: " .. BOOKROOM_HOST,
        }, "\n")
    end

    return table.concat({
        "Book Room sync",
        "Not connected",
    }, "\n")
end

return Credentials
