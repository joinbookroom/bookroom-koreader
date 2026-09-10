local Client = {}

Client.endpoint = "https://sync.joinbookroom.com/bookroom/v1/chapter-progress"

local BLOCK_TIMEOUT = 2
local TOTAL_TIMEOUT = 5
local ASYNC_MIDDLEWARE = "Spore.Middleware.BookRoomAsyncHTTP"

-- Use the same lua-Spore transport strategy as KOReader's built-in KOSync
-- client. Kobo ships with DUSE_TURBO_LIB=false, so Spore falls back to its
-- synchronous LuaSocket/LuaSec protocol there. On platforms with a Turbo
-- looper, the middleware below keeps the request asynchronous.
local SERVICE_SPEC = {
    base_url = "https://sync.joinbookroom.com",
    name = "bookroom-koreader-api",
    methods = {
        send_chapter = {
            path = "/bookroom/v1/chapter-progress",
            method = "PUT",
            required_params = {
                "username",
                "userkey",
                "content_type",
                "accept",
            },
            optional_payload = true,
            headers = {
                -- Spore.Request only copies method headers containing a
                -- parameter substitution into the outgoing header table.
                -- Binding these values prevents its payload fallback from
                -- replacing the media type with form-urlencoded.
                ["content-type"] = ":content_type",
                ["accept"] = ":accept",
                ["x-auth-user"] = ":username",
                ["x-auth-key"] = ":userkey",
            },
        },
    },
}

local function result(reason, status, transport_code)
    return {
        ok = reason == nil,
        reason = reason,
        status = status,
        transportCode = transport_code,
    }
end

local function loadDependencies(dependencies)
    dependencies = dependencies or {}

    local rapidjson = dependencies.rapidjson
    if not rapidjson then
        local ok, module = pcall(require, "rapidjson")
        if not ok then return nil, "rapidjson_unavailable" end
        rapidjson = module
    end

    local Spore = dependencies.Spore
    if not Spore then
        local ok, module = pcall(require, "Spore")
        if not ok then return nil, "spore_unavailable" end
        Spore = module
    end

    local socketutil = dependencies.socketutil
    if not socketutil then
        local ok, module = pcall(require, "socketutil")
        if not ok then return nil, "socketutil_unavailable" end
        socketutil = module
    end

    local UIManager = dependencies.UIManager
    if not UIManager then
        local ok, module = pcall(require, "ui/uimanager")
        if not ok then return nil, "uimanager_unavailable" end
        UIManager = module
    end

    local httpclient = dependencies.httpclient
    if UIManager.looper and not httpclient then
        local ok, module = pcall(require, "httpclient")
        if not ok then return nil, "httpclient_unavailable" end
        httpclient = module
    end

    return {
        rapidjson = rapidjson,
        Spore = Spore,
        socketutil = socketutil,
        UIManager = UIManager,
        httpclient = httpclient,
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
    local transport_error = type(response) == "table" and response.error or nil
    if type(transport_error) == "table" then
        return result("network_failure", nil, tonumber(transport_error.code))
    end

    local status = type(response) == "table"
        and tonumber(response.status or response.code) or nil
    if status == 200 then return result(nil, status) end
    if status == 401 then return result("invalid_credentials", status) end
    if status then return result("server_failure", status) end
    return result("network_failure")
end

local function responseFromCall(ok, value)
    if ok then return value end
    if type(value) == "table" and type(value.response) == "table" then
        return value.response
    end
    return nil
end

local function installAsyncMiddleware(httpclient)
    package.loaded[ASYNC_MIDDLEWARE] = {
        call = function(args, request)
            request:finalize()
            local response
            httpclient:new():request({
                url = request.url,
                method = request.method,
                body = request.env.spore.payload,
                on_headers = function(headers)
                    for header, value in pairs(request.headers) do
                        if type(header) == "string" then
                            headers:add(header, value)
                        end
                    end
                end,
            }, function(value)
                response = value or {}
                response.status = response.code
                coroutine.resume(args.thread)
            end)
            return coroutine.create(function()
                coroutine.yield(response)
            end)
        end,
    }
end

-- One manual tap starts exactly one request. This mirrors KOSync's 2s/5s
-- timeout convention and transport selection; it never retries or queues.
function Client.send(payload, username, userkey, callback, dependencies)
    local loaded, dependency_error = loadDependencies(dependencies)
    if not loaded or type(loaded.rapidjson.encode) ~= "function"
        or loaded.rapidjson.null == nil
        or type(loaded.Spore.new_from_lua) ~= "function"
        or type(loaded.socketutil.set_timeout) ~= "function"
        or type(loaded.socketutil.reset_timeout) ~= "function" then
        local failed = result("plugin_error", nil, dependency_error)
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

    local client_ok, client = pcall(loaded.Spore.new_from_lua, SERVICE_SPEC)
    if not client_ok or type(client) ~= "table"
        or type(client.send_chapter) ~= "function" then
        local failed = result("plugin_error", nil, "spore_client_unavailable")
        if type(callback) == "function" then pcall(callback, failed) end
        return { started = false, reason = failed.reason, callbackInvoked = true }
    end

    local function finish(ok, value)
        if type(callback) == "function" then
            pcall(callback, classify(responseFromCall(ok, value)))
        end
    end

    local function request()
        return client:send_chapter({
            username = username,
            userkey = userkey,
            content_type = "application/json",
            accept = "application/json",
            spore_payload = body,
        })
    end

    pcall(loaded.socketutil.set_timeout, loaded.socketutil, BLOCK_TIMEOUT, TOTAL_TIMEOUT)

    if loaded.UIManager.looper then
        if type(loaded.httpclient) ~= "table"
            or type(loaded.httpclient.new) ~= "function"
            or type(client.enable) ~= "function" then
            pcall(loaded.socketutil.reset_timeout, loaded.socketutil)
            local failed = result("plugin_error", nil, "async_transport_unavailable")
            if type(callback) == "function" then pcall(callback, failed) end
            return { started = false, reason = failed.reason, callbackInvoked = true }
        end

        installAsyncMiddleware(loaded.httpclient)
        local thread = coroutine.create(function()
            finish(pcall(request))
        end)
        client:enable(ASYNC_MIDDLEWARE, { thread = thread })
        local resume_ok = coroutine.resume(thread)
        pcall(loaded.socketutil.reset_timeout, loaded.socketutil)
        if not resume_ok then
            local failed = result("network_failure")
            if type(callback) == "function" then pcall(callback, failed) end
            return { started = false, reason = failed.reason, callbackInvoked = true }
        end
        if type(loaded.UIManager.setInputTimeout) == "function" then
            pcall(loaded.UIManager.setInputTimeout, loaded.UIManager)
        end
        return { started = true }
    end

    -- This is the normal Kobo path. Spore.Protocols uses LuaSocket/LuaSec,
    -- just as the built-in KOSync client does when Turbo is disabled.
    local request_ok, response = pcall(request)
    pcall(loaded.socketutil.reset_timeout, loaded.socketutil)
    finish(request_ok, response)
    return { started = true, callbackInvoked = true }
end

return Client
