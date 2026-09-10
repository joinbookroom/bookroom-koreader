local Observer = {}
Observer.__index = Observer

local STATE_VERSION = 1
local STATE_FILENAME = "bookroom_observations.lua"

local function nonBlank(value)
    return type(value) == "string" and value:match("%S") ~= nil
end

local function scalar(value)
    if value == nil then return "-1:" end
    local text = tostring(value)
    return tostring(#text) .. ":" .. text
end

-- Compare the complete normalized TOC identity, not live page progress.
-- A TOC entry's page/location are stable while turning pages within it.
function Observer.chapterKey(entry)
    if type(entry) ~= "table" then return nil end

    -- Encode fields directly because nullable values (notably parentIndex)
    -- cannot safely live in an array traversed with ipairs.
    local encoded = {
        scalar(entry.index),
        scalar(entry.depth),
        scalar(entry.parentIndex),
        scalar(entry.sequenceInLevel),
        scalar(entry.title),
        scalar(entry.page),
        scalar(entry.location),
    }
    local path = type(entry.path) == "table" and entry.path or {}
    encoded[#encoded + 1] = scalar(#path)
    for _, part in ipairs(path) do
        encoded[#encoded + 1] = scalar(part)
    end

    return table.concat(encoded, "|")
end

local function memoryStorage()
    return {
        load = function() return nil end,
        save = function() return true end,
    }
end

local function defaultStorage(dependencies)
    dependencies = dependencies or {}

    local DataStorage = dependencies.DataStorage
    if not DataStorage then
        local ok, module = pcall(require, "datastorage")
        if not ok then return memoryStorage() end
        DataStorage = module
    end

    local Persist = dependencies.Persist
    if not Persist then
        local ok, module = pcall(require, "persist")
        if not ok then return memoryStorage() end
        Persist = module
    end

    if type(DataStorage) ~= "table"
        or type(DataStorage.getSettingsDir) ~= "function"
        or type(Persist) ~= "table"
        or type(Persist.new) ~= "function" then
        return memoryStorage()
    end

    local path_ok, settings_dir = pcall(DataStorage.getSettingsDir, DataStorage)
    if not path_ok or not nonBlank(settings_dir) then return memoryStorage() end

    local persist_ok, persist = pcall(Persist.new, Persist, {
        path = settings_dir:gsub("/$", "") .. "/" .. STATE_FILENAME,
        codec = "dump",
    })
    if not persist_ok or type(persist) ~= "table" then return memoryStorage() end

    return {
        load = function()
            local exists_ok, exists = pcall(persist.exists, persist)
            if not exists_ok or not exists then return nil end
            local load_ok, data = pcall(persist.load, persist)
            return load_ok and data or nil
        end,
        save = function(data)
            local save_ok, result = pcall(persist.save, persist, data)
            return save_ok and result ~= false
        end,
    }
end

local function validData(data)
    if type(data) ~= "table" then data = {} end
    if data.version ~= STATE_VERSION or type(data.owners) ~= "table" then
        data = {
            version = STATE_VERSION,
            owners = {},
        }
    end
    return data
end

function Observer.new(options)
    options = options or {}
    return setmetatable({
        storage = options.storage or defaultStorage(options),
        data = nil,
        inFlight = {},
    }, Observer)
end

function Observer:_data()
    if not self.data then
        local load_ok, loaded = pcall(self.storage.load)
        self.data = validData(load_ok and loaded or nil)
    end
    return self.data
end

function Observer:_save()
    pcall(self.storage.save, self:_data())
end

function Observer:_documents(owner, create)
    if not nonBlank(owner) then return nil end
    local owners = self:_data().owners
    local bucket = owners[owner]
    if not bucket and create then
        bucket = { documents = {} }
        owners[owner] = bucket
    end
    if type(bucket) ~= "table" then return nil end
    if type(bucket.documents) ~= "table" then
        if not create then return nil end
        bucket.documents = {}
    end
    return bucket.documents
end

function Observer:getPending(owner, document)
    local documents = self:_documents(owner, false)
    local state = documents and documents[document]
    return type(state) == "table" and state.pending or nil
end

function Observer:pendingCount(owner)
    local count = 0
    local documents = self:_documents(owner, false) or {}
    for _, state in pairs(documents) do
        if type(state) == "table" and type(state.pending) == "table" then
            count = count + 1
        end
    end
    return count
end

function Observer:_markSent(owner, document, key)
    local documents = self:_documents(owner, false)
    local state = documents and documents[document]
    if type(state) ~= "table" then return end

    state.sentKey = key
    if type(state.pending) == "table" and state.pending.key == key then
        state.pending = nil
    end
    self:_save()
end

function Observer:recordSuccessful(owner, document, entry)
    local key = Observer.chapterKey(entry)
    if not key or not nonBlank(document) then return false end

    local documents = self:_documents(owner, true)
    if not documents then return false end
    local state = documents[document] or {}
    documents[document] = state
    state.observedKey = key
    state.sentKey = key
    -- A successful forced manual send represents the latest live state for
    -- this document, so it supersedes any older pending observation.
    state.pending = nil
    self:_save()
    return true
end

function Observer:_sendPending(owner, document, send)
    if type(send) ~= "function" then return false end
    local pending = self:getPending(owner, document)
    if type(pending) ~= "table" or type(pending.payload) ~= "table" then
        return false
    end

    local flight_id = owner .. "\31" .. document
    -- Serialize sends per document so a slower older request can never arrive
    -- after a newer chapter and regress the server's external observation.
    if self.inFlight[flight_id] then return false end
    self.inFlight[flight_id] = pending.key

    local key = pending.key
    local callback_invoked = false
    local function finished(send_result)
        callback_invoked = true
        if self.inFlight[flight_id] == key then
            self.inFlight[flight_id] = nil
        end
        if type(send_result) == "table" and send_result.ok then
            self:_markSent(owner, document, key)
        end
        local latest = self:getPending(owner, document)
        if type(latest) == "table" and latest.key ~= key then
            self:_sendPending(owner, document, send)
        end
    end

    local send_ok, operation = pcall(send, pending.payload, finished)
    if not send_ok or type(operation) ~= "table" or not operation.started then
        if self.inFlight[flight_id] == key then
            self.inFlight[flight_id] = nil
        end
        return false
    end

    -- Synchronous Kobo sends invoke the callback before returning. Async
    -- transports retain the in-flight marker until their callback arrives.
    if operation.callbackInvoked and not callback_invoked then
        self.inFlight[flight_id] = nil
    end
    return true
end

function Observer:observe(owner, document, entry, payload, online, send)
    local key = Observer.chapterKey(entry)
    if not key or not nonBlank(document) or type(payload) ~= "table" then
        return { changed = false, reason = "invalid_observation" }
    end

    local documents = self:_documents(owner, true)
    if not documents then
        return { changed = false, reason = "invalid_owner" }
    end

    local state = documents[document] or {}
    documents[document] = state
    if state.observedKey == key then
        return {
            changed = false,
            pending = type(state.pending) == "table",
        }
    end

    state.observedKey = key
    state.pending = {
        key = key,
        payload = payload,
    }
    self:_save()

    local is_online = online
    if type(online) == "function" then
        local online_ok, value = pcall(online)
        is_online = online_ok and value == true
    end

    local started = false
    if is_online then
        started = self:_sendPending(owner, document, send)
    end
    return {
        changed = true,
        pending = self:getPending(owner, document) ~= nil,
        started = started,
    }
end

function Observer:flush(owner, online, send)
    if not online then return 0 end
    local documents = self:_documents(owner, false) or {}
    local document_ids = {}
    for document, state in pairs(documents) do
        if type(state) == "table" and type(state.pending) == "table" then
            document_ids[#document_ids + 1] = document
        end
    end
    table.sort(document_ids)

    local started = 0
    for _, document in ipairs(document_ids) do
        if self:_sendPending(owner, document, send) then
            started = started + 1
        end
    end
    return started
end

return Observer
