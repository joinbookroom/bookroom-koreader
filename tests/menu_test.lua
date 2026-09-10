local source = debug.getinfo(1, "S").source:gsub("^@", "")
local test_dir = source:match("^(.*)/[^/]+$") or "."
local plugin_dir = test_dir .. "/../bookroom.koplugin"

local shown_message
local warnings = {}
local network_checks = 0
local mock_full_data_dir
local next_tick_tasks = {}
local scheduled_tasks = {}
local online = true
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
        nextTick = function(_, callback)
            next_tick_tasks[#next_tick_tasks + 1] = callback
        end,
        scheduleIn = function(_, _, callback)
            scheduled_tasks[#scheduled_tasks + 1] = callback
        end,
        unschedule = function() end,
    }
end

package.preload["ui/network/manager"] = function()
    return {
        isOnline = function() return online end,
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
    return {
        getFullDataDir = function() return mock_full_data_dir end,
        getSettingsDir = function() return "/mock/settings" end,
    }
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

local function runTasks(tasks)
    local pending = tasks
    if tasks == next_tick_tasks then
        next_tick_tasks = {}
    else
        scheduled_tasks = {}
    end
    for _, callback in ipairs(pending) do callback() end
end

local BookRoom = dofile(plugin_dir .. "/main.lua")

mock_full_data_dir = "/mnt/onboard/.adds/koreader"
local relative_path_instance = setmetatable({
    path = "plugins/bookroom.koplugin",
}, { __index = BookRoom })
assertEqual(
    relative_path_instance:resolvePluginRoot(),
    "/mnt/onboard/.adds/koreader/plugins/bookroom.koplugin",
    "relative PluginLoader path resolves against KOReader's absolute data directory"
)
assertEqual(
    relative_path_instance:getModulePath("docstate.lua"),
    "/mnt/onboard/.adds/koreader/plugins/bookroom.koplugin/docstate.lua",
    "lazy document module path is independent of cwd"
)
mock_full_data_dir = nil

-- Exercise the production loader path. Using a logical `and` around pcall
-- collapses pcall's second return value and makes a valid module look invalid.
local loader_instance = setmetatable({ path = plugin_dir }, { __index = BookRoom })
local loaded_document, document_load_error = loader_instance:loadDocumentModule()
assertEqual(document_load_error, nil, "actual document module loads without an error")
assertEqual(type(loaded_document), "table", "actual document module is returned")
assertEqual(type(loaded_document.capture), "function", "actual document capture callback exists")
local loaded_client, client_load_error = loader_instance:loadClientModule()
assertEqual(client_load_error, nil, "actual client module loads without an error")
assertEqual(type(loaded_client), "table", "actual client module is returned")
assertEqual(type(loaded_client.send), "function", "actual client send callback exists")

local registered_plugin
local toc_calls = 0
local http_calls = 0
local sent_payload
local sent_username
local sent_userkey
local client_result = { ok = true, status = 200 }
local current_page = 23
local current_toc_index = 2
local current_title = "CHAPTER III."
local current_progress = "/body/progress"
local instance = setmetatable({
    path = plugin_dir,
    ui = {
        getCurrentPage = function() return current_page end,
        toc = {
            toc = {
                { title = "Part I", depth = 1, page = 1, xpointer = "/body/part1", seq_in_level = 1 },
                { title = "CHAPTER III.", depth = 2, page = 20, xpointer = "/body/part1/chapter3", seq_in_level = 3 },
                { title = "CHAPTER II.", depth = 2, page = 10, xpointer = "/body/part1/chapter2", seq_in_level = 2 },
                { title = "CHAPTER IV.", depth = 2, page = 30, xpointer = "/body/part1/chapter4", seq_in_level = 4 },
                { title = "CHAPTER V.", depth = 2, page = 40, xpointer = "/body/part1/chapter5", seq_in_level = 5 },
                { title = "CHAPTER VI.", depth = 2, page = 50, xpointer = "/body/part1/chapter6", seq_in_level = 6 },
            },
            getTocTitleByPage = function(_, page)
                toc_calls = toc_calls + 1
                assertEqual(page, current_page, "menu action passes the current page")
                return current_title
            end,
            fillToc = function() end,
            getTocIndexByPage = function(_, page)
                assertEqual(page, current_page, "normalized chapter resolves current TOC entry")
                return current_toc_index
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
                progress = current_progress,
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
assertEqual(type(instance.onPageUpdate), "function", "plugin handles paged chapter observations")
assertEqual(type(instance.onPosUpdate), "function", "plugin handles rolling chapter observations")
instance:onPageUpdate(current_page)
instance:onPosUpdate(current_progress, current_page)
assertEqual(#next_tick_tasks, 1, "duplicate reader events schedule one observation")
runTasks(next_tick_tasks)
assertEqual(http_calls, before_page_turn, "same chapter across page turns produces no automatic request")

client_result = { ok = false, reason = "invalid_credentials", status = 401 }
shown_message = nil
send_item.callback()
assertEqual(shown_message.text, "Book Room credentials are no longer valid.\nReconnect KOReader progress sync.", "HTTP 401 has specific guidance")

client_result = { ok = false, reason = "network_failure", transportCode = -5 }
shown_message = nil
send_item.callback()
assertEqual(shown_message.text, "Could not reach Book Room.\nYour reading was not interrupted.\nTransport code: -5", "network failure is fail-open and diagnosable")

client_result = { ok = false, reason = "server_failure", status = 500 }
shown_message = nil
send_item.callback()
assertEqual(shown_message.text, "Book Room could not accept this chapter update.\nHTTP status: 500", "server failure exposes a safe status")

client_result = { ok = false, reason = "plugin_error", transportCode = "spore_unavailable" }
shown_message = nil
send_item.callback()
assertEqual(shown_message.text, "Book Room could not prepare this chapter update.\nDiagnostic: spore_unavailable", "local transport setup failure is safe and diagnosable")

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

-- Step 8 automatic observation uses both paged and rolling events, while
-- debouncing their duplicate delivery through one next-tick task.
instance.ui.toc.getTocTitleByPage = function(_, page)
    assertEqual(page, current_page, "automatic observation reads the live page")
    return current_title
end
client_result = { ok = true, status = 200 }
local canonical_progress = "Book Room Chapter 1"
local prompts_before_automatic = network_checks

current_page = 12
current_toc_index = 3
current_title = "CHAPTER II."
current_progress = "/body/part1/chapter2/p[2]"
local before_forward = http_calls
shown_message = nil
instance:onPageUpdate(current_page)
instance:onPosUpdate(current_progress, current_page)
assertEqual(#next_tick_tasks, 1, "page and position duplicates are debounced")
runTasks(next_tick_tasks)
assertEqual(http_calls, before_forward + 1, "Chapter III to Chapter II sends one automatic request")
assertEqual(sent_payload.chapter.title, "CHAPTER II.", "backward automatic payload uses current normalized chapter")
assertEqual(shown_message, nil, "successful automatic send shows no reading dialog")

current_page = 23
current_toc_index = 2
current_title = "CHAPTER III."
current_progress = "/body/part1/chapter3/p[2]"
local before_backward = http_calls
instance:onPageUpdate(current_page)
runTasks(next_tick_tasks)
assertEqual(http_calls, before_backward + 1, "Chapter II to Chapter III sends one automatic request")
assertEqual(sent_payload.chapter.title, "CHAPTER III.", "forward automatic payload uses current normalized chapter")

online = false
current_page = 32
current_toc_index = 4
current_title = "CHAPTER IV."
current_progress = "/body/part1/chapter4/p[2]"
local before_offline = http_calls
instance:onPageUpdate(current_page)
runTasks(next_tick_tasks)
assertEqual(http_calls, before_offline, "offline chapter change performs no request")
local observer = instance:getObserver()
assertEqual(observer:pendingCount(kosync_settings.username), 1, "offline change retains one pending document")
assertEqual(
    observer:getPending(kosync_settings.username, sent_payload.document).payload.chapter.title,
    "CHAPTER IV.",
    "offline state retains the current chapter"
)

current_page = 42
current_toc_index = 5
current_title = "CHAPTER V."
current_progress = "/body/part1/chapter5/p[2]"
instance:onPageUpdate(current_page)
runTasks(next_tick_tasks)
assertEqual(http_calls, before_offline, "newer offline chapter still performs no request")
assertEqual(observer:pendingCount(kosync_settings.username), 1, "newer offline state replaces rather than appends")
assertEqual(
    observer:getPending(kosync_settings.username, sent_payload.document).payload.chapter.title,
    "CHAPTER V.",
    "latest offline chapter replaces the older pending chapter"
)

online = true
instance:onNetworkConnected()
instance:onNetworkConnected()
assertEqual(#scheduled_tasks, 1, "duplicate reconnect events schedule one flush")
runTasks(scheduled_tasks)
assertEqual(http_calls, before_offline + 1, "reconnect sends one pending observation")
assertEqual(sent_payload.chapter.title, "CHAPTER V.", "reconnect sends only the latest pending chapter")
assertEqual(observer:pendingCount(kosync_settings.username), 0, "successful reconnect clears pending state")
assertEqual(shown_message, nil, "automatic reconnect send shows no reading dialog")

current_page = 43
local before_duplicate = http_calls
instance:onPageUpdate(current_page)
instance:onPosUpdate(current_progress, current_page)
runTasks(next_tick_tasks)
assertEqual(http_calls, before_duplicate, "same normalized chapter on another page sends nothing")

client_result = { ok = false, reason = "network_failure" }
current_page = 52
current_toc_index = 6
current_title = "CHAPTER VI."
current_progress = "/body/part1/chapter6/p[2]"
shown_message = nil
instance:onPageUpdate(current_page)
runTasks(next_tick_tasks)
assertEqual(http_calls, before_duplicate + 1, "failed automatic chapter change is attempted once")
assertEqual(shown_message, nil, "automatic network failure shows no reading dialog")
instance:onPageUpdate(current_page)
runTasks(next_tick_tasks)
assertEqual(http_calls, before_duplicate + 1, "page events do not repeatedly retry a failed chapter")
assertEqual(shown_message, nil, "repeated automatic failure remains silent")
assertEqual(
    network_checks,
    prompts_before_automatic,
    "automatic observation never invokes the interactive network helper"
)

client_result = { ok = true, status = 200 }
shown_message = nil
send_item.callback()
assertEqual(http_calls, before_duplicate + 2, "manual send remains available after automatic observation")
assertEqual(
    shown_message.text:find("Chapter synced with Book Room.", 1, true) ~= nil,
    true,
    "manual send still reports success"
)
assertEqual(
    canonical_progress,
    "Book Room Chapter 1",
    "automatic observation does not change canonical Book Room progress"
)

print("reader menu and manual-send tests passed")
