-- Screenshot driver for tools/screenshots/run.sh: walks every Folio screen and
-- saves a PNG of each. Never ship this in a release zip.
local Device = require("device")
local DocSettings = require("docsettings")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local OUT = os.getenv("SHOT_OUT")
local TOKEN = os.getenv("SHOT_TOKEN")
-- Screenshots should look like a touch e-reader: no keyboard shortcut hints.
local function no() return false end
-- The emulator has no battery; show a plausible one.
pcall(function() Device:getPowerDevice().getCapacity = function() return 58 end end)
Device.hasKeys = no; Device.hasKeyboard = no; Device.hasDPad = no

local Shot = WidgetContainer:extend{ name = "shot", is_doc_only = false }

local function shot(name)
    UIManager:forceRePaint()
    local file = OUT .. "/" .. name .. ".png"
    if Device.screen:isColorEnabled() then
        Device.screen:shot(file)
    else
        -- The desktop emulator always draws in color; a grayscale e-ink panel
        -- shows covers in gray, so convert to match what readers actually see.
        local Blitbuffer = require("ffi/blitbuffer")
        local src = Device.screen.bb
        local gray = Blitbuffer.new(src:getWidth(), src:getHeight(), Blitbuffer.TYPE_BB8)
        gray:blitFrom(src)
        gray:writePNG(file)
        gray:free()
    end
    print("SHOT", name)
end

local function steps(list, gap)
    local i = 0
    local function nxt()
        i = i + 1
        if list[i] then
            local ok, err = pcall(list[i])
            if not ok then print("STEP ERROR", i, err) end
            UIManager:scheduleIn(gap, nxt)
        end
    end
    UIManager:scheduleIn(gap, nxt)
end

function Shot:init()
    local folio = self.ui.folio
    if not folio then print("NO FOLIO") return end
    if self.ui.document then return self:readerSteps(folio) end
    if _G.SHOT_DONE_FM then return end
    _G.SHOT_DONE_FM = true
    local view
    steps({
        function() folio:save("server", os.getenv("SHOT_SERVER") or "https://myfolio.so"); folio:save("token", nil) end,
        function() folio:showFolio() end,
        function()
            -- Screenshots go in the public README: show the public address
            -- even when the run talks to a test server.
            local p = folio.view.pairing
            if p then p.verification_uri = "https://myfolio.so/link" end
            folio.view:refresh()
        end,
        function() shot("00-connect") end,
        function()
            folio.view:close()
            folio:save("token", TOKEN); folio:save("connected_at", os.time() - 86400)
            folio:save("keep_latest", 8)
            -- Download synchronously here (the plugin's own sync runs in the
            -- background) so the demo state below has files to attach to.
            for i, issue in ipairs(folio:fetchIssues() or {}) do
                if i <= folio:keepLatest() then folio:downloadIssue(issue) end
            end
            -- Demo state: one issue part-read, one finished, real excerpts as highlights.
            local issues = folio:fetchIssues()
            local function seed(issue, pct, status, annotate)
                local path = folio:localPath(issue); if not path then return end
                local ds = DocSettings:open(path)
                ds:saveSetting("percent_finished", pct)
                if status then ds:saveSetting("summary", { status = status }) end
                if annotate then
                    local code, d = folio:request("GET", "/api/generations/" .. issue.id)
                    local ann = {}
                    for i, a in ipairs(d and d.articles or {}) do
                        if a.excerpt and a.excerpt ~= "" and i <= 3 then
                            table.insert(ann, { text = a.excerpt:gsub("%s+", " "):sub(1, 160):gsub("%s%S*$", "") .. "…", chapter = a.title,
                                note = i == 1 and "Use this to open the Friday essay." or nil, datetime = "2026-10-19 08:00:00", page = 1 })
                        end
                    end
                    ds:saveSetting("annotations", ann)
                end
                ds:flush()
            end
            seed(issues[1], 0.25, nil, true)
            seed(issues[2], 0.62, nil, true)
            seed(issues[3], 1, "complete")
            folio:save("unseen_new", 2)
        end,
        function() folio:showFolio(); view = folio.view end,
        function() shot("01-issues") end,
        function() view:showContents(view.data.issues[1]) end,
        function() shot("02-contents") end,
        function()
            -- Public screenshots: show a made-up forwarding address, not the
            -- test account's real one (checked unused in prod and dev).
            folio:save("forward_email", "alex-reader@myfolio.so")
            view:go("inbox")
            local n = 0
            for i, a in ipairs(view.data.articles or {}) do
                if a.scrape_status == "done" and (i == 1 or i == 2 or i == 4 or i == 5) then view.selected[a.id] = true end
            end
            view:refresh()
        end,
        function() shot("03-inbox") end,
        function() view:go("highlights") end,
        function() shot("04-highlights") end,
        function()
            view:go("settings")
            local real = folio.settings:readSetting("server")
            folio.settings:saveSetting("server", nil) -- display only, see 00-connect
            view:refresh()
            folio.settings:saveSetting("server", real)
        end,
        function() shot("06-settings") end,
        function()
            -- Preview an inbox article; readerSteps shoots it, then opens the issue.
            _G.SHOT_ISSUE_PATH = folio:localPath(view.data.issues and view.data.issues[1] or folio:fetchIssues()[1])
            view:go("inbox")
            view:previewArticle(view.data.articles[1])
        end,
    }, 4)
end

function Shot:readerSteps(folio)
    if self.ui.document.file:find("folio-articles", 1, true) then
        return steps({
            function() shot("07-preview") end,
            function()
                print("OPEN", _G.SHOT_ISSUE_PATH)
                require("apps/reader/readerui"):showReader(_G.SHOT_ISSUE_PATH)
            end,
        }, 4)
    end
    steps({
        function() self.ui:handleEvent(require("ui/event"):new("GotoPage", 3)) end,
        function() folio:showSaveLink("https://anildash.com/2012/12/13/the_web_we_lost/") end,
        function() shot("05-save-link") end,
        function() os.exit(0) end,
    }, 4)
end

return Shot
