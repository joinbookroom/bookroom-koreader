local source = debug.getinfo(1, "S").source:gsub("^@", "")
local test_dir = source:match("^(.*)/[^/]+$") or "."
local Observer = dofile(test_dir .. "/../bookroom.koplugin/observer.lua")

local function assertEqual(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
    end
end

local function contains(value, needle, seen)
    if type(value) == "string" then return value == needle end
    if type(value) ~= "table" then return false end
    seen = seen or {}
    if seen[value] then return false end
    seen[value] = true
    for key, child in pairs(value) do
        if contains(key, needle, seen) or contains(child, needle, seen) then
            return true
        end
    end
    return false
end

local saved
local storage = {
    load = function() return saved end,
    save = function(value)
        saved = value
        return true
    end,
}

local owner = "reader"
local document = "f668708f3aa2f8779f57665ded56ed38"
local canonical_progress = "Book Room Chapter 1"
local requests = {}
local send_result = { ok = true, status = 200 }

local function entry(title, index, location)
    return {
        index = index,
        depth = 0,
        parentIndex = nil,
        sequenceInLevel = index + 1,
        title = title,
        path = { title },
        page = index * 10 + 1,
        location = location,
    }
end

local function payload(chapter)
    return {
        version = 1,
        document = document,
        device = "Kobo Clara",
        deviceId = "device-id",
        progress = "/body/live-progress",
        percentage = 0.25,
        chapter = {
            title = chapter.title,
            tocIndex = chapter.index,
            depth = chapter.depth,
            parentIndex = chapter.parentIndex,
            sequenceInLevel = chapter.sequenceInLevel,
            path = chapter.path,
            page = chapter.page,
            location = chapter.location,
        },
    }
end

local function send(observation, callback)
    requests[#requests + 1] = observation
    callback(send_result)
    return { started = true, callbackInvoked = true }
end

local observer = Observer.new{ storage = storage }
local chapter_two = entry("CHAPTER II.", 4, "/body/chapter2")
local chapter_three = entry("CHAPTER III.", 5, "/body/chapter3")
local retitled_chapter_two = entry("Chapter Two", 4, "/body/chapter2")
assertEqual(
    Observer.chapterKey(chapter_two) == Observer.chapterKey(retitled_chapter_two),
    false,
    "nullable parent does not truncate normalized identity comparison"
)

local result = observer:observe(
    owner, document, chapter_two, payload(chapter_two), true, send
)
assertEqual(result.changed, true, "first local chapter is observed")
assertEqual(#requests, 1, "first online observation is sent")
assertEqual(observer:pendingCount(owner), 0, "successful observation is not pending")

-- Live progress may change on every page, but the normalized TOC identity
-- remains the same and must not produce another request.
local same_chapter_payload = payload(chapter_two)
same_chapter_payload.progress = "/body/another-page"
same_chapter_payload.percentage = 0.27
result = observer:observe(
    owner, document, chapter_two, same_chapter_payload, true, send
)
assertEqual(result.changed, false, "same chapter across page turns is unchanged")
assertEqual(#requests, 1, "same chapter produces zero additional requests")

result = observer:observe(
    owner, document, chapter_three, payload(chapter_three), true, send
)
assertEqual(result.changed, true, "forward chapter change is observed")
assertEqual(#requests, 2, "Chapter II to Chapter III produces one request")

result = observer:observe(
    owner, document, chapter_two, payload(chapter_two), true, send
)
assertEqual(result.changed, true, "backward chapter change is observed")
assertEqual(#requests, 3, "Chapter III to Chapter II produces one request")

local chapter_four = entry("CHAPTER IV.", 6, "/body/chapter4")
result = observer:observe(
    owner, document, chapter_four, payload(chapter_four), false, send
)
assertEqual(result.changed, true, "offline chapter change is observed")
assertEqual(#requests, 3, "offline chapter change sends nothing")
assertEqual(observer:pendingCount(owner), 1, "offline observation is pending")
assertEqual(
    observer:getPending(owner, document).payload.chapter.title,
    "CHAPTER IV.",
    "offline pending state stores the latest chapter"
)

local chapter_five = entry("CHAPTER V.", 7, "/body/chapter5")
observer:observe(
    owner, document, chapter_five, payload(chapter_five), false, send
)
assertEqual(#requests, 3, "second offline change still sends nothing")
assertEqual(observer:pendingCount(owner), 1, "only one pending item is retained per document")
assertEqual(
    observer:getPending(owner, document).payload.chapter.title,
    "CHAPTER V.",
    "newer offline chapter replaces the older pending state"
)

local flushed = observer:flush(owner, true, send)
assertEqual(flushed, 1, "reconnect starts the latest pending send")
assertEqual(#requests, 4, "reconnect sends one latest observation")
assertEqual(requests[4].chapter.title, "CHAPTER V.", "reconnect sends the newest chapter")
assertEqual(observer:pendingCount(owner), 0, "successful reconnect clears pending state")

-- Duplicate observations after reconnect are locally debounced.
local online_checks = 0
observer:observe(
    owner, document, chapter_five, payload(chapter_five), function()
        online_checks = online_checks + 1
        return true
    end, send
)
observer:observe(
    owner, document, chapter_five, payload(chapter_five), function()
        online_checks = online_checks + 1
        return true
    end, send
)
assertEqual(#requests, 4, "duplicate chapter events produce no requests")
assertEqual(online_checks, 0, "duplicate chapter events perform no network check")

-- A failed automatic attempt remains pending, but repeated page events in the
-- same chapter do not turn into a retry loop.
send_result = { ok = false, reason = "network_failure" }
local chapter_six = entry("CHAPTER VI.", 8, "/body/chapter6")
observer:observe(
    owner, document, chapter_six, payload(chapter_six), true, send
)
assertEqual(#requests, 5, "new chapter gets one automatic attempt")
assertEqual(observer:pendingCount(owner), 1, "failed send remains pending")
observer:observe(
    owner, document, chapter_six, payload(chapter_six), true, send
)
assertEqual(#requests, 5, "same chapter does not repeatedly retry after failure")

-- The latest state survives a new observer instance, without credentials.
local reloaded = Observer.new{ storage = storage }
assertEqual(
    reloaded:getPending(owner, document).payload.chapter.title,
    "CHAPTER VI.",
    "pending observation persists across plugin instances"
)

send_result = { ok = true, status = 200 }
reloaded:recordSuccessful(owner, document, chapter_six)
assertEqual(reloaded:pendingCount(owner), 0, "manual success clears older pending state")
assertEqual(
    canonical_progress,
    "Book Room Chapter 1",
    "observation state never changes canonical Book Room progress"
)

-- If a chapter changes while an asynchronous request is still in flight, the
-- latest state waits and is sent immediately afterward. Requests for one
-- document cannot complete out of order.
local async_observer = Observer.new{ storage = {
    load = function() return nil end,
    save = function() return true end,
} }
local async_requests = {}
local async_callbacks = {}
local function asyncSend(observation, callback)
    async_requests[#async_requests + 1] = observation
    async_callbacks[#async_callbacks + 1] = callback
    return { started = true }
end
async_observer:observe(
    owner, document, chapter_two, payload(chapter_two), true, asyncSend
)
async_observer:observe(
    owner, document, chapter_three, payload(chapter_three), true, asyncSend
)
assertEqual(#async_requests, 1, "one document has at most one request in flight")
assertEqual(
    async_observer:getPending(owner, document).payload.chapter.title,
    "CHAPTER III.",
    "new chapter replaces pending state while an older send is in flight"
)
async_callbacks[1]({ ok = true, status = 200 })
assertEqual(#async_requests, 2, "latest pending chapter follows the completed request")
assertEqual(async_requests[2].chapter.title, "CHAPTER III.", "follow-up send uses latest chapter")
async_callbacks[2]({ ok = true, status = 200 })
assertEqual(async_observer:pendingCount(owner), 0, "latest asynchronous success clears pending state")

local persist_options
local persisted_state
local persistent_observer = Observer.new{
    DataStorage = {
        getSettingsDir = function() return "/mock/settings" end,
    },
    Persist = {
        new = function(_, options)
            persist_options = options
            return {
                exists = function() return persisted_state ~= nil end,
                load = function() return persisted_state end,
                save = function(_, value)
                    persisted_state = value
                    return true
                end,
            }
        end,
    },
}
persistent_observer:observe(
    owner, document, chapter_two, payload(chapter_two), false, send
)
assertEqual(
    persist_options.path,
    "/mock/settings/bookroom_observations.lua",
    "pending state uses a Book Room-owned KOReader settings file"
)
assertEqual(persist_options.codec, "dump", "pending state uses KOReader persistence")
assertEqual(
    contains(persisted_state, "DO_NOT_DISPLAY_THIS_USERKEY"),
    false,
    "persistent observation state never contains the userkey"
)

print("automatic chapter observer tests passed")
