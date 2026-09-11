local source = debug.getinfo(1, "S").source:gsub("^@", "")
local test_dir = source:match("^(.*)/[^/]+$") or "."
local Client = dofile(test_dir .. "/../bookroom.koplugin/client.lua")

local function assertEqual(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
    end
end

local secret = "DO_NOT_DISPLAY_THIS_USERKEY"
local null = {}
local encoded_payload
local service_spec
local request_params
local request_count = 0
local response = { status = 200 }
local should_throw = false
local timeout_values
local timeout_resets = 0

local spore_client = {
    send_chapter = function(_, params)
        request_count = request_count + 1
        request_params = params
        if should_throw then error("network unavailable") end
        return response
    end,
}

local dependencies = {
    rapidjson = {
        null = null,
        encode = function(payload)
            encoded_payload = payload
            return "{encoded-json}"
        end,
    },
    Spore = {
        new_from_lua = function(spec)
            service_spec = spec
            return spore_client
        end,
    },
    socketutil = {
        set_timeout = function(_, block, total)
            timeout_values = { block, total }
        end,
        reset_timeout = function()
            timeout_resets = timeout_resets + 1
        end,
    },
    -- This is the real Kobo configuration: DUSE_TURBO_LIB=false means there
    -- is no UIManager looper and Spore must use its LuaSocket/LuaSec fallback.
    UIManager = {
        looper = nil,
    },
}

local payload = {
    version = 1,
    document = "f668708f3aa2f8779f57665ded56ed38",
    device = "Kobo Clara",
    deviceId = "device-id",
    progress = "/body/progress",
    percentage = 0.0399,
    chapter = {
        title = "CHAPTER II.",
        tocIndex = 4,
        depth = 0,
        parentIndex = nil,
        sequenceInLevel = 5,
        path = { "CHAPTER II." },
        page = 21,
        location = "/body/chapter-2",
    },
    toc = {
        entries = {
            {
                title = "Contents",
                index = 0,
                depth = 0,
                path = { "Contents" },
                page = 1,
            },
            {
                title = "CHAPTER II.",
                index = 4,
                depth = 0,
                sequenceInLevel = 5,
                path = { "CHAPTER II." },
                page = 21,
                location = "/body/chapter-2",
            },
        },
    },
}

local send_result
local started = Client.send(payload, "reader", secret, function(value)
    send_result = value
end, dependencies)

assertEqual(started.started, true, "Kobo fallback starts one Spore request")
assertEqual(started.callbackInvoked, true, "Kobo fallback completes synchronously")
assertEqual(request_count, 1, "one manual send produces one request")
assertEqual(Client.endpoint, "https://sync.joinbookroom.com/bookroom/v1/chapter-progress", "endpoint is fixed")
assertEqual(service_spec.base_url, "https://sync.joinbookroom.com", "Spore base URL is fixed")
assertEqual(service_spec.methods.send_chapter.path, "/bookroom/v1/chapter-progress", "Spore path is fixed")
assertEqual(service_spec.methods.send_chapter.method, "PUT", "request uses PUT")
assertEqual(service_spec.methods.send_chapter.headers["content-type"], ":content_type", "JSON content type is bound as a Spore header parameter")
assertEqual(service_spec.methods.send_chapter.headers.accept, ":accept", "JSON accept value is bound as a Spore header parameter")
assertEqual(service_spec.methods.send_chapter.headers["x-auth-user"], ":username", "username is an authenticated header parameter")
assertEqual(service_spec.methods.send_chapter.headers["x-auth-key"], ":userkey", "userkey is an authenticated header parameter")
assertEqual(request_params.username, "reader", "KOSync username is supplied to Spore")
assertEqual(request_params.userkey, secret, "existing wire userkey is supplied unchanged")
assertEqual(request_params.content_type, "application/json", "outgoing media type is JSON")
assertEqual(request_params.accept, "application/json", "accepted response media type is JSON")
assertEqual(request_params.spore_payload, "{encoded-json}", "encoded JSON is supplied as the request body")
assertEqual(timeout_values[1], 2, "interactive block timeout mirrors KOSync")
assertEqual(timeout_values[2], 5, "interactive total timeout mirrors KOSync")
assertEqual(timeout_resets, 1, "socket timeout is reset")
assertEqual(encoded_payload.document, payload.document, "document digest is encoded")
assertEqual(encoded_payload.chapter.title, "CHAPTER II.", "chapter title punctuation is preserved")
assertEqual(encoded_payload.chapter.parentIndex, null, "nullable parent is encoded as JSON null")
assertEqual(encoded_payload.chapter.page, 21, "available page is encoded")
assertEqual(#encoded_payload.toc.entries, 2, "the normalized external TOC is encoded")
assertEqual(encoded_payload.toc.entries[1].tocIndex, 0, "TOC source indexes remain zero-based")
assertEqual(encoded_payload.toc.entries[1].parentIndex, null, "TOC nullable parents are encoded")
assertEqual(encoded_payload.toc.entries[2].title, "CHAPTER II.", "TOC titles remain raw")
assertEqual(send_result.ok, true, "HTTP 200 succeeds")
assertEqual(send_result.status, 200, "success status is retained")
assertEqual(send_result.userkey, nil, "result does not expose userkey")
assertEqual(started.userkey, nil, "start result does not expose userkey")

response = { status = 401 }
Client.send(payload, "reader", secret, function(value) send_result = value end, dependencies)
assertEqual(send_result.reason, "invalid_credentials", "HTTP 401 has a credential-specific result")

response = { status = 422 }
Client.send(payload, "reader", secret, function(value) send_result = value end, dependencies)
assertEqual(send_result.reason, "server_failure", "other 4xx responses are server failures")
assertEqual(send_result.status, 422, "server status is retained")

response = { status = 503 }
Client.send(payload, "reader", secret, function(value) send_result = value end, dependencies)
assertEqual(send_result.reason, "server_failure", "5xx responses are server failures")

should_throw = true
local calls_before_failure = request_count
started = Client.send(payload, "reader", secret, function(value)
    send_result = value
end, dependencies)
assertEqual(request_count, calls_before_failure + 1, "network failure is not retried")
assertEqual(started.started, true, "Kobo transport failure is contained after starting")
assertEqual(started.callbackInvoked, true, "Kobo transport failure invokes the callback")
assertEqual(send_result.reason, "network_failure", "Kobo transport failure is fail-open")
should_throw = false

-- Exercise the Turbo branch independently so non-Kobo platforms retain the
-- same asynchronous behavior as built-in KOSync.
local async_callback
local async_headers
local enabled_name
local enabled_args
local input_timeouts = 0
local async_client = {}

function async_client:enable(name, args)
    enabled_name = name
    enabled_args = args
end

function async_client:send_chapter(params)
    local request = {
        method = "PUT",
        headers = {
            ["content-type"] = params.content_type,
            ["accept"] = params.accept,
            ["x-auth-user"] = params.username,
            ["x-auth-key"] = params.userkey,
        },
        env = { spore = { payload = params.spore_payload } },
        finalize = function(self)
            self.url = Client.endpoint
        end,
    }
    local middleware = package.loaded[enabled_name]
    local middleware_thread = middleware.call(enabled_args, request)
    coroutine.yield()
    local _, value = coroutine.resume(middleware_thread)
    return value
end

local async_dependencies = {
    rapidjson = dependencies.rapidjson,
    Spore = {
        new_from_lua = function() return async_client end,
    },
    socketutil = dependencies.socketutil,
    UIManager = {
        looper = true,
        setInputTimeout = function()
            input_timeouts = input_timeouts + 1
        end,
    },
    httpclient = {
        new = function()
            return {
                request = function(_, options, callback)
                    async_headers = {}
                    options.on_headers({
                        add = function(_, name, value)
                            async_headers[name] = value
                        end,
                    })
                    async_callback = callback
                end,
            }
        end,
    },
}

send_result = nil
started = Client.send(payload, "reader", secret, function(value)
    send_result = value
end, async_dependencies)
assertEqual(started.started, true, "Turbo request starts asynchronously")
assertEqual(send_result, nil, "Turbo result waits for its callback")
assertEqual(enabled_name, "Spore.Middleware.BookRoomAsyncHTTP", "Book Room uses a private async middleware")
assertEqual(async_headers["content-type"], "application/json", "async JSON content type is sent")
assertEqual(async_headers["x-auth-user"], "reader", "async username header is sent")
assertEqual(async_headers["x-auth-key"], secret, "async userkey header is sent")
assertEqual(input_timeouts, 1, "KOReader looper is nudged for asynchronous HTTP")

async_callback({ code = 200 })
assertEqual(send_result.ok, true, "Turbo HTTP 200 succeeds")
assertEqual(send_result.status, 200, "Turbo status is retained")

print("Book Room HTTP client tests passed")
