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
local request
local response_callback
local timeout_values
local timeout_resets = 0
local input_timeouts = 0

local dependencies = {
    rapidjson = {
        null = null,
        encode = function(payload)
            encoded_payload = payload
            return "{encoded-json}"
        end,
    },
    httpclient = {
        new = function()
            return {
                request = function(_, options, callback)
                    request = options
                    response_callback = callback
                end,
            }
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
    UIManager = {
        looper = true,
        setInputTimeout = function()
            input_timeouts = input_timeouts + 1
        end,
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
}

local send_result
local started = Client.send(payload, "reader", secret, function(value)
    send_result = value
end, dependencies)
assertEqual(started.started, true, "valid send starts one request")
assertEqual(Client.endpoint, "https://sync.joinbookroom.com/bookroom/v1/chapter-progress", "endpoint is fixed")
assertEqual(request.url, Client.endpoint, "request uses only the Book Room endpoint")
assertEqual(request.method, "PUT", "request uses PUT")
assertEqual(request.body, "{encoded-json}", "encoded body is sent")
assertEqual(timeout_values[1], 2, "interactive block timeout mirrors KOSync")
assertEqual(timeout_values[2], 5, "interactive total timeout mirrors KOSync")
assertEqual(timeout_resets, 1, "socket timeout is reset")
assertEqual(input_timeouts, 1, "KOReader looper is nudged for asynchronous HTTP")
assertEqual(encoded_payload.document, payload.document, "document digest is encoded")
assertEqual(encoded_payload.chapter.title, "CHAPTER II.", "chapter title punctuation is preserved")
assertEqual(encoded_payload.chapter.parentIndex, null, "nullable parent is encoded as JSON null")
assertEqual(encoded_payload.chapter.page, 21, "available page is encoded")

local headers = {}
request.on_headers({
    add = function(_, name, value)
        headers[name] = value
    end,
})
assertEqual(headers["Content-Type"], "application/json", "JSON content type is sent")
assertEqual(headers["Accept"], "application/json", "JSON response is requested")
assertEqual(headers["x-auth-user"], "reader", "KOSync username header is used")
assertEqual(headers["x-auth-key"], secret, "existing wire userkey is sent unchanged")
assertEqual(started.userkey, nil, "start result does not expose userkey")

response_callback({ code = 200 })
assertEqual(send_result.ok, true, "HTTP 200 succeeds")
assertEqual(send_result.status, 200, "success status is retained")
assertEqual(send_result.userkey, nil, "success result does not expose userkey")

response_callback({ code = 401 })
assertEqual(send_result.reason, "invalid_credentials", "HTTP 401 has a credential-specific result")

response_callback({ code = 422 })
assertEqual(send_result.reason, "server_failure", "other 4xx responses are server failures")
response_callback({ code = 503 })
assertEqual(send_result.reason, "server_failure", "5xx responses are server failures")
response_callback({})
assertEqual(send_result.reason, "network_failure", "timeout/network responses fail open")

local request_count = 0
local throwing_dependencies = {
    rapidjson = dependencies.rapidjson,
    socketutil = dependencies.socketutil,
    UIManager = dependencies.UIManager,
    httpclient = {
        new = function()
            return {
                request = function()
                    request_count = request_count + 1
                    error("network unavailable")
                end,
            }
        end,
    },
}
started = Client.send(payload, "reader", secret, function(value)
    send_result = value
end, throwing_dependencies)
assertEqual(request_count, 1, "network failure is not retried")
assertEqual(started.started, false, "synchronous network failure is contained")
assertEqual(send_result.reason, "network_failure", "synchronous network failure is generic")
assertEqual(started.userkey, nil, "failure result does not expose userkey")

print("Book Room HTTP client tests passed")
