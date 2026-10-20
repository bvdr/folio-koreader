--[[--
Folio for KOReader.

Pairs with a Folio account by device code (myfolio.so/link), downloads
finished issues into a "Folio" folder, lets you build an issue from your
inbox, and adds a "Save to Folio inbox" button to the link dialog.

Server side: web/src/routes/device-link.ts in the Folio repo.

@module koplugin.folio
]]

local DataStorage = require("datastorage")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local JSON = require("json")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local http = require("socket.http")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local T = require("ffi/util").template
local _ = require("gettext")

local DEFAULT_SERVER = "https://myfolio.so"
-- Give up polling for a freshly made issue after this long; the next sync
-- (or Wi-Fi reconnect) picks it up anyway.
local ISSUE_POLL_SECONDS = 15
local ISSUE_POLL_MAX_TRIES = 40

local Folio = WidgetContainer:extend{
    name = "folio",
    is_doc_only = false,
}

function Folio:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/folio.lua")
    self.ui.menu:registerToMainMenu(self)
    if self.ui.link then
        self.ui.link:addToExternalLinkDialog("30_folio", function(this, link_url)
            return {
                text = _("Save to Folio inbox"),
                callback = function()
                    UIManager:close(this.external_link_dialog)
                    self:saveLink(link_url)
                end,
                show_in_dialog_func = function() return self:token() ~= nil end,
            }
        end)
    end
end

-- ─── settings ────────────────────────────────────────────────────────────────

function Folio:server() return self.settings:readSetting("server") or DEFAULT_SERVER end
function Folio:token() return self.settings:readSetting("token") end
function Folio:autoSync() return self.settings:nilOrTrue("auto_sync") end

function Folio:downloadDir()
    local dir = self.settings:readSetting("dir")
    if dir then return dir end
    local home = G_reader_settings:readSetting("home_dir") or Device.home_dir or DataStorage:getDataDir()
    return home .. "/Folio"
end

-- issue id (string) → local file path. String keys: LuaSettings round-trips them reliably.
function Folio:downloaded() return self.settings:readSetting("downloaded") or {} end

function Folio:save(key, value)
    self.settings:saveSetting(key, value)
    self.settings:flush()
end

-- ─── http ────────────────────────────────────────────────────────────────────

--- One request to the Folio server. Returns (status_code, decoded_json_or_nil, headers).
-- status_code is nil on a network error. With `filepath`, the body streams to that file.
function Folio:request(method, path, body, filepath)
    local sink = {}
    local headers = { ["Accept"] = "application/json" }
    local token = self:token()
    if token then headers["Authorization"] = "Bearer " .. token end
    local source
    if body then
        local payload = JSON.encode(body)
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = tostring(#payload)
        source = ltn12.source.string(payload)
    end
    local file
    if filepath then
        file = io.open(filepath, "wb")
        if not file then return nil end
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    else
        socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    end
    local code, resp_headers, status = socket.skip(1, http.request{
        url = self:server() .. path,
        method = method,
        headers = headers,
        source = source,
        sink = file and ltn12.sink.file(file) or ltn12.sink.table(sink),
    })
    socketutil:reset_timeout()
    if resp_headers == nil then
        logger.warn("Folio: network error", method, path, status or code)
        return nil
    end
    if code == 401 and token then
        -- Session revoked or expired: drop it so the menu offers Connect again.
        self:save("token", nil)
    end
    local data
    if not filepath then
        local ok, decoded = pcall(JSON.decode, table.concat(sink))
        if ok then data = decoded end
    end
    return code, data, resp_headers
end

local function toast(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout })
end

-- Show a "working…" note while a blocking request runs.
local function busy(text, fn)
    local note = InfoMessage:new{ text = text }
    UIManager:show(note)
    UIManager:forceRePaint()
    local ok, err = pcall(fn)
    UIManager:close(note)
    if not ok then
        logger.err("Folio:", err)
        toast(_("Something went wrong. Try again in a moment."))
    end
end

local NETWORK_ERROR = _("Couldn't reach Folio. Check your Wi-Fi and try again.")

-- ─── connect ─────────────────────────────────────────────────────────────────

function Folio:connect()
    NetworkMgr:runWhenOnline(function()
        local code, data = self:request("POST", "/api/auth/device/code", {})
        if code ~= 200 or not data then
            toast(code and _("Folio couldn't start pairing. Try again in a minute.") or NETWORK_ERROR)
            return
        end
        local pretty = data.user_code:sub(1, 3) .. "–" .. data.user_code:sub(4)
        local host = (data.verification_uri or ""):gsub("^https?://", "")
        local dialog
        local cancelled = false
        dialog = InfoMessage:new{
            text = T(_("Connect this reader\n\n1. On your phone or computer, open %1\n\n2. Enter this code:\n\n%2\n\nNew issues will download here on their own. Tap to cancel."), host, pretty),
            dismiss_callback = function() cancelled = true end,
        }
        UIManager:show(dialog)

        local deadline = os.time() + (data.expires_in or 600)
        local function poll()
            if cancelled then return end
            if os.time() > deadline then
                UIManager:close(dialog)
                toast(_("That code expired. Choose Connect to get a new one."))
                return
            end
            local c, d = self:request("POST", "/api/auth/device/token", { device_code = data.device_code })
            if c == 200 and d and d.token then
                cancelled = true
                UIManager:close(dialog)
                self:save("token", d.token)
                toast(_("Connected to Folio."), 3)
                self:sync(true)
            elseif c == nil or (d and d.error == "authorization_pending") then
                UIManager:scheduleIn(data.interval or 5, poll)
            else
                UIManager:close(dialog)
                toast(_("That code expired. Choose Connect to get a new one."))
            end
        end
        UIManager:scheduleIn(data.interval or 5, poll)
    end)
end

function Folio:disconnect()
    NetworkMgr:runWhenOnline(function()
        -- Best effort: even if the server is unreachable, forget the token locally.
        self:request("POST", "/api/auth/device/logout", {})
        self:save("token", nil)
        toast(_("Disconnected from Folio. Downloaded issues stay on this reader."))
    end)
end

-- ─── issues ──────────────────────────────────────────────────────────────────

local function issueName(issue)
    local n = issue.issue_number and T(_("Issue #%1"), issue.issue_number) or _("Issue")
    if issue.title and issue.title ~= "" then return issue.title .. " · " .. n end
    return n
end

--- Download one issue. Prefers the EPUB (reflows on any screen), falls back
-- to whatever render exists. Returns the local path or nil.
function Folio:downloadIssue(issue)
    local dir = self:downloadDir()
    lfs.mkdir(dir)
    local tmp = dir .. "/.folio-download"
    for __, query in ipairs({ "?format=kindle", "" }) do
        local code, __, headers = self:request("GET", "/library/issues/" .. issue.id .. "/download" .. query, nil, tmp)
        -- A paywalled account gets redirected to the /plans HTML page, which
        -- http.request follows; only keep real book files.
        local ctype = headers and headers["content-type"] or ""
        if code == 200 and (ctype:find("epub", 1, true) or ctype:find("pdf", 1, true)) then
            local cd = headers and headers["content-disposition"] or ""
            local name = cd:match('filename="([^"]+)"') or (issueName(issue) .. ".epub")
            name = name:gsub("[/\\:*?\"<>|]", "-")
            local path = dir .. "/" .. name
            os.remove(path)
            os.rename(tmp, path)
            local downloaded = self:downloaded()
            downloaded[tostring(issue.id)] = path
            self:save("downloaded", downloaded)
            return path
        end
        os.remove(tmp)
        if code == nil then return nil end
    end
end

function Folio:fetchIssues()
    local code, data = self:request("GET", "/api/generations")
    if code ~= 200 or type(data) ~= "table" then return nil, code end
    local done = {}
    for __, issue in ipairs(data) do
        if issue.status == "completed" then table.insert(done, issue) end
    end
    return done
end

--- Download every finished issue not on this reader yet.
-- quiet: only speak up when something new arrived (auto-sync on Wi-Fi).
function Folio:sync(quiet)
    if not self:token() or self.syncing then return end
    self.syncing = true
    local run = function()
        local issues, code = self:fetchIssues()
        if not issues then
            if not quiet then toast(code and _("Folio couldn't list your issues.") or NETWORK_ERROR) end
            return
        end
        local have, got = self:downloaded(), 0
        for __, issue in ipairs(issues) do
            local path = have[tostring(issue.id)]
            if not (path and lfs.attributes(path, "mode") == "file") and self:downloadIssue(issue) then
                got = got + 1
            end
        end
        if got > 0 then
            toast(T(_("%1 new Folio issue(s) in your %2 folder."), got, "Folio"), 4)
            local FileManager = require("apps/filemanager/filemanager")
            if FileManager.instance then FileManager.instance:onRefresh() end
        elseif not quiet then
            toast(_("You're up to date."), 2)
        end
    end
    if quiet then
        local ok, err = pcall(run)
        if not ok then logger.err("Folio sync:", err) end
    else
        busy(_("Checking Folio for new issues…"), run)
    end
    self.syncing = false
end

function Folio:openFile(path)
    local ReaderUI = require("apps/reader/readerui")
    ReaderUI:showReader(path)
end

function Folio:showIssues()
    NetworkMgr:runWhenOnline(function()
        local issues, code
        busy(_("Loading your issues…"), function() issues, code = self:fetchIssues() end)
        if not issues then
            toast(code and _("Folio couldn't list your issues.") or NETWORK_ERROR)
            return
        end
        if #issues == 0 then
            toast(_("No issues yet. Make one from your inbox, or set a schedule at myfolio.so."))
            return
        end
        local menu
        local items = {}
        local have = self:downloaded()
        for __, issue in ipairs(issues) do
            local path = have[tostring(issue.id)]
            local local_ok = path and lfs.attributes(path, "mode") == "file"
            table.insert(items, {
                text = issueName(issue),
                mandatory = local_ok and _("On reader") or "",
                callback = function()
                    UIManager:close(menu)
                    if not local_ok then
                        busy(_("Downloading…"), function() path = self:downloadIssue(issue) end)
                    end
                    if path then self:openFile(path) else toast(_("That issue couldn't be downloaded.")) end
                end,
            })
        end
        menu = Menu:new{ title = _("Folio issues"), item_table = items, is_popout = false, is_borderless = true }
        UIManager:show(menu)
    end)
end

-- ─── inbox ───────────────────────────────────────────────────────────────────

--- Poll a freshly made issue and download it the moment it's ready.
function Folio:waitForIssue(id, tries)
    tries = tries or 0
    if tries >= ISSUE_POLL_MAX_TRIES then return end
    UIManager:scheduleIn(ISSUE_POLL_SECONDS, function()
        local code, gen = self:request("GET", "/api/generations/" .. id)
        if code == 200 and gen and gen.status == "completed" then
            self:sync(true)
        elseif code == 200 and gen and gen.status == "failed" then
            toast(_("Folio couldn't make that issue. Try again from the app."))
        else
            self:waitForIssue(id, tries + 1)
        end
    end)
end

function Folio:makeIssue(ids)
    local code, data
    busy(_("Making your issue…"), function() code, data = self:request("POST", "/api/generate", { articleIds = ids }) end)
    if code == 200 and data and data.id then
        toast(T(_("Issue #%1 is on its way. It will download here when it's ready, usually in a minute or two."), data.issueNumber or ""), 5)
        self:waitForIssue(data.id)
    elseif code == 402 and data and data.error == "paywall_locked" then
        toast(_("Making issues needs an active Folio plan. See myfolio.so/plans."))
    elseif code == 402 then
        toast(_("You've reached this month's issue limit. Upgrade at myfolio.so/plans."))
    else
        toast(code and (data and data.error or _("Folio couldn't make that issue.")) or NETWORK_ERROR)
    end
end

function Folio:showInbox()
    NetworkMgr:runWhenOnline(function()
        local code, data
        busy(_("Loading your inbox…"), function() code, data = self:request("GET", "/api/articles?status=inbox&limit=100") end)
        if code ~= 200 or not data or not data.articles then
            toast(code and _("Folio couldn't load your inbox.") or NETWORK_ERROR)
            return
        end
        local selected, menu = {}, nil
        local function build()
            local ids = {}
            for id in pairs(selected) do table.insert(ids, id) end
            local items = {
                {
                    text = #ids > 0 and T(_("Make an issue from %1 article(s)"), #ids) or _("Tap articles to pick them"),
                    bold = true,
                    callback = function()
                        if #ids == 0 then return end
                        UIManager:close(menu)
                        self:makeIssue(ids)
                    end,
                },
                { text = _("Add a link…"), callback = function() self:promptLink() end, separator = true },
            }
            for __, a in ipairs(data.articles) do
                local ready = a.scrape_status == "done"
                table.insert(items, {
                    text = (selected[a.id] and "☑ " or "☐ ") .. (a.title or a.url or "?"),
                    mandatory = not ready and _("loading") or (a.read_time_minutes and T(_("%1 min"), a.read_time_minutes)) or "",
                    dim = not ready,
                    callback = function()
                        if not ready then return end
                        selected[a.id] = (not selected[a.id]) or nil
                        menu:switchItemTable(nil, build())
                    end,
                })
            end
            return items
        end
        menu = Menu:new{
            title = T(_("Inbox · %1 articles"), data.total or #data.articles),
            item_table = build(),
            is_popout = false,
            is_borderless = true,
        }
        UIManager:show(menu)
    end)
end

function Folio:saveLink(url)
    NetworkMgr:runWhenOnline(function()
        local code, data
        busy(_("Saving to Folio…"), function() code, data = self:request("POST", "/api/articles", { url = url }) end)
        if code and code >= 200 and code < 300 then
            toast(_("Saved to your Folio inbox."), 2)
        else
            toast(code and (data and data.error or _("Folio couldn't save that link.")) or NETWORK_ERROR)
        end
    end)
end

function Folio:promptLink()
    local dialog
    dialog = InputDialog:new{
        title = _("Add a link to your Folio inbox"),
        input_hint = "https://",
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Add"), is_enter_default = true, callback = function()
                local url = dialog:getInputText()
                UIManager:close(dialog)
                if url and url:match("^https?://") then self:saveLink(url) else toast(_("That doesn't look like a web link.")) end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- ─── settings ────────────────────────────────────────────────────────────────

function Folio:promptServer()
    local dialog
    dialog = InputDialog:new{
        title = _("Folio server"),
        description = _("Leave this as myfolio.so unless you were asked to change it."),
        input = self:server(),
        buttons = {{
            { text = _("Reset"), callback = function() UIManager:close(dialog); self:save("server", nil) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local url = (dialog:getInputText() or ""):gsub("/+$", "")
                UIManager:close(dialog)
                if url:match("^https://") then
                    -- A token belongs to one server; switching means re-pairing.
                    if url ~= self:server() then self:save("token", nil) end
                    self:save("server", url)
                else
                    toast(_("The server must start with https://"))
                end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- ─── menu ────────────────────────────────────────────────────────────────────

function Folio:addToMainMenu(menu_items)
    menu_items.folio = {
        text = _("Folio"),
        sorting_hint = "tools",
        sub_item_table_func = function()
            if not self:token() then
                return {
                    { text = _("Connect to Folio"), callback = function() self:connect() end },
                    { text = _("Server"), keep_menu_open = true, callback = function() self:promptServer() end },
                }
            end
            return {
                { text = _("Issues"), callback = function() self:showIssues() end },
                { text = _("Inbox"), callback = function() self:showInbox() end },
                { text = _("Check for new issues"), callback = function()
                    NetworkMgr:runWhenOnline(function() self:sync(false) end)
                end, separator = true },
                { text = _("Download new issues on Wi-Fi"),
                  checked_func = function() return self:autoSync() end,
                  callback = function() self:save("auto_sync", not self:autoSync()) end },
                { text_func = function() return T(_("Folder: %1"), self:downloadDir()) end,
                  keep_menu_open = true,
                  callback = function()
                      local PathChooser = require("ui/widget/pathchooser")
                      UIManager:show(PathChooser:new{
                          select_file = false,
                          path = self:downloadDir(),
                          onConfirm = function(path) self:save("dir", path) end,
                      })
                  end },
                { text = _("Server"), keep_menu_open = true, callback = function() self:promptServer() end },
                { text = _("Disconnect"), callback = function() self:disconnect() end },
            }
        end,
    }
end

-- KOReader broadcasts this when Wi-Fi comes up (and once at start if it's already up).
function Folio:onNetworkConnected()
    if self:token() and self:autoSync() then
        UIManager:nextTick(function() self:sync(true) end)
    end
end

return Folio
