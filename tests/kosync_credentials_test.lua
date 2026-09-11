local source = debug.getinfo(1, "S").source:gsub("^@", "")
local test_dir = source:match("^(.*)/[^/]+$") or "."
local Credentials = dofile(test_dir .. "/../bookroom.koplugin/kosync_credentials.lua")

local function assertEqual(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
    end
end

local function assertNotContains(value, unexpected, message)
    if value:find(unexpected, 1, true) then
        error(string.format("%s: did not expect %q in %q", message, unexpected, value))
    end
end

local secret = "DO_NOT_DISPLAY_THIS_USERKEY"
local connected = Credentials.evaluate({
    custom_server = "https://sync.joinbookroom.com",
    username = "reader",
    userkey = secret,
})
assertEqual(connected.connected, true, "exact Book Room server and credentials connect")
assertEqual(connected.serverMatchesBookRoom, true, "exact server is recognized")
assertEqual(connected.usernameConfigured, true, "username presence is retained")
assertEqual(connected.userkeyConfigured, true, "userkey presence is retained")
assertEqual(connected.userkey, nil, "userkey is not returned")

local connected_text = Credentials.formatStatus(connected)
assertEqual(connected_text, "Book Room sync\nConnected\nServer: sync.joinbookroom.com", "connected status is minimal")
assertNotContains(connected_text, secret, "connected status never displays userkey")
assertNotContains(connected_text, "reader", "connected status does not display username")

local wrong_server = Credentials.evaluate({
    custom_server = "https://example.com",
    username = "reader",
    userkey = secret,
})
assertEqual(wrong_server.connected, false, "other custom servers are rejected")
assertEqual(
    Credentials.formatStatus(wrong_server),
    "Book Room sync\nNot connected\nSet the custom server to https://sync.joinbookroom.com (no trailing slash).",
    "wrong server status gives safe corrective guidance"
)

local trailing_slash = Credentials.evaluate({
    custom_server = "https://sync.joinbookroom.com/",
    username = "reader",
    userkey = secret,
})
assertEqual(trailing_slash.connected, false, "server comparison is intentionally exact")

local missing_username = Credentials.evaluate({
    custom_server = "https://sync.joinbookroom.com",
    userkey = secret,
})
assertEqual(missing_username.connected, false, "missing username is rejected")

local missing_userkey = Credentials.evaluate({
    custom_server = "https://sync.joinbookroom.com",
    username = "reader",
})
assertEqual(missing_userkey.connected, false, "missing userkey is rejected")

local opened_path
local read_key
local read_default
local read_result = Credentials.read({
    DataStorage = {
        getSettingsDir = function()
            return "/mock/settings"
        end,
    },
    LuaSettings = {
        open = function(_, path)
            opened_path = path
            return {
                readSetting = function(_, key, default)
                    read_key = key
                    read_default = default
                    return {
                        custom_server = "https://sync.joinbookroom.com",
                        username = "reader",
                        userkey = secret,
                    }
                end,
            }
        end,
    },
})
assertEqual(opened_path, "/mock/settings/kosync.lua", "KOReader 2026.07.1 KOSync file is opened")
assertEqual(read_key, "settings", "KOSync nested settings key is read")
assertEqual(type(read_default), "table", "missing settings have a safe default")
assertEqual(read_result.connected, true, "file-backed settings are evaluated")
assertEqual(read_result.userkey, nil, "file-backed result does not retain userkey")

local callback_calls = 0
local connection_status, operation = Credentials.withConnection(function(settings)
    callback_calls = callback_calls + 1
    assertEqual(settings.username, "reader", "connection callback receives existing username")
    assertEqual(settings.userkey, secret, "connection callback receives wire userkey unchanged")
    return { started = true }
end, {
    DataStorage = {
        getSettingsDir = function() return "/mock/settings" end,
    },
    LuaSettings = {
        open = function()
            return {
                readSetting = function()
                    return {
                        custom_server = "https://sync.joinbookroom.com",
                        username = "reader",
                        userkey = secret,
                    }
                end,
            }
        end,
    },
})
assertEqual(callback_calls, 1, "valid Book Room connection invokes consumer once")
assertEqual(connection_status.connected, true, "connection status remains safe")
assertEqual(connection_status.userkey, nil, "connection status never returns userkey")
assertEqual(operation.started, true, "safe consumer result is returned")
assertEqual(operation.userkey, nil, "consumer result contains no credential")

local function assertNoConnection(settings, message)
    local calls = 0
    local status = Credentials.withConnection(function()
        calls = calls + 1
    end, {
        DataStorage = {
            getSettingsDir = function() return "/mock/settings" end,
        },
        LuaSettings = {
            open = function()
                return { readSetting = function() return settings end }
            end,
        },
    })
    assertEqual(status.connected, false, message)
    assertEqual(calls, 0, message .. " does not invoke consumer")
end

assertNoConnection({
    custom_server = "https://example.com",
    username = "reader",
    userkey = secret,
}, "invalid server")
assertNoConnection({
    custom_server = "https://sync.joinbookroom.com",
    userkey = secret,
}, "missing username")
assertNoConnection({
    custom_server = "https://sync.joinbookroom.com",
    username = "reader",
}, "missing userkey")

local failed = Credentials.read({
    DataStorage = {
        getSettingsDir = function()
            return "/mock/settings"
        end,
    },
    LuaSettings = {
        open = function()
            error(secret)
        end,
    },
})
assertEqual(failed.connected, false, "settings read failures fail closed")
assertEqual(failed.reason, "settings_unavailable", "settings error is reduced to a generic reason")
assertNotContains(Credentials.formatStatus(failed), secret, "settings errors cannot leak userkey-like content")
assertEqual(
    Credentials.formatStatus(failed),
    "Book Room sync\nNot connected\nBook Room could not read Progress Sync settings.",
    "unavailable plugin settings are explained"
)

print("KOSync credential tests passed")
