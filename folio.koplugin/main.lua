--[[--
Folio for KOReader.

Pairs with a Folio account by device code (myfolio.so/link), downloads
finished issues into a "Folio" folder, lets you build an issue from your
inbox, shows your highlights, and adds a "Save to Folio inbox" button to
the link dialog. The screens live in folioui.lua.

Server side: web/src/routes/device-link.ts in the Folio repo.

@module koplugin.folio
]]

local DataStorage = require("datastorage")
local Device = require("device")
local DocSettings = require("docsettings")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local JSON = require("json")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local http = require("socket.http")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local T = require("ffi/util").template
local _ = require("gettext")
local Screen = Device.screen

local UI = require("folioui")

local VERSION = "0.2.6"
local DEFAULT_SERVER = "https://myfolio.so"
-- Give up polling for a freshly made issue after this long; the next sync
-- (or Wi-Fi reconnect) picks it up anyway.
local ISSUE_POLL_SECONDS = 15
local ISSUE_POLL_MAX_TRIES = 40
-- Article to jump to when the reader opens. Module-level because the reader
-- gets its own plugin instance, separate from the file browser's.
local pending_chapter
-- Folio tab to reopen when the reader closes (after an inbox preview), so
-- Back lands where the user was. Module-level for the same reason.
local reopen_tab

local Folio = WidgetContainer:extend{
    name = "folio",
    is_doc_only = false,
    version = VERSION,
}

function Folio:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/folio.lua")
    self.ui.menu:registerToMainMenu(self)
    if reopen_tab and not self.ui.document then
        local tab = reopen_tab
        reopen_tab = nil
        UIManager:nextTick(function()
            -- Home from a preview opens the browser in the preview cache folder;
            -- point it back at the Folio folder underneath.
            if self.ui.file_chooser and lfs.attributes(self:downloadDir(), "mode") == "directory" then
                self.ui.file_chooser:changeToPath(self:downloadDir())
            end
            self:showFolio(tab)
        end)
    end
    if self.ui.link then
        self.ui.link:addToExternalLinkDialog("30_folio", function(this, link_url)
            return {
                text = _("Save to Folio inbox"),
                callback = function()
                    UIManager:close(this.external_link_dialog)
                    self:showSaveLink(link_url)
                end,
                show_in_dialog_func = function() return self:token() ~= nil and self:linkButton() end,
            }
        end)
    end
end

-- ─── settings ────────────────────────────────────────────────────────────────

function Folio:server() return self.settings:readSetting("server") or DEFAULT_SERVER end
function Folio:token() return self.settings:readSetting("token") end
function Folio:autoSync() return self.settings:nilOrTrue("auto_sync") end
function Folio:linkButton() return self.settings:nilOrTrue("link_button") end
function Folio:preferPdf() return self.settings:isTrue("prefer_pdf") end

function Folio:downloadDir()
    local dir = self.settings:readSetting("dir")
    if dir then return dir end
    local home = G_reader_settings:readSetting("home_dir") or Device.home_dir or DataStorage:getDataDir()
    return home .. "/Folio"
end

--- "Books / Folio": the last two parts of the folder, like the design shows.
function Folio:folderLabel()
    local parts = {}
    for p in self:downloadDir():gmatch("[^/]+") do table.insert(parts, p) end
    return table.concat({ parts[#parts - 1], parts[#parts] }, " / ")
end

-- issue id (string) → { path = ..., format = ... }. String keys: LuaSettings round-trips them reliably.
function Folio:downloaded() return self.settings:readSetting("downloaded") or {} end

function Folio:localPath(issue)
    local d = self:downloaded()[tostring(issue.id)]
    local path = type(d) == "table" and d.path or d
    if path and lfs.attributes(path, "mode") == "file" then return path end
end

function Folio:localFormat(issue)
    local d = self:downloaded()[tostring(issue.id)]
    return type(d) == "table" and d.format or (d and "kindle") or nil
end

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
        -- Session revoked or expired: drop it so Folio shows Connect again.
        self:save("token", nil)
    end
    local data
    if not filepath then
        -- .simple: JSON null → nil (the default decodes null to a function, which
        -- breaks every `x or default` and `if x then` on server fields).
        local ok, decoded = pcall(JSON.decode, table.concat(sink), JSON.decode.simple)
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

-- ─── pairing ─────────────────────────────────────────────────────────────────

-- KOReader knows Kobos by codename; Settings on myfolio.so shows this name.
-- From KOReader's frontend/device/kobo/device.lua. Unknown models fall back
-- to the platform ("Kobo", "PocketBook", ...).
local KOBO_NAMES = {
    Kobo_nova = "Kobo Clara HD", Kobo_frost = "Kobo Forma", Kobo_storm = "Kobo Libra H2O",
    Kobo_luna = "Kobo Nia", Kobo_europa = "Kobo Elipsa", Kobo_cadmus = "Kobo Sage",
    Kobo_io = "Kobo Libra 2", Kobo_goldfinch = "Kobo Clara 2E", Kobo_condor = "Kobo Elipsa 2E",
    Kobo_monza = "Kobo Libra Colour", Kobo_spaBW = "Kobo Clara BW", Kobo_spaColour = "Kobo Clara Colour",
}

--- A human name for this reader, e.g. "Kobo Libra Colour".
function Folio:deviceName()
    local model = Device.model or ""
    if KOBO_NAMES[model] then return KOBO_NAMES[model] end
    local checks = {
        { "isKobo", "Kobo" }, { "isPocketBook", "PocketBook" }, { "isKindle", "Kindle" },
        { "isRemarkable", "reMarkable" }, { "isCervantes", "Cervantes" }, { "isAndroid", "Android reader" },
    }
    for __, c in ipairs(checks) do
        if Device[c[1]] and Device[c[1]]() then return c[2] end
    end
    return "KOReader"
end

--- Ask for a code and poll until the user approves it at /link.
-- Returns the pairing table; set .cancelled on it to stop polling.
function Folio:startPairing(on_update, on_done)
    local code, data = self:request("POST", "/api/auth/device/code", {})
    if code ~= 200 or not data then
        local failed = { error = code and _("Folio couldn't start pairing. Try again in a minute.") or NETWORK_ERROR }
        on_update(failed)
        return failed
    end
    local pairing = data
    local deadline = os.time() + (data.expires_in or 600)
    local function expired()
        pairing.user_code = nil
        pairing.error = _("That code expired. Close Folio and open it again for a new one.")
        on_update(pairing)
    end
    local function poll()
        if pairing.cancelled then return end
        if os.time() > deadline then return expired() end
        local c, d = self:request("POST", "/api/auth/device/token", { device_code = data.device_code, device_name = self:deviceName() })
        if c == 200 and d and d.token then
            self:save("token", d.token)
            self:save("connected_at", os.time())
            on_done()
        elseif c == nil or (d and d.error == "authorization_pending") then
            UIManager:scheduleIn(data.interval or 5, poll)
        else
            expired()
        end
    end
    UIManager:scheduleIn(data.interval or 5, poll)
    return pairing
end

function Folio:disconnect()
    -- Best effort: even if the server is unreachable, forget the token locally.
    self:request("POST", "/api/auth/device/logout", {})
    self:save("token", nil)
end

function Folio:showHelp()
    toast(_("Folio sends your reading to this reader.\n\nOn your phone, open the address shown here, sign in, and type the code. Issues then download on their own whenever Wi-Fi is on.\n\nNo account yet? Make one at myfolio.so."))
end

-- ─── issues ──────────────────────────────────────────────────────────────────

local function issueName(issue)
    local n = issue.issue_number and T(_("Issue #%1"), issue.issue_number) or _("Issue")
    if issue.title and issue.title ~= "" then return issue.title .. " · " .. n end
    return n
end

--- Download one issue in `format` (default: EPUB, or PDF if preferred).
-- Falls back to whatever render exists. Returns the local path or nil.
function Folio:downloadIssue(issue, format)
    local dir = self:downloadDir()
    lfs.mkdir(dir)
    local tmp = dir .. "/.folio-download"
    local wanted = format or (self:preferPdf() and "" or "kindle")
    local tries = wanted ~= "" and { "?format=" .. wanted, "" } or { "" }
    for __, query in ipairs(tries) do
        local code, __, headers = self:request("GET", "/library/issues/" .. issue.id .. "/download" .. query, nil, tmp)
        -- A paywalled account gets redirected to the /plans HTML page, which
        -- http.request follows; only keep real book files.
        local ctype = headers and headers["content-type"] or ""
        local is_epub = ctype:find("epub", 1, true) ~= nil
        if code == 200 and (is_epub or ctype:find("pdf", 1, true)) then
            local cd = headers["content-disposition"] or ""
            local name = cd:match('filename="([^"]+)"') or (issueName(issue) .. (is_epub and ".epub" or ".pdf"))
            name = name:gsub("[/\\:*?\"<>|]", "-")
            local path = dir .. "/" .. name
            local old = self:localPath(issue)
            if old and old ~= path then os.remove(old) end
            os.remove(path)
            os.rename(tmp, path)
            local downloaded = self:downloaded()
            downloaded[tostring(issue.id)] = { path = path, format = query:match("format=([%w-]+)") or (is_epub and "kindle" or "pdf"),
                number = issue.issue_number }
            self:save("downloaded", downloaded)
            return path
        end
        os.remove(tmp)
        if code == nil then return nil end
    end
end

-- Issues come 20 at a time; older ones load when the reader pages past the
-- end of the library. Someone with years of weekly issues shouldn't wait for
-- all of them on every open.
local ISSUE_PAGE = 20

--- One page of finished issues, newest first. Returns (issues, more) where
-- more says the server may have older ones; (nil, code) on failure.
function Folio:fetchIssues(offset)
    offset = offset or 0
    local code, data = self:request("GET", "/api/generations?limit=" .. ISSUE_PAGE .. "&offset=" .. offset)
    if code ~= 200 or type(data) ~= "table" then return nil, code end
    local done = {}
    for __, issue in ipairs(data) do
        if issue.status == "completed" then table.insert(done, issue) end
    end
    -- #data (all statuses) is what the next page's offset must skip.
    return done, #data == ISSUE_PAGE, #data
end

--- Cover image for an issue, cached on disk (a finished cover never changes).
-- The extension matters: KOReader picks the image decoder from it.
function Folio:coverPath(issue)
    local dir = DataStorage:getDataDir() .. "/cache/folio-covers"
    local base = dir .. "/" .. issue.id
    for __, ext in ipairs({ ".png", ".jpg" }) do
        if lfs.attributes(base .. ext, "mode") == "file" then return base .. ext end
    end
    if self.offline then return nil end
    lfs.mkdir(DataStorage:getDataDir() .. "/cache")
    lfs.mkdir(dir)
    local tmp = base .. ".part"
    local code, __, headers = self:request("GET", "/api/generations/" .. issue.id .. "/cover", nil, tmp)
    local ctype = headers and headers["content-type"] or ""
    if code == 200 and ctype:find("image", 1, true) then
        local path = base .. (ctype:find("png", 1, true) and ".png" or ".jpg")
        os.rename(tmp, path)
        return path
    end
    os.remove(tmp)
    if code == nil then self.offline = true end
end

--- How many of the newest issues to keep on the reader; nil means all.
-- Defaults to 8 (the design's default): a long-time user can have dozens of
-- issues at ~2 MB each, and downloading them all on first connect looked frozen.
function Folio:keepLatest()
    local v = self.settings:readSetting("keep_latest")
    if v == nil then return 8 end
    return v or nil
end

--- Download finished issues not on this reader yet, then tidy up.
-- Runs one download per UI tick so the screen stays usable while it works.
-- on_done(got, failed) runs at the end. Returns false if nothing was started.
function Folio:sync(on_done)
    if not self:token() or self.syncing then return false end
    local issues, code = self:fetchIssues()
    if not issues then
        if on_done then on_done(0, code and "list" or "network") end
        return false
    end
    self.syncing = true
    local keep = self:keepLatest()
    local queue = {}
    for i, issue in ipairs(issues) do
        if (not keep or i <= keep) and not self:localPath(issue) and not self:wasRemoved(issue) then
            table.insert(queue, issue)
        end
    end
    local got = 0
    local function step()
        local issue = table.remove(queue, 1)
        if issue then
            local ok, path = pcall(self.downloadIssue, self, issue)
            if ok and path then got = got + 1 elseif not ok then logger.err("Folio sync:", path) end
            UIManager:scheduleIn(0.2, step)
            return
        end
        self:tidy(issues)
        self:prunePreviews()
        self:save("last_sync", os.time())
        -- Cache categories for the save-link sheet, so it works offline later.
        local c, cats = self:request("GET", "/api/categories")
        if c == 200 and cats and cats.categories then
            local names = {}
            for __, cat in ipairs(cats.categories) do table.insert(names, cat.name) end
            self:save("categories", names)
        end
        if got > 0 then
            self:save("unseen_new", (self.settings:readSetting("unseen_new") or 0) + got)
            local FileManager = require("apps/filemanager/filemanager")
            if FileManager.instance then FileManager.instance:onRefresh() end
        end
        self.syncing = false
        if on_done then on_done(got) end
    end
    UIManager:nextTick(step)
    return true
end

--- Issues the plugin deleted on purpose are not downloaded again.
function Folio:wasRemoved(issue)
    return (self.settings:readSetting("removed") or {})[tostring(issue.id)]
end

--- Apply "Keep latest N" and "Delete finished issues".
function Folio:tidy(issues)
    local keep = self:keepLatest()
    local delete_finished = self.settings:isTrue("delete_finished")
    local downloaded, removed = self:downloaded(), self.settings:readSetting("removed") or {}
    for i, issue in ipairs(issues) do
        local path = self:localPath(issue)
        if path and ((keep and i > keep) or (delete_finished and UI.readState(path) == "complete")) then
            os.remove(path)
            DocSettings:open(path):purge()
            downloaded[tostring(issue.id)] = nil
            removed[tostring(issue.id)] = true
        end
    end
    self:save("downloaded", downloaded)
    self:save("removed", removed)
end

function Folio:openFile(path)
    local ReaderUI = require("apps/reader/readerui")
    ReaderUI:showReader(path)
end

-- ─── inbox ───────────────────────────────────────────────────────────────────

--- Poll a freshly made issue and download it the moment it's ready.
function Folio:waitForIssue(id, tries)
    tries = tries or 0
    if tries >= ISSUE_POLL_MAX_TRIES then return end
    UIManager:scheduleIn(ISSUE_POLL_SECONDS, function()
        local code, gen = self:request("GET", "/api/generations/" .. id)
        if code == 200 and gen and gen.status == "completed" then
            self:sync(function(got)
                if got > 0 then toast(_("Your new Folio issue is ready."), 4) end
                if self.view and not self.view.closed then self.view:reload() end
            end)
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
        return true
    elseif code == 402 and data and data.error == "paywall_locked" then
        toast(_("Making issues needs an active Folio plan. See myfolio.so/plans."))
    elseif code == 402 then
        toast(_("You've reached this month's issue limit. Upgrade at myfolio.so/plans."))
    else
        toast(code and (data and data.error or _("Folio couldn't make that issue.")) or NETWORK_ERROR)
    end
end

function Folio:saveLink(url, category)
    NetworkMgr:runWhenOnline(function()
        local code, data
        busy(_("Saving to Folio…"), function() code, data = self:request("POST", "/api/articles", { url = url, category = category }) end)
        if code and code >= 200 and code < 300 then
            toast(_("Saved to your Folio inbox."), 2)
        else
            toast(code and (data and data.error or _("Folio couldn't save that link.")) or NETWORK_ERROR)
        end
    end)
end

function Folio:showSaveLink(url)
    UIManager:show(UI.saveLinkSheet(self, url, function(w) UIManager:close(w) end))
end

function Folio:promptLink(after)
    local dialog
    dialog = InputDialog:new{
        title = _("Add a link to your Folio inbox"),
        input_hint = "https://",
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Add"), is_enter_default = true, callback = function()
                local url = dialog:getInputText()
                UIManager:close(dialog)
                if url and url:match("^https?://") then
                    self:saveLink(url)
                    if after then UIManager:scheduleIn(1, after) end
                else
                    toast(_("That doesn't look like a web link."))
                end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Folio:promptServer(after)
    local dialog
    dialog = InputDialog:new{
        title = _("Folio server"),
        description = _("Leave this as myfolio.so unless you were asked to change it."),
        input = self:server(),
        buttons = {{
            { text = _("Reset"), callback = function() UIManager:close(dialog); self:save("server", nil); if after then after() end end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local url = (dialog:getInputText() or ""):gsub("/+$", "")
                UIManager:close(dialog)
                if url:match("^https://") then
                    -- A token belongs to one server; switching means re-pairing.
                    if url ~= self:server() then self:save("token", nil) end
                    self:save("server", url)
                    if after then after() end
                else
                    toast(_("The server must start with https://"))
                end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- ─── inbox preview ───────────────────────────────────────────────────────────

local mime = require("mime")

--- Turn an inbox article into a local HTML file KOReader opens like a book.
-- Images are saved next to it (data: URIs decoded, remote ones downloaded)
-- so the preview works offline. Cached: the second open needs no network.
function Folio:previewPath(article)
    local dir = DataStorage:getDataDir() .. "/cache/folio-articles"
    -- "-v3": bump when the page template changes so cached previews are rebuilt.
    local path = dir .. "/" .. article.id .. "-v3.html"
    if lfs.attributes(path, "mode") == "file" then return path end
    lfs.mkdir(DataStorage:getDataDir() .. "/cache")
    lfs.mkdir(dir)
    local code, a = self:request("GET", "/api/articles/" .. article.id .. "/reader")
    if code ~= 200 or not a then return nil, code end

    local n = 0
    local function saveImage(src)
        n = n + 1
        if n > 30 then return nil end -- ponytail: cap per article; raise if long photo essays get cut
        local base = article.id .. "-" .. n
        local mimetype, b64 = src:match("^data:image/([%w+]+);base64,(.+)$")
        if b64 then
            local ext = mimetype:gsub("jpeg", "jpg"):gsub("%+xml", "")
            local f = io.open(dir .. "/" .. base .. "." .. ext, "wb")
            if not f then return nil end
            f:write((mime.unb64(b64)))
            f:close()
            return base .. "." .. ext
        end
        if src:match("^https?://") then
            local tmp = dir .. "/" .. base .. ".part"
            local f = io.open(tmp, "wb")
            if not f then return nil end
            socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
            local c, headers = socket.skip(1, http.request{ url = src, sink = ltn12.sink.file(f) })
            socketutil:reset_timeout()
            local ctype = headers and headers["content-type"] or ""
            local ext = ctype:match("image/(%w+)")
            if c ~= 200 or not ext then os.remove(tmp) return nil end
            ext = ext:gsub("jpeg", "jpg")
            os.rename(tmp, dir .. "/" .. base .. "." .. ext)
            return base .. "." .. ext
        end
    end

    local body = (a.body_html or "")
        :gsub('%s+srcset="[^"]*"', ""):gsub("%s+sizes=\"[^\"]*\"", "")
        :gsub('(<img[^>]-src=")([^"]+)(")', function(pre, src, post)
            local file = saveImage(src)
            return file and (pre .. file .. post) or (pre .. "" .. post)
        end)
    local meta = {}
    if a.source_name and a.source_name ~= "" then table.insert(meta, a.source_name) end
    if a.read_time_minutes then table.insert(meta, T(_("%1 min"), a.read_time_minutes)) end
    local function esc(t) return (t or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;") end
    local html = table.concat({
        '<!DOCTYPE html><html><head><meta charset="utf-8">',
        "<title>", esc(a.title), "</title>",
        -- A notch smaller than book text, with a quieter title, so a preview
        -- reads like an article page rather than a chapter opener. Relative
        -- sizes: KOReader's own font-size setting still scales everything.
        "<style>",
        "body{font-size:0.82em;line-height:1.45}",
        "h1{font-size:1.45em;line-height:1.2;text-align:left;margin:0 0 0.3em}",
        "h2{font-size:1.2em}h3{font-size:1.05em}",
        ".folio-meta{font-size:0.8em;color:#555;text-indent:0;margin:0 0 1.2em}",
        "img{max-width:100%}",
        "</style>",
        "</head><body>",
        "<h1>", esc(a.title), "</h1>",
        '<p class="folio-meta">', esc(table.concat(meta, " · ")), "</p>",
        body,
        "</body></html>",
    })
    local f = io.open(path, "w")
    if not f then return nil end
    f:write(html)
    f:close()
    return path
end

--- Previews older than 30 days are re-fetched on demand; keep the cache small.
function Folio:prunePreviews()
    local dir = DataStorage:getDataDir() .. "/cache/folio-articles"
    if lfs.attributes(dir, "mode") ~= "directory" then return end
    local cutoff = os.time() - 30 * 86400
    for f in lfs.dir(dir) do
        local p = dir .. "/" .. f
        local mod = lfs.attributes(p, "modification")
        if f ~= "." and f ~= ".." and mod and mod < cutoff then os.remove(p) end
    end
end

-- ─── highlights ──────────────────────────────────────────────────────────────

--- KOReader's highlights from every downloaded Folio issue, grouped by article
-- (KOReader records the chapter, and each Folio article is a chapter).
function Folio:collectHighlights()
    local groups, by_key, issues = {}, {}, {}
    for id, d in pairs(self:downloaded()) do
        local path = type(d) == "table" and d.path or d
        if path and DocSettings:hasSidecarFile(path) then
            table.insert(issues, { id = tonumber(id), path = path, number = type(d) == "table" and d.number or nil })
        end
    end
    table.sort(issues, function(a, b) return a.id > b.id end)
    for __, issue in ipairs(issues) do
        local ds = DocSettings:open(issue.path)
        local number = issue.number
        for __, a in ipairs(ds:readSetting("annotations") or {}) do
            if a.text and a.text ~= "" then
                local title = a.chapter or _("Untitled")
                local key = issue.id .. "/" .. title
                if not by_key[key] then
                    by_key[key] = { title = title, source = number and T(_("Issue #%1"), number) or _("Folio"), items = {} }
                    table.insert(groups, by_key[key])
                end
                table.insert(by_key[key].items, { text = a.text, note = a.note })
            end
        end
    end
    return groups
end

function Folio:exportHighlights(groups)
    local lines = { "# Folio highlights", "" }
    for __, g in ipairs(groups) do
        table.insert(lines, "## " .. g.title .. " (" .. g.source .. ")")
        table.insert(lines, "")
        for __, h in ipairs(g.items) do
            table.insert(lines, "> " .. h.text:gsub("\n", "\n> "))
            if h.note and h.note ~= "" then table.insert(lines, "") table.insert(lines, h.note) end
            table.insert(lines, "")
        end
    end
    lfs.mkdir(self:downloadDir())
    local path = self:downloadDir() .. "/Folio highlights.md"
    local f = io.open(path, "w")
    if not f then toast(_("Couldn't write the file.")) return end
    f:write(table.concat(lines, "\n"))
    f:close()
    toast(T(_("Saved to %1."), self:folderLabel() .. " / Folio highlights.md"), 3)
end

-- ─── the Folio screen ────────────────────────────────────────────────────────

local FolioView = InputContainer:extend{
    covers_fullscreen = true,
    tab = "issues",
    page = 1,
}

function FolioView:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.data = { details = {} }
    self.selected = {}
    if self.folio:token() then
        self:load()
        self:refresh()
        self:backgroundSync()
    else
        self:startPairing()
        self:refresh()
    end
end

--- Download new issues without blocking the screen, then redraw.
function FolioView:backgroundSync(on_done)
    local started = self.folio:sync(function(got, failed)
        if not self.closed then self:reload() end
        if on_done then on_done(got, failed) end
    end)
    if started then self:refresh() end -- show "Syncing…" in the nav
    return started
end

function FolioView:startPairing()
    self.tab = "connect"
    self.pairing = nil
    NetworkMgr:runWhenOnline(function()
        self.pairing = self.folio:startPairing(function(update)
            self.pairing = update
            self:refresh()
        end, function()
            self.tab = "issues"
            self:load()
            self:refresh()
            self:backgroundSync()
        end)
        self:refresh()
    end)
end

--- Fetch what the current tab needs. Blocking; shows a note while it runs.
function FolioView:load()
    local folio = self.folio
    folio.offline = false
    busy(_("Loading Folio…"), function()
        if self.tab == "issues" then
            local issues, more, raw = folio:fetchIssues()
            if issues then self.data.issues, self.data.issues_more, self.data.issues_offset = issues, more, raw end
            local latest = self.data.issues and self.data.issues[1]
            if latest then self:loadDetail(latest) end
        elseif self.tab == "inbox" then
            local code, data = folio:request("GET", "/api/articles?status=inbox&limit=100")
            if code == 200 and data then
                self.data.articles = data.articles or {}
                self.data.articles_total = data.total
            end
            self:loadNextIssue()
        elseif self.tab == "settings" then
            local code, me = folio:request("GET", "/api/me")
            if code == 200 then self.data.me = me end
        end
    end)
end

function FolioView:loadDetail(issue)
    if self.data.details[issue.id] then return end
    local code, d = self.folio:request("GET", "/api/generations/" .. issue.id)
    if code == 200 and d then self.data.details[issue.id] = d end
end

--- Earliest upcoming run among active schedules.
function FolioView:loadNextIssue()
    local code, data = self.folio:request("GET", "/api/schedules")
    self.data.next_run = nil
    if code ~= 200 or not data or not data.schedules then return end
    for __, s in ipairs(data.schedules) do
        local t = s.active == 1 and UI.utc(s.next_run_at)
        if t and t > os.time() and (not self.data.next_run or t < self.data.next_run) then self.data.next_run = t end
    end
    if not self.data.next_run then return end
    local issues = self.data.issues or self.folio:fetchIssues() or {}
    local latest = issues[1]
    self.data.next_issue_number = latest and latest.issue_number and (latest.issue_number + 1) or 1
end

function FolioView:refresh()
    local W, H = Screen:getWidth(), Screen:getHeight()
    local px = UI.px
    local content
    if self.tab == "connect" then
        content = UI.connect(self, W, H, W, H)
    else
        local top = VerticalGroup:new{ align = "left", UI.statusBar(W), UI.nav(self, W) }
        local foot_h = UI.footer(self, W, 1, 1):getSize().h
        local pad_top, pad_bottom = px(26), px(18)
        local body_h = H - top:getSize().h - foot_h - pad_top - pad_bottom
        local builder = ({ issues = UI.issues, contents = UI.contents, inbox = UI.inbox, highlights = UI.highlights, settings = UI.settings })[self.tab]
        local blocks, pages, page = builder(self, W - px(64), body_h)
        self.pages, self.page = pages or 1, page or 1
        -- Pad the body out to its full height so the footer sits at the bottom.
        local inner_h = blocks[1]:getSize().h
        local body = FrameContainer:new{ blocks[1], bordersize = 0, margin = 0, padding = 0,
            padding_left = px(32), padding_top = pad_top, padding_bottom = math.max(0, body_h + pad_bottom - inner_h) }
        content = VerticalGroup:new{ align = "left", top, body, UI.footer(self, W, self.page, self.pages) }
    end
    self[1] = FrameContainer:new{ content, background = UI.C.paper, bordersize = 0, margin = 0, padding = 0, width = W, height = H }
    UIManager:setDirty(self, "ui")
end

function FolioView:go(tab)
    self.tab, self.page = tab, 1
    self:load()
    self:refresh()
end

--- More issues may be waiting on the server (Issues tab only).
function FolioView:hasMore()
    return self.tab == "issues" and self.data.issues_more == true
end

function FolioView:setPage(n)
    if n > (self.pages or 1) and self:hasMore() then
        -- Paged past what we have: fetch the next 20 older issues.
        busy(_("Loading older issues…"), function()
            local older, more, raw = self.folio:fetchIssues(self.data.issues_offset or 0)
            if older then
                for __, issue in ipairs(older) do table.insert(self.data.issues, issue) end
                self.data.issues_more = more
                self.data.issues_offset = (self.data.issues_offset or 0) + raw
            end
        end)
    end
    self.page = n
    self:refresh()
end

--- Open an inbox article on its own, without making an issue. Back returns here.
function FolioView:previewArticle(article)
    local path, code
    NetworkMgr:runWhenOnline(function()
        busy(_("Opening article…"), function() path, code = self.folio:previewPath(article) end)
        if not path then
            toast(code and _("Folio couldn't open that article.") or NETWORK_ERROR)
            return
        end
        reopen_tab = self.tab
        self:close()
        self.folio:openFile(path)
    end)
end

function FolioView:reload()
    self:load()
    self:refresh()
end

function FolioView:syncNow()
    NetworkMgr:runWhenOnline(function()
        local started = self:backgroundSync(function(got, failed)
            if failed then toast(failed == "network" and NETWORK_ERROR or _("Folio couldn't list your issues."))
            elseif got > 0 then toast(T(_("%1 new Folio issue(s) on this reader."), got), 3)
            else toast(_("You're up to date."), 2) end
        end)
        if not started and self.folio.syncing then toast(_("Already checking for new issues…"), 2) end
    end)
end

function FolioView:showContents(issue)
    self.contents_issue, self.tab, self.page = issue, "contents", 1
    busy(_("Loading…"), function() self:loadDetail(issue) end)
    self:refresh()
end

--- Open an issue (downloading it, or another format of it, first if needed).
-- chapter: optional article title to jump to once the book is open.
function FolioView:openIssue(issue, format, chapter)
    local path = self.folio:localPath(issue)
    if not path or (format and format ~= self.folio:localFormat(issue)) then
        busy(_("Downloading…"), function() path = self.folio:downloadIssue(issue, format) end)
    end
    if not path then toast(_("That issue couldn't be downloaded.")) return end
    self:close()
    pending_chapter = chapter
    self.folio:openFile(path)
end

function FolioView:generate()
    local ids = {}
    for id in pairs(self.selected) do table.insert(ids, id) end
    if #ids == 0 then return end
    if self.folio:makeIssue(ids) then
        self.selected = {}
        self:reload()
    end
end

function FolioView:disconnect()
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = _("Disconnect this reader from Folio? Issues already here stay."),
        ok_text = _("Disconnect"),
        ok_callback = function()
            self.folio:disconnect()
            self.data = { details = {} }
            self:startPairing()
            self:refresh()
        end,
    })
end

function FolioView:chooseFolder()
    local PathChooser = require("ui/widget/pathchooser")
    UIManager:show(PathChooser:new{
        select_file = false,
        path = self.folio:downloadDir(),
        onConfirm = function(path) self.folio:save("dir", path); self:refresh() end,
    })
end

function FolioView:openFolder()
    self:close()
    local FileManager = require("apps/filemanager/filemanager")
    lfs.mkdir(self.folio:downloadDir())
    if FileManager.instance then
        FileManager.instance.file_chooser:changeToPath(self.folio:downloadDir())
    else
        FileManager:showFiles(self.folio:downloadDir())
    end
end

function FolioView:close()
    self.closed = true
    -- They've now seen the "arrived while you were away" card. Cleared on close,
    -- not on redraw: a background sync redraws the screen while they look at it.
    self.folio:save("unseen_new", nil)
    if self.pairing then self.pairing.cancelled = true end
    UIManager:close(self)
end

function FolioView:onClose() self:close() return true end

function Folio:showFolio(tab)
    self.view = FolioView:new{ folio = self, tab = tab }
    UIManager:show(self.view)
end

-- ─── menu + events ───────────────────────────────────────────────────────────

function Folio:addToMainMenu(menu_items)
    menu_items.folio = {
        text = _("Folio"),
        sorting_hint = "tools",
        callback = function() self:showFolio() end,
    }
end

-- Jump to the article the user tapped on the Contents screen.
function Folio:onReaderReady()
    local chapter = pending_chapter
    pending_chapter = nil
    if not chapter or not self.ui.toc then return end
    self.ui.toc:fillToc()
    for __, item in ipairs(self.ui.toc.toc or {}) do
        local title = (item.title or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if title == chapter then
            self.ui:handleEvent(require("ui/event"):new("GotoPage", item.page))
            return
        end
    end
end

-- KOReader broadcasts this when Wi-Fi comes up (and once at start if it's already up).
function Folio:onNetworkConnected()
    if self:token() and self:autoSync() then
        UIManager:nextTick(function()
            self:sync(function(got)
                if got > 0 then toast(T(_("%1 new Folio issue(s) on this reader."), got), 4) end
                if self.view and not self.view.closed then self.view:reload() end
            end)
        end)
    end
end

return Folio
