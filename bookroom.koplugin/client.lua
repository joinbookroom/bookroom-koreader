local Client = {}

Client.endpoint = "https://sync.joinbookroom.com/bookroom/v1/chapter-progress"

local BLOCK_TIMEOUT = 2
local TOTAL_TIMEOUT = 5

local function result(reason, status)
    return {
        ok = reason == nil,
        reason = reason,
        status = status,
    }
end

local function loadDependencies(dependencies)
    dependencies = dependencies or {}

    local rapidjson = dependencies.rapidjson
    if not rapidjson then
        local ok, module = pcall(require, "rapidjson")
        if not ok then return nil end
        rapidjson = module
    end

    local httpclient = dependencies.httpclient
    if not httpclient then
        local ok, module = pcall(require, "httpclient")
        if not ok then return nil end
        httpclient = module
    end

    local socketutil = dependencies.socketutil
    if not socketutil then
        local ok, module = pcall(require, "socketutil")
        if not ok then return nil end
        socketutil = module
    end

    local UIManager = dependencies.UIManager
    if not UIManager then
        local ok, module = pcall(require, "ui/uimanager")
        if not ok then return nil end
        UIManager = module
    end

    return {
        rapidjson = rapidjson,
        httpclient = httpclient,
        socketutil = socketutil,
        UIManager = UIManager,
    }
end

local function encodablePayload(payload, null_value)
    if type(payload) ~= "table" or type(payload.chapter) ~= "table" then
        return nil
    end

    local chapter = payload.chapter
    return {
        version = payload.version,
        document = payload.document,
        device = payload.device,
        deviceId = payload.deviceId,
        progress = payload.progress,
        percentage = payload.percentage,
        chapter = {
            title = chapter.title,
            tocIndex = chapter.tocIndex,
            depth = chapter.depth,
            parentIndex = chapter.parentIndex == nil and null_value or chapter.parentIndex,
            sequenceInLevel = chapter.sequenceInLevel == nil and null_value or chapter.sequenceInLevel,
            path = chapter.path,
            page = chapter.page == nil and null_value or chapter.page,
            location = chapter.location == nil and null_value or chapter.location,
        },
        toc = payload.toc,
    }
end

local function classify(response)
    local status = type(response) == "table" and tonumber(response.code) or nil
    if status == 200 then return result(nil, status) end
    if status == 401 then return result("invalid_credentials", status) end
    if status then return result("server_failure", status) end
    return result("network_failure")
end

-- Uses the same KOReader asynchronous HTTP client and tight 2s/5s timeout
-- convention as the built-in KOSync manual progress push. There is no retry,
-- queue, timer, or page-turn hook here.
function Client.send(payload, username, userkey, callback, dependencies)
    local loaded = loadDependencies(dependencies)
    if not loaded or type(loaded.rapidjson.encode) ~= "function"
        or loaded.rapidjson.null == nil
        or type(loaded.httpclient.new) ~= "function"
        or type(loaded.socketutil.set_timeout) ~= "function"
        or type(loaded.socketutil.reset_timeout) ~= "function" then
        local failed = result("network_failure")
        if type(callback) == "function" then pcall(callback, failed) end
        return { started = false, reason = failed.reason, callbackInvoked = true }
    end

    local request_payload = encodablePayload(payload, loaded.rapidjson.null)
    local encode_ok, body = pcall(loaded.rapidjson.encode, request_payload)
    if not encode_ok or type(body) ~= "string" then
        local failed = result("encoding_failure")
        if type(callback) == "function" then pcall(callback, failed) end
        return { started = false, reason = failed.reason, callbackInvoked = true }
    end

    local function finish(response)
        if type(callback) == "function" then
            pcall(callback, classify(response))
        end
    end

    pcall(loaded.socketutil.set_timeout, loaded.socketutil, BLOCK_TIMEOUT, TOTAL_TIMEOUT)
    local request_ok = pcall(function()
        loaded.httpclient:new():request({
            url = Client.endpoint,
            method = "PUT",
            body = body,
            on_headers = function(headers)
                headers:add("Content-Type", "application/json")
                headers:add("Accept", "application/json")
                headers:add("x-auth-user", username)
                headers:add("x-auth-key", userkey)
            end,
        }, finish)
    end)
    pcall(loaded.socketutil.reset_timeout, loaded.socketutil)

    if not request_ok then
        local failed = result("network_failure")
        if type(callback) == "function" then pcall(callback, failed) end
        return { started = false, reason = failed.reason, callbackInvoked = true }
    end

    if loaded.UIManager.looper and type(loaded.UIManager.setInputTimeout) == "function" then
        pcall(loaded.UIManager.setInputTimeout, loaded.UIManager)
    end
    return { started = true }
end

return Client
