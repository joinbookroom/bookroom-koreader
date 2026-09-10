local Document = {}

local CHECKSUM_METHOD_FILENAME = 1

local function unavailable(reason)
    return {
        status = "unavailable",
        reason = reason,
    }
end

local function nonBlank(value)
    return type(value) == "string" and value:match("%S") ~= nil
end

local function loadDependencies(dependencies)
    dependencies = dependencies or {}

    local Device = dependencies.Device
    if not Device then
        local ok, module = pcall(require, "device")
        if not ok then return nil end
        Device = module
    end

    local Math = dependencies.Math
    if not Math then
        local ok, module = pcall(require, "optmath")
        if not ok then return nil end
        Math = module
    end

    local util = dependencies.util
    if not util then
        local ok, module = pcall(require, "util")
        if not ok then return nil end
        util = module
    end

    local md5 = dependencies.md5
    if not md5 then
        local ok, module = pcall(require, "ffi/sha2")
        if not ok or type(module) ~= "table" then return nil end
        md5 = module.md5
    end

    return {
        Device = Device,
        Math = Math,
        util = util,
        md5 = md5,
        readerSettings = dependencies.readerSettings or G_reader_settings,
    }
end

local function readDigest(ui, settings, dependencies)
    if settings.checksum_method == CHECKSUM_METHOD_FILENAME then
        local file = ui.document and ui.document.file
        if not nonBlank(file) or type(dependencies.util.splitFilePathName) ~= "function"
            or type(dependencies.md5) ~= "function" then
            return nil
        end
        local _, filename = dependencies.util.splitFilePathName(file)
        if not nonBlank(filename) then return nil end
        return dependencies.md5(filename)
    end

    if type(ui.doc_settings) ~= "table"
        or type(ui.doc_settings.readSetting) ~= "function" then
        return nil
    end
    local ok, digest = pcall(
        ui.doc_settings.readSetting,
        ui.doc_settings,
        "partial_md5_checksum"
    )
    return ok and nonBlank(digest) and digest or nil
end

local function readProgress(ui)
    if type(ui.document) ~= "table" or type(ui.document.info) ~= "table" then
        return nil
    end

    local reader = ui.document.info.has_pages and ui.paging or ui.rolling
    if type(reader) ~= "table"
        or type(reader.getLastProgress) ~= "function"
        or type(reader.getLastPercent) ~= "function" then
        return nil
    end

    local progress_ok, progress = pcall(reader.getLastProgress, reader)
    local percentage_ok, percentage = pcall(reader.getLastPercent, reader)
    if not progress_ok or not percentage_ok then return nil end
    if type(progress) ~= "string" and type(progress) ~= "number" then return nil end
    if type(percentage) ~= "number" then return nil end

    return tostring(progress), percentage
end

-- Mirrors KOReader 2026.07.1's built-in KOSync identity and live progress
-- selection. This module only reads reader state and never performs I/O.
function Document.capture(ui, settings, dependencies)
    if type(ui) ~= "table" or type(settings) ~= "table" then
        return unavailable("reader_unavailable")
    end

    local loaded = loadDependencies(dependencies)
    if not loaded or type(loaded.Math.roundPercent) ~= "function"
        or type(loaded.readerSettings) ~= "table"
        or type(loaded.readerSettings.readSetting) ~= "function" then
        return unavailable("koreader_api_unavailable")
    end

    local digest = readDigest(ui, settings, loaded)
    if not digest then return unavailable("document_digest_unavailable") end

    local progress, percentage = readProgress(ui)
    if progress == nil then return unavailable("progress_unavailable") end

    local rounded_ok, rounded_percentage = pcall(
        loaded.Math.roundPercent,
        percentage
    )
    if not rounded_ok or type(rounded_percentage) ~= "number"
        or rounded_percentage < 0 or rounded_percentage > 1 then
        return unavailable("progress_unavailable")
    end

    local id_ok, device_id = pcall(
        loaded.readerSettings.readSetting,
        loaded.readerSettings,
        "device_id"
    )
    if not id_ok or not nonBlank(device_id) then
        return unavailable("device_unavailable")
    end

    local device = settings.kosync_hostname or loaded.Device.model
    if not nonBlank(device) then return unavailable("device_unavailable") end

    return {
        status = "ok",
        document = digest,
        device = device,
        deviceId = device_id,
        progress = progress,
        percentage = rounded_percentage,
    }
end

return Document
