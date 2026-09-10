local source = debug.getinfo(1, "S").source:gsub("^@", "")
local test_dir = source:match("^(.*)/[^/]+$") or "."
local Document = dofile(test_dir .. "/../bookroom.koplugin/docstate.lua")

local function assertEqual(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
    end
end

local partial_digest = "f668708f3aa2f8779f57665ded56ed38"
local reader_settings = {
    readSetting = function(_, key)
        assertEqual(key, "device_id", "KOSync device ID setting is reused")
        return "17A13352062743B2A9FE49C058215A95"
    end,
}
local dependencies = {
    Device = { model = "Kobo Clara" },
    Math = { roundPercent = function(value) return value end },
    util = {
        splitFilePathName = function(path)
            assertEqual(path, "/mnt/onboard/Sense and Sensibility.epub", "active filename is used")
            return "/mnt/onboard/", "Sense and Sensibility.epub"
        end,
    },
    md5 = function(filename)
        assertEqual(filename, "Sense and Sensibility.epub", "filename-only checksum input matches KOSync")
        return "filename-md5"
    end,
    readerSettings = reader_settings,
}

local function rollingReader()
    return {
        document = {
            file = "/mnt/onboard/Sense and Sensibility.epub",
            info = { has_pages = false },
        },
        doc_settings = {
            readSetting = function(_, key)
                assertEqual(key, "partial_md5_checksum", "binary checksum uses KOSync document setting")
                return partial_digest
            end,
        },
        rolling = {
            getLastProgress = function()
                return "/body/DocFragment[4]/body/div/p[5]/text().307"
            end,
            getLastPercent = function()
                return 0.0399
            end,
        },
    }
end

local state = Document.capture(rollingReader(), {}, dependencies)
assertEqual(state.status, "ok", "rolling EPUB state is captured")
assertEqual(state.document, partial_digest, "binary digest exactly matches the Phase 1 document")
assertEqual(state.progress, "/body/DocFragment[4]/body/div/p[5]/text().307", "rolling XPointer is reused")
assertEqual(state.percentage, 0.0399, "rolling percentage is reused")
assertEqual(state.device, "Kobo Clara", "KOReader model is the default device name")
assertEqual(state.deviceId, "17A13352062743B2A9FE49C058215A95", "KOReader device ID is reused")

state = Document.capture(rollingReader(), {
    checksum_method = 1,
    kosync_hostname = "Fernando's Kobo",
}, dependencies)
assertEqual(state.document, "filename-md5", "filename matching mirrors KOSync when configured")
assertEqual(state.device, "Fernando's Kobo", "custom KOSync hostname is reused")

local paged = rollingReader()
paged.document.info.has_pages = true
paged.paging = {
    getLastProgress = function() return 21 end,
    getLastPercent = function() return 0.25 end,
}
state = Document.capture(paged, {}, dependencies)
assertEqual(state.progress, "21", "paged progress is stringified like KOSync")
assertEqual(state.percentage, 0.25, "paged percentage is reused")

local missing_digest = rollingReader()
missing_digest.doc_settings.readSetting = function() return nil end
state = Document.capture(missing_digest, {}, dependencies)
assertEqual(state.status, "unavailable", "missing digest fails open")
assertEqual(state.reason, "document_digest_unavailable", "missing digest has a generic reason")

print("KOSync document-state tests passed")
