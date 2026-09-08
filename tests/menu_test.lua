local source = debug.getinfo(1, "S").source:gsub("^@", "")
local test_dir = source:match("^(.*)/[^/]+$") or "."
local plugin_dir = test_dir .. "/../bookroom.koplugin"

local shown_message
local warnings = {}
local network_checks = 0
local kosync_settings = {
    custom_server = "https://sync.joinbookroom.com",
    username = "reader",
    userkey = "DO_NOT_DISPLAY_THIS_USERKEY",
}

package.preload["gettext"] = function()
    return function(text) return text end
end

package.preload["logger"] = function()
    return {
        dbg = function() end,
        info = function() end,
        warn = function(...)
            table.insert(warnings, {...})
        end,
    }
end

package.preload["ui/uimanager"] = function()
    return {
        show = function(_, message) shown_message = message end,
    }
end

package.preload["ui/network/manager"] = function()
    return {
        willRerunWhenOnline = function()
            network_checks = network_checks + 1
            return false
        end,
    }
end

package.preload["ui/widget/infomessage"] = function()
    return { new = function(_, options) return options end }
end

package.preload["ui/widget/textviewer"] = function()
    return { new = function(_, options) return options end }
end

package.preload["ui/widget/container/widgetcontainer"] = function()
    return {
        extend = function(_, definition)
            definition.__index = definition
            return definition
        end,
    }
end

package.preload["datastorage"] = function()
    return { getSettingsDir = function() return "/mock/settings" end }
end

package.preload["luasettings"] = function()
    return {
        open = function(_, path)
            assert(path == "/mock/settings/kosync.lua")
            return {
                readSetting = function(_, key)
                    assert(key == "settings")
                    return kosync_settings
                end,
            }
        end,
    }
end

local function assertEqual(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
    end
end

local BookRoom = dofile(plugin_dir .. "/main.lua")
local registered_plugin
local toc_calls = 0
local http_calls = 0
local sent_payload
local sent_username
local sent_userkey
local client_result = { ok = true, status = 200 }
local instance = setmetatable({
    path = plugin_dir,
    ui = {
        getCurrentPage = function() return 23 end,
        toc = {
            toc = {
                { title = "Part I", depth = 1, page = 1, xpointer = "/body/part1", seq_in_level = 1 },
                { title = "CHAPTER III.", depth = 2, page = 20, xpointer = "/body/part1/chapter3", seq_in_level = 3 },
            },
            getTocTitleByPage = function(_, page)
                toc_calls = toc_calls + 1
                assertEqual(page, 23, "menu action passes the current page")
                return "CHAPTER III."
            end,
            fillToc = function() end,
            getTocIndexByPage = function(_, page)
                assertEqual(page, 23, "normalized chapter resolves current TOC entry")
                return 2
            end,
        },
        menu = {
            registerToMainMenu = function(_, plugin) registered_plugin = plugin end,
        },
    },
    document_module = {
        capture = function(_, settings)
            assertEqual(settings, kosync_settings, "KOReader-owned KOSync settings are reused directly")
            return {
                status = "ok",
                document = "f668708f3aa2f8779f57665ded56ed38",
                device = "Kobo Clara",
                deviceId = "device-id",
                progress = "/body/progress",
                percentage = 0.25,
            }
        end,
    },
    client_module = {
        send = function(payload, username, userkey, callback)
            http_calls = http_calls + 1
            sent_payload = payload
            sent_username = username
            sent_userkey = userkey
            callback(client_result)
            return { started = true }
        end,
    },
}, { __index = BookRoom })

instance:init()
assertEqual(registered_plugin, instance, "plugin registers with the active reader menu")

local menu_items = {}
instance:addToMainMenu(menu_items)
local menu_item = menu_items.bookroom
assertEqual(type(menu_item), "table", "Book Room menu item exists")
assertEqual(menu_item.text, "Book Room", "Book Room menu label")
assertEqual(menu_item.sorting_hint, "more_tools", "Book Room menu placement")
assertEqual(type(menu_item.sub_item_table), "table", "Book Room opens a standard submenu")

local chapter_item = menu_item.sub_item_table[1]
local sync_item = menu_item.sub_item_table[2]
local send_item = menu_item.sub_item_table[3]
local diagnostic_item = menu_item.sub_item_table[4]
assertEqual(chapter_item.text_func(), "Current chapter: CHAPTER III.", "submenu shows the live chapter")
assertEqual(sync_item.text, "Book Room sync status", "sync status remains available")
assertEqual(send_item.text, "Send chapter now", "manual action label")
assertEqual(type(send_item.enabled_func), "function", "manual action has an availability check")
assertEqual(send_item.enabled_func(), true, "valid connection and chapter enable manual send")
assertEqual(diagnostic_item.text, "TOC diagnostics (temporary)", "TOC diagnostics remain available")

shown_message = nil
chapter_item.callback()
assertEqual(shown_message.text, "Current chapter: CHAPTER III.", "chapter action shows current chapter")

shown_message = nil
sync_item.callback()
assertEqual(shown_message.text, "Book Room sync\nConnected\nServer: sync.joinbookroom.com", "valid KOSync status is shown")
assertEqual(shown_message.text:find(kosync_settings.userkey, 1, true), nil, "sync status does not display userkey")

shown_message = nil
send_item.callback()
assertEqual(http_calls, 1, "one menu tap creates one HTTP request")
assertEqual(network_checks, 1, "manual action checks KOReader network availability")
assertEqual(sent_username, "reader", "manual action reuses KOSync username")
assertEqual(sent_userkey, kosync_settings.userkey, "manual action passes through wire userkey")
assertEqual(sent_payload.version, 1, "Step 6 payload version is used")
assertEqual(sent_payload.document, "f668708f3aa2f8779f57665ded56ed38", "Phase 1 document digest is sent")
assertEqual(sent_payload.chapter.title, "CHAPTER III.", "normalized title punctuation is preserved")
assertEqual(sent_payload.chapter.tocIndex, 1, "normalized zero-based TOC index is sent")
assertEqual(sent_payload.chapter.depth, 1, "normalized depth is sent")
assertEqual(sent_payload.chapter.parentIndex, 0, "normalized parent is sent")
assertEqual(sent_payload.chapter.sequenceInLevel, 3, "KOReader sequence is sent")
assertEqual(table.concat(sent_payload.chapter.path, " > "), "Part I > CHAPTER III.", "normalized path is sent")
assertEqual(shown_message.text:find("Chapter synced with Book Room.", 1, true) ~= nil, true, "HTTP 200 shows success")
assertEqual(shown_message.text:find(sent_payload.document, 1, true) ~= nil, true, "success exposes digest for Kobo identity check")
assertEqual(shown_message.text:find(kosync_settings.userkey, 1, true), nil, "success never displays userkey")

local before_page_turn = http_calls
assertEqual(instance.onPageUpdate, nil, "plugin installs no automatic page-turn handler")
assertEqual(http_calls, before_page_turn, "page state alone produces no HTTP request")

client_result = { ok = false, reason = "invalid_credentials", status = 401 }
shown_message = nil
send_item.callback()
assertEqual(shown_message.text, "Book Room credentials are no longer valid.\nReconnect KOReader progress sync.", "HTTP 401 has specific guidance")

client_result = { ok = false, reason = "network_failure" }
shown_message = nil
send_item.callback()
assertEqual(shown_message.text, "Could not reach Book Room.\nYour reading was not interrupted.", "network failure is fail-open")

client_result = { ok = false, reason = "server_failure", status = 500 }
shown_message = nil
send_item.callback()
assertEqual(shown_message.text, "Book Room could not accept this chapter update.", "server failure is concise")

local calls_before_guard = http_calls
instance.ui.toc.getTocTitleByPage = function() return nil end
shown_message = nil
send_item.callback()
assertEqual(http_calls, calls_before_guard, "missing chapter performs no HTTP request")
assertEqual(shown_message.text, "Current chapter is unavailable.", "missing chapter is explained")

instance.ui.toc.getTocTitleByPage = function() return "CHAPTER III." end
kosync_settings.custom_server = "https://example.com"
shown_message = nil
send_item.callback()
assertEqual(http_calls, calls_before_guard, "invalid server performs no HTTP request")
assertEqual(shown_message.text, "Book Room sync is not connected.", "invalid server is explained")

kosync_settings.custom_server = "https://sync.joinbookroom.com"
kosync_settings.username = nil
send_item.callback()
assertEqual(http_calls, calls_before_guard, "missing username performs no HTTP request")
kosync_settings.username = "reader"
kosync_settings.userkey = nil
send_item.callback()
assertEqual(http_calls, calls_before_guard, "missing userkey performs no HTTP request")
kosync_settings.userkey = "DO_NOT_DISPLAY_THIS_USERKEY"

shown_message = nil
diagnostic_item.callback()
assertEqual(shown_message.title, "Book Room TOC diagnostics", "diagnostic uses a scrollable viewer")
assertEqual(shown_message.text:find("path: Part I > CHAPTER III.", 1, true) ~= nil, true, "diagnostic shows normalized hierarchy")

instance.ui.toc.getTocTitleByPage = function() error("TOC failed") end
shown_message = nil
local action_ok = pcall(chapter_item.callback)
assertEqual(action_ok, true, "chapter extraction failure does not escape menu action")
assertEqual(shown_message.text, "Current chapter: temporarily unavailable", "failure shows unavailable state")

print("reader menu and manual-send tests passed")
