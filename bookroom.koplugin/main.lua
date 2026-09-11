local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

local BookRoom = WidgetContainer:extend{
    name = "bookroom",
    is_doc_only = true,
}

function BookRoom:resolvePluginRoot()
    if type(self.path) ~= "string" or self.path == "" then return nil end
    if self.path:sub(1, 1) == "/" then return self.path end

    if type(DataStorage) == "table" and type(DataStorage.getFullDataDir) == "function" then
        local ok, data_dir = pcall(DataStorage.getFullDataDir, DataStorage)
        if ok and type(data_dir) == "string" and data_dir:sub(1, 1) == "/" then
            return data_dir:gsub("/$", "") .. "/" .. self.path:gsub("^%./", "")
        end
    end

    return self.path
end

function BookRoom:getModulePath(filename)
    local root = self.module_root or self:resolvePluginRoot()
    if type(root) ~= "string" or root == "" then return nil end
    return root:gsub("/$", "") .. "/" .. filename
end

function BookRoom:init()
    -- PluginLoader provides a relative self.path. Resolve it while KOReader's
    -- data directory is known so delayed menu actions never depend on cwd.
    self.module_root = self:resolvePluginRoot()
    self.observation_task = function()
        self.observation_scheduled = false
        self:observeChapterChange()
    end
    self.reconnect_task = function()
        self.reconnect_scheduled = false
        self:flushPendingObservations()
    end
    self.ui.menu:registerToMainMenu(self)
end

function BookRoom:loadChapterModule()
    if self.chapter_module then
        return self.chapter_module
    end
    if self.chapter_module_error then
        return nil, self.chapter_module_error
    end

    local module_path = self:getModulePath("chapter.lua")
    if not module_path then
        self.chapter_module_error = "plugin path unavailable"
        return nil, self.chapter_module_error
    end

    local ok, module_or_error = pcall(dofile, module_path)
    if not ok or type(module_or_error) ~= "table" or type(module_or_error.detect) ~= "function" then
        self.chapter_module_error = ok and "invalid chapter module" or tostring(module_or_error)
        logger.warn("BookRoom: unable to load chapter extraction:", self.chapter_module_error)
        return nil, self.chapter_module_error
    end

    self.chapter_module = module_or_error
    return self.chapter_module
end

function BookRoom:loadTocModule()
    if self.toc_module then
        return self.toc_module
    end
    if self.toc_module_error then
        return nil, self.toc_module_error
    end

    local module_path = self:getModulePath("toc.lua")
    if not module_path then
        self.toc_module_error = "plugin path unavailable"
        return nil, self.toc_module_error
    end

    local ok, module_or_error = pcall(dofile, module_path)
    if not ok or type(module_or_error) ~= "table"
        or type(module_or_error.inspect) ~= "function"
        or type(module_or_error.formatDiagnostics) ~= "function" then
        self.toc_module_error = ok and "invalid TOC module" or tostring(module_or_error)
        logger.warn("BookRoom: unable to load TOC module:", self.toc_module_error)
        return nil, self.toc_module_error
    end

    self.toc_module = module_or_error
    return self.toc_module
end

function BookRoom:loadCredentialsModule()
    if self.credentials_module then
        return self.credentials_module
    end
    if self.credentials_module_error then
        return nil, self.credentials_module_error
    end

    local module_path = self:getModulePath("kosync_credentials.lua")
    if not module_path then
        self.credentials_module_error = "plugin path unavailable"
        return nil, self.credentials_module_error
    end

    local ok, module_or_error = pcall(dofile, module_path)
    if not ok or type(module_or_error) ~= "table"
        or type(module_or_error.read) ~= "function"
        or type(module_or_error.formatStatus) ~= "function" then
        self.credentials_module_error = ok and "invalid credentials module" or tostring(module_or_error)
        logger.warn("BookRoom: unable to load KOSync credential reader")
        return nil, self.credentials_module_error
    end

    self.credentials_module = module_or_error
    return self.credentials_module
end

function BookRoom:loadDocumentModule()
    if self.document_module then return self.document_module end
    if self.document_module_error then return nil, self.document_module_error end

    -- Keep device-side module names within FAT's native 8.3 form. The former
    -- kosync_document.lua repeatedly became an orphaned FSCK file on the Kobo.
    local module_path = self:getModulePath("docstate.lua")
    if not module_path then
        self.document_module_error = "document_module_path_unavailable"
        return nil, self.document_module_error
    end

    local ok, module_or_error = pcall(dofile, module_path)
    if not ok or type(module_or_error) ~= "table"
        or type(module_or_error.capture) ~= "function" then
        self.document_module_error = ok and "document_module_invalid"
            or "document_module_load_failed"
        logger.warn(
            "BookRoom: unable to load KOSync document reader:",
            ok and self.document_module_error or tostring(module_or_error)
        )
        return nil, self.document_module_error
    end
    self.document_module = module_or_error
    return self.document_module
end

function BookRoom:loadClientModule()
    if self.client_module then return self.client_module end
    if self.client_module_error then return nil, self.client_module_error end

    local module_path = self:getModulePath("client.lua")
    if not module_path then
        self.client_module_error = "client_module_path_unavailable"
        return nil, self.client_module_error
    end

    local ok, module_or_error = pcall(dofile, module_path)
    if not ok or type(module_or_error) ~= "table"
        or type(module_or_error.send) ~= "function" then
        self.client_module_error = ok and "client_module_invalid"
            or "client_module_load_failed"
        logger.warn(
            "BookRoom: unable to load Book Room HTTP client:",
            ok and self.client_module_error or tostring(module_or_error)
        )
        return nil, self.client_module_error
    end
    self.client_module = module_or_error
    return self.client_module
end

function BookRoom:loadObserverModule()
    if self.observer_module then return self.observer_module end
    if self.observer_module_error then return nil, self.observer_module_error end

    local module_path = self:getModulePath("observer.lua")
    if not module_path then
        self.observer_module_error = "observer_module_path_unavailable"
        return nil, self.observer_module_error
    end

    local ok, module_or_error = pcall(dofile, module_path)
    if not ok or type(module_or_error) ~= "table"
        or type(module_or_error.new) ~= "function"
        or type(module_or_error.chapterKey) ~= "function" then
        self.observer_module_error = ok and "observer_module_invalid"
            or "observer_module_load_failed"
        logger.warn(
            "BookRoom: unable to load chapter observer:",
            ok and self.observer_module_error or tostring(module_or_error)
        )
        return nil, self.observer_module_error
    end
    self.observer_module = module_or_error
    return self.observer_module
end

function BookRoom:getObserver()
    if self.observer then return self.observer end
    local module = self:loadObserverModule()
    if not module then return nil end
    local ok, observer = pcall(module.new)
    if not ok or type(observer) ~= "table" then
        logger.warn("BookRoom: unable to initialize chapter observer")
        return nil
    end
    self.observer = observer
    return self.observer
end

function BookRoom:getChapterSnapshot()
    local load_ok, chapter, module_error = pcall(self.loadChapterModule, self)
    if not load_ok then
        logger.warn("BookRoom: chapter module load failed:", chapter)
        return {
            status = "unavailable",
            reason = "plugin_error",
            detail = tostring(chapter),
        }
    end
    if not chapter then
        return {
            status = "unavailable",
            reason = "plugin_error",
            detail = module_error,
        }
    end

    local ok, snapshot_or_error = pcall(chapter.detect, self.ui)
    if not ok or type(snapshot_or_error) ~= "table" then
        local detail = ok and "invalid chapter result" or tostring(snapshot_or_error)
        logger.warn("BookRoom: chapter extraction failed:", detail)
        return {
            status = "unavailable",
            reason = "plugin_error",
            detail = detail,
        }
    end

    if snapshot_or_error.status == "ok" then
        logger.dbg(
            "BookRoom: current chapter:",
            snapshot_or_error.title,
            "location:",
            tostring(snapshot_or_error.page),
            "type:",
            snapshot_or_error.pageType
        )
    elseif snapshot_or_error.detail then
        logger.warn(
            "BookRoom: chapter unavailable:",
            snapshot_or_error.reason,
            snapshot_or_error.detail
        )
    end

    return snapshot_or_error
end

function BookRoom:chapterMenuText(snapshot)
    if snapshot.status == "ok" then
        return _("Current chapter:") .. " " .. snapshot.title
    end
    if snapshot.reason == "no_toc_entry" then
        return _("Current chapter: no TOC entry at this position")
    end
    if snapshot.reason == "reader_unavailable" or snapshot.reason == "current_page_unavailable" then
        return _("Current chapter: open a supported book first")
    end
    if snapshot.reason == "unsupported_api" then
        return _("Current chapter: unsupported KOReader API")
    end
    return _("Current chapter: temporarily unavailable")
end

function BookRoom:showCurrentChapter()
    local snapshot = self:getChapterSnapshot()
    local ok, err = pcall(function()
        UIManager:show(InfoMessage:new{
            text = self:chapterMenuText(snapshot),
        })
    end)
    if not ok then
        logger.warn("BookRoom: unable to show current chapter:", err)
    end
end

function BookRoom:getTocReport()
    local load_ok, toc, module_error = pcall(self.loadTocModule, self)
    if not load_ok then
        return {
            status = "unavailable",
            reason = "plugin_error",
            detail = tostring(toc),
        }
    end
    if not toc then
        return {
            status = "unavailable",
            reason = "plugin_error",
            detail = module_error,
        }
    end

    local inspect_ok, report_or_error = pcall(toc.inspect, self.ui)
    if inspect_ok and type(report_or_error) == "table" then
        return report_or_error
    end
    return {
        status = "unavailable",
        reason = "plugin_error",
        detail = inspect_ok and "invalid TOC report" or tostring(report_or_error),
    }
end

function BookRoom:showTocDiagnostics()
    -- Keep the proven Step 3 extractor as the source of the displayed current
    -- chapter while inspecting and normalizing the full TOC independently.
    local chapter_snapshot = self:getChapterSnapshot()
    local chapter_text = self:chapterMenuText(chapter_snapshot)

    local report = self:getTocReport()
    local toc = self.toc_module

    local text
    if type(toc) == "table" and type(toc.formatDiagnostics) == "function" then
        local format_ok, text_or_error = pcall(toc.formatDiagnostics, report, chapter_text)
        text = format_ok and text_or_error or nil
        if not format_ok then
            logger.warn("BookRoom: unable to format TOC diagnostics:", text_or_error)
        end
    end
    text = text or (chapter_text .. "\n\nTOC diagnostics unavailable: plugin_error")

    local show_ok, show_error = pcall(function()
        UIManager:show(TextViewer:new{
            title = _("Book Room TOC diagnostics"),
            text = text,
            text_type = "code",
        })
    end)
    if not show_ok then
        logger.warn("BookRoom: unable to show TOC diagnostics:", show_error)
        pcall(function()
            UIManager:show(InfoMessage:new{ text = chapter_text })
        end)
    end
end

function BookRoom:showMessage(text)
    local show_ok = pcall(function()
        UIManager:show(InfoMessage:new{ text = text, timeout = 4 })
    end)
    if not show_ok then logger.warn("BookRoom: unable to show status") end
end

function BookRoom:captureObservation(settings, report)
    report = report or self:getTocReport()
    if type(report) ~= "table" or report.status ~= "ok"
        or type(report.currentEntry) ~= "table" then
        return nil, "chapter_unavailable"
    end

    local document_module = self:loadDocumentModule()
    if not document_module then return nil, "document_module_unavailable" end
    local document = document_module.capture(self.ui, settings)
    if type(document) ~= "table" or document.status ~= "ok" then
        return nil, type(document) == "table"
            and document.reason or "document_unavailable"
    end

    local entry = report.currentEntry
    return {
        document = document,
        entry = entry,
        payload = {
            version = 1,
            document = document.document,
            device = document.device,
            deviceId = document.deviceId,
            progress = document.progress,
            percentage = document.percentage,
            chapter = {
                title = entry.title,
                tocIndex = entry.index,
                depth = entry.depth,
                parentIndex = entry.parentIndex,
                sequenceInLevel = entry.sequenceInLevel,
                path = entry.path,
                page = entry.page,
                location = entry.location,
            },
            toc = {
                entries = report.entries,
            },
        },
    }
end

function BookRoom:isOnline()
    if type(NetworkMgr) ~= "table" or type(NetworkMgr.isOnline) ~= "function" then
        return false
    end
    local ok, online = pcall(NetworkMgr.isOnline, NetworkMgr)
    return ok and online == true
end

function BookRoom:sendAutomaticPayload(settings, payload, callback)
    local client = self:loadClientModule()
    if not client then
        if type(callback) == "function" then
            pcall(callback, { ok = false, reason = "plugin_error" })
        end
        return { started = false, reason = "plugin_error", callbackInvoked = true }
    end

    local send_ok, operation = pcall(
        client.send,
        payload,
        settings.username,
        settings.userkey,
        function(send_result)
            if type(send_result) == "table" and send_result.ok then
                logger.info(
                    "BookRoom: automatic chapter observation sent; document:",
                    payload.document,
                    "chapter:",
                    payload.chapter.title
                )
            else
                logger.warn(
                    "BookRoom: automatic chapter observation retained; document:",
                    payload.document,
                    "chapter:",
                    payload.chapter.title
                )
            end
            if type(callback) == "function" then pcall(callback, send_result) end
        end
    )
    if send_ok and type(operation) == "table" then return operation end
    if type(callback) == "function" then
        pcall(callback, { ok = false, reason = "network_failure" })
    end
    return { started = false, reason = "network_failure", callbackInvoked = true }
end

function BookRoom:observeChapterChange()
    local ok, err = pcall(function()
        local observer = self:getObserver()
        local credentials = self:loadCredentialsModule()
        if not observer or not credentials
            or type(credentials.withConnection) ~= "function" then
            return
        end

        credentials.withConnection(function(settings)
            local observation = self:captureObservation(settings)
            if not observation then return end
            observer:observe(
                settings.username,
                observation.document.document,
                observation.entry,
                observation.payload,
                function() return self:isOnline() end,
                function(payload, callback)
                    return self:sendAutomaticPayload(settings, payload, callback)
                end
            )
        end)
    end)
    if not ok then
        logger.warn("BookRoom: automatic chapter observation failed safely:", tostring(err))
    end
end

function BookRoom:flushPendingObservations()
    local ok, err = pcall(function()
        if not self:isOnline() then return end
        local observer = self:getObserver()
        local credentials = self:loadCredentialsModule()
        if not observer or not credentials
            or type(credentials.withConnection) ~= "function" then
            return
        end

        credentials.withConnection(function(settings)
            observer:flush(
                settings.username,
                true,
                function(payload, callback)
                    return self:sendAutomaticPayload(settings, payload, callback)
                end
            )
        end)
    end)
    if not ok then
        logger.warn("BookRoom: pending chapter flush failed safely:", tostring(err))
    end
end

function BookRoom:scheduleChapterObservation()
    if self.observation_scheduled then return end
    self.observation_scheduled = true
    if type(UIManager.nextTick) == "function" then
        local ok = pcall(UIManager.nextTick, UIManager, self.observation_task)
        if ok then return end
    end
    self.observation_task()
end

function BookRoom:onReaderReady()
    self:scheduleChapterObservation()
end

function BookRoom:onPageUpdate()
    self:scheduleChapterObservation()
end

function BookRoom:onPosUpdate()
    self:scheduleChapterObservation()
end

function BookRoom:onNetworkConnected()
    if self.reconnect_scheduled then return end
    self.reconnect_scheduled = true
    if type(UIManager.scheduleIn) == "function" then
        local ok = pcall(UIManager.scheduleIn, UIManager, 0.5, self.reconnect_task)
        if ok then return end
    end
    self.reconnect_task()
end

function BookRoom:onCloseWidget()
    if type(UIManager.unschedule) == "function" then
        pcall(UIManager.unschedule, UIManager, self.observation_task)
        pcall(UIManager.unschedule, UIManager, self.reconnect_task)
    end
    self.observation_scheduled = false
    self.reconnect_scheduled = false
end

function BookRoom:canSendChapter()
    local chapter = self:getChapterSnapshot()
    if chapter.status ~= "ok" then return false end

    local report = self:getTocReport()
    if report.status ~= "ok" or type(report.currentEntry) ~= "table" then
        return false
    end

    local load_ok, credentials = pcall(self.loadCredentialsModule, self)
    if not load_ok or not credentials then return false end
    local read_ok, status = pcall(credentials.read)
    return read_ok and type(status) == "table" and status.connected == true
end

function BookRoom:showSendResult(send_result, chapter_title, document)
    if type(send_result) == "table" and send_result.ok then
        logger.info(
            "BookRoom: manual chapter send succeeded; document:",
            document,
            "chapter:",
            chapter_title,
            "status:",
            send_result.status
        )
        self:showMessage(table.concat({
            _("Chapter synced with Book Room."),
            "",
            chapter_title,
            _("Document:") .. " " .. document,
        }, "\n"))
        return
    end

    local reason = type(send_result) == "table" and send_result.reason or "network_failure"
    local status = type(send_result) == "table" and send_result.status or nil
    logger.warn(
        "BookRoom: manual chapter send failed; document:",
        document,
        "chapter:",
        chapter_title,
        "status:",
        status or "unavailable"
    )
    if reason == "invalid_credentials" then
        self:showMessage(table.concat({
            _("Book Room credentials are no longer valid."),
            _("Reconnect KOReader progress sync."),
        }, "\n"))
    elseif reason == "network_failure" then
        local lines = {
            _("Could not reach Book Room."),
            _("Your reading was not interrupted."),
        }
        if type(send_result) == "table" and send_result.transportCode then
            table.insert(lines, _("Transport code:") .. " " .. tostring(send_result.transportCode))
        end
        self:showMessage(table.concat(lines, "\n"))
    elseif reason == "encoding_failure" then
        self:showMessage(table.concat({
            _("Book Room could not prepare this chapter update."),
            _("Diagnostic:") .. " encoding_failure",
        }, "\n"))
    elseif reason == "plugin_error" then
        local diagnostic = type(send_result) == "table"
            and send_result.transportCode or "plugin_error"
        self:showMessage(table.concat({
            _("Book Room could not prepare this chapter update."),
            _("Diagnostic:") .. " " .. tostring(diagnostic),
        }, "\n"))
    else
        local lines = { _("Book Room could not accept this chapter update.") }
        if status then
            table.insert(lines, _("HTTP status:") .. " " .. tostring(status))
        end
        self:showMessage(table.concat(lines, "\n"))
    end
end

function BookRoom:sendChapterNow()
    local action_ok, action_error = pcall(function()
        local chapter = self:getChapterSnapshot()
        if chapter.status ~= "ok" then
            self:showMessage(_("Current chapter is unavailable."))
            return
        end

        local report = self:getTocReport()
        if report.status ~= "ok" or type(report.currentEntry) ~= "table" then
            self:showMessage(_("Current chapter is unavailable."))
            return
        end

        local credentials = self:loadCredentialsModule()
        if not credentials or type(credentials.withConnection) ~= "function" then
            self:showMessage(_("Book Room sync is not connected."))
            return
        end

        local connection_status, operation = credentials.withConnection(function(settings)
            local client, client_error = self:loadClientModule()
            if not client then
                self:showMessage(table.concat({
                    _("Book Room could not prepare this chapter update."),
                    _("Diagnostic:") .. " " .. tostring(client_error or "client_module_error"),
                }, "\n"))
                return { started = false, reason = "plugin_error", callbackInvoked = true }
            end

            local observation, observation_error = self:captureObservation(settings, report)
            if not observation then
                self:showMessage(table.concat({
                    _("Book Room could not identify this document for sync."),
                    _("Diagnostic:") .. " " .. tostring(observation_error),
                }, "\n"))
                return { started = false, reason = "document_unavailable", callbackInvoked = true }
            end

            local document = observation.document
            local entry = observation.entry
            local payload = observation.payload

            if NetworkMgr:willRerunWhenOnline(function()
                self:sendChapterNow()
            end) then
                return { started = false, reason = "waiting_for_network" }
            end

            local started = client.send(
                payload,
                settings.username,
                settings.userkey,
                function(send_result)
                    if type(send_result) == "table" and send_result.ok then
                        local observer = self:getObserver()
                        if observer then
                            pcall(
                                observer.recordSuccessful,
                                observer,
                                settings.username,
                                document.document,
                                entry
                            )
                        end
                    end
                    self:showSendResult(
                        send_result,
                        entry.title,
                        document.document
                    )
                end
            )
            if type(started) == "table" and started.started then
                logger.info(
                    "BookRoom: manual chapter send started; document:",
                    document.document,
                    "chapter:",
                    entry.title
                )
            end
            return started
        end)

        if type(connection_status) ~= "table" or not connection_status.connected then
            self:showMessage(_("Book Room sync is not connected."))
        elseif type(operation) ~= "table" then
            self:showMessage(_("Could not reach Book Room.") .. "\n" .. _("Your reading was not interrupted."))
        elseif not operation.started and operation.reason ~= "waiting_for_network"
            and not operation.callbackInvoked then
            if operation.reason == "network_failure" then
                self:showMessage(_("Could not reach Book Room.") .. "\n" .. _("Your reading was not interrupted."))
            else
                self:showMessage(_("Book Room could not accept this chapter update."))
            end
        end
    end)

    if not action_ok then
        logger.warn("BookRoom: manual chapter send failed safely:", tostring(action_error))
        self:showMessage(_("Could not reach Book Room.") .. "\n" .. _("Your reading was not interrupted."))
    end
end

function BookRoom:showSyncStatus()
    local status_text = _("Book Room sync") .. "\n" .. _("Not connected")
    local load_ok, credentials = pcall(self.loadCredentialsModule, self)
    if load_ok and credentials then
        local read_ok, status = pcall(credentials.read)
        if read_ok then
            local format_ok, formatted = pcall(credentials.formatStatus, status)
            if format_ok and type(formatted) == "string" then
                status_text = formatted
            end
        end
    end

    local show_ok = pcall(function()
        UIManager:show(InfoMessage:new{ text = status_text })
    end)
    if not show_ok then
        logger.warn("BookRoom: unable to show sync status")
    end
end

function BookRoom:addToMainMenu(menu_items)
    menu_items.bookroom = {
        text = _("Book Room"),
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text_func = function()
                    return self:chapterMenuText(self:getChapterSnapshot())
                end,
                callback = function()
                    self:showCurrentChapter()
                end,
            },
            {
                text = _("Book Room sync status"),
                callback = function()
                    self:showSyncStatus()
                end,
            },
            {
                text = _("Send chapter now"),
                enabled_func = function()
                    return self:canSendChapter()
                end,
                callback = function()
                    self:sendChapterNow()
                end,
            },
            {
                text = _("TOC diagnostics (temporary)"),
                callback = function()
                    self:showTocDiagnostics()
                end,
            },
        },
    }
end

return BookRoom
