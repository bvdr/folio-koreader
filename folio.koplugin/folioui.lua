--[[--
Folio screens for KOReader, drawn to match the Folio design (koreader-plugin.pen).

Sizes are written in design pixels (the design is a 720×960 canvas) and
scaled to the real screen width by px(), so the layout keeps its proportions
on a 6″ Kobo and a 10″ Boox alike. Colors are the design's black & white
tokens: e-ink panels show grey levels, not hues.

@module koplugin.folio.ui
]]

local Blitbuffer = require("ffi/blitbuffer")
local DocSettings = require("docsettings")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Freetype = require("ffi/freetype")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local lfs = require("libs/libkoreader-lfs")
local T = require("ffi/util").template
local _ = require("gettext")
local Screen = Device.screen

local DIR = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"

local UI = {}

-- ─── tokens ──────────────────────────────────────────────────────────────────

local function gray(v) return Blitbuffer.Color8(v) end
local C = {
    paper = Blitbuffer.COLOR_WHITE,
    ink = Blitbuffer.COLOR_BLACK,
    muted = gray(0x3D),
    faint = gray(0x6B),
    line = gray(0xA3),
    surface = gray(0xED),
    mark = gray(0xD6),
}
UI.C = C

-- Design pixels → screen pixels.
local function px(v) return math.floor(v * Screen:getWidth() / 720 + 0.5) end
UI.px = px

local faces = {}
--- A face from the fonts bundled with the plugin, sized in design pixels.
-- Built like Font:getFace() builds its faces, but from our own folder, so we
-- don't have to install fonts into KOReader.
local function face(file, size)
    local key = file .. size
    if faces[key] then return faces[key] end
    local real = px(size)
    local ok, ftsize = pcall(Freetype.newFaceSize, DIR .. "fonts/" .. file, real)
    if not ok then return Font:getFace("cfont", size) end
    local f = { orig_font = file, realname = file, size = real, orig_size = real, ftsize = ftsize,
                hash = "folio/" .. key, hb_features = { "+kern", "+liga" } }
    -- xtext asks for fallback 0 (the font itself) and then 1, 2, … for glyphs
    -- our font lacks. Fallbacks come from KOReader's own list; Font:getFace()
    -- scales by DPI, so hand it the size before that scaling.
    local fallbacks = {}
    f.getFallbackFont = function(num)
        if not num or num == 0 then
            f.embolden_half_strength = f.embolden_half_strength or ftsize:getEmboldenHalfStrength(3/8)
            return f
        end
        if fallbacks[num] == nil then
            local name = Font.fallbacks[num]
            local fb = name and Font:getFace(name, real * 1000 / Screen:scaleBySize(1000))
            if fb then fb.embolden_half_strength = fb.embolden_half_strength or fb.ftsize:getEmboldenHalfStrength(3/8) end
            fallbacks[num] = fb or false
        end
        return fallbacks[num] or nil
    end
    faces[key] = f
    return f
end

local F = {
    serif = "Newsreader-Medium.ttf",
    serif_italic = "Newsreader-MediumItalic.ttf",
    serif_regular = "Newsreader-Regular.ttf",
    serif_regular_italic = "Newsreader-Italic.ttf",
    sans = "DMSans-Regular.ttf",
    sans_medium = "DMSans-Medium.ttf",
    sans_bold = "DMSans-SemiBold.ttf",
}
UI.F = F

-- ─── primitives ──────────────────────────────────────────────────────────────

local function text(str, font, size, color, max_width)
    return TextWidget:new{ text = str, face = face(font, size), fgcolor = color or C.ink, max_width = max_width, padding = 0 }
end

local function para(str, font, size, color, width, line_height)
    return TextBoxWidget:new{
        text = str, face = face(font, size), fgcolor = color or C.ink, width = width,
        line_height = (line_height or 1.3) - 1,
    }
end

--- Tracked uppercase label ("N E W · A R R I V E D"). TextWidget has no letter
-- spacing, so a thin space goes between letters.
local function eyebrow(str, color, size)
    local spaced = str:upper():gsub("([%z\1-\127\194-\244][\128-\191]*)", "%1\u{2009}"):gsub("\u{2009}$", "")
    return text(spaced, F.sans_bold, size or 11, color or C.ink)
end

local function hspan(w) return HorizontalSpan:new{ width = px(w) } end
local function vspan(h) return VerticalSpan:new{ width = px(h) } end

local function row(children, gap, align)
    local g = HorizontalGroup:new{ align = align or "center" }
    for i, c in ipairs(children) do
        if i > 1 and gap and gap > 0 then table.insert(g, hspan(gap)) end
        table.insert(g, c)
    end
    return g
end

local function col(children, gap, align)
    local g = VerticalGroup:new{ align = align or "left" }
    for i, c in ipairs(children) do
        if i > 1 and gap and gap > 0 then table.insert(g, vspan(gap)) end
        table.insert(g, c)
    end
    return g
end

--- Left and right pinned to the edges of `width` (flex space-between).
local function spread(left, right, width, align)
    local gap = width - left:getSize().w - right:getSize().w
    return HorizontalGroup:new{ align = align or "center", left, HorizontalSpan:new{ width = math.max(0, gap) }, right }
end

local function hline(width, color, thickness)
    return LineWidget:new{ background = color or C.line, dimen = Geom:new{ w = width, h = math.max(1, px(thickness or 1)) } }
end

local function vline(height, color, thickness)
    return LineWidget:new{ background = color or C.ink, dimen = Geom:new{ w = math.max(1, px(thickness or 2)), h = height } }
end

--- Box with padding {top, right, bottom, left} in design px, optional fill/border/radius.
-- o.width / o.height (screen px) are honored by growing the right/bottom
-- padding: FrameContainer's own width/height don't count in getSize().
local function box(child, o)
    o = o or {}
    local p = o.padding or { 0, 0, 0, 0 }
    if type(p) == "number" then p = { p, p, p, p } end
    if #p == 2 then p = { p[1], p[2], p[1], p[2] } end
    local bw = o.stroke and math.max(1, px(o.stroke_width or 1)) or 0
    local pt, pr, pb, pl = px(p[1]), px(p[2]), px(p[3]), px(p[4])
    local cs = child:getSize()
    if o.width then pr = math.max(0, o.width - cs.w - pl - 2 * bw) end
    if o.height then
        -- Vertically center the content inside a fixed height, like the design's rows.
        local free = math.max(0, o.height - cs.h - 2 * bw)
        if p[1] == 0 and p[3] == 0 then pt = math.floor(free / 2); pb = free - pt
        else pb = math.max(0, o.height - cs.h - pt - 2 * bw) end
    end
    return FrameContainer:new{
        child,
        background = o.fill,
        color = o.stroke or C.ink,
        bordersize = bw,
        radius = o.radius and px(o.radius) or nil,
        padding = 0, margin = 0,
        padding_top = pt, padding_right = pr, padding_bottom = pb, padding_left = pl,
    }
end

--- Fixed-size box (w×h screen px) with its child centered.
local function center(child, w, h, o)
    local cs = child:getSize()
    o = o or {}
    local bw = o.stroke and math.max(1, px(o.stroke_width or 1)) or 0
    local pl = math.floor((w - cs.w) / 2) - bw
    local pt = math.floor((h - cs.h) / 2) - bw
    return FrameContainer:new{
        child, background = o.fill, color = o.stroke or C.ink, bordersize = bw,
        radius = o.radius and px(o.radius) or nil, margin = 0, padding = 0,
        padding_left = pl, padding_top = pt,
        padding_right = w - cs.w - pl - 2 * bw, padding_bottom = h - cs.h - pt - 2 * bw,
    }
end

local function icon(name, size)
    return ImageWidget:new{ file = DIR .. "icons/" .. name .. ".svg", width = px(size), height = px(size), alpha = true }
end

local function dot(size, color)
    local s = px(size)
    return center(VerticalSpan:new{ width = 0 }, s, s, { fill = color or C.ink, radius = size / 2 })
end

local function image(file, w, h)
    if not file or not lfs.attributes(file, "mode") then
        return center(VerticalSpan:new{ width = 0 }, w, h, { fill = C.surface })
    end
    return ImageWidget:new{ file = file, width = w, height = h, file_do_cache = false }
end

--- Tap target around any widget.
local Tap = InputContainer:extend{ callback = nil }
function Tap:init()
    self.dimen = Geom:new{ w = self[1]:getSize().w, h = self[1]:getSize().h }
    self.ges_events = { TapFolio = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } } }
end
function Tap:onTapFolio() if self.callback then self.callback() end return true end
local function tap(widget, callback) return Tap:new{ widget, callback = callback } end

local function button(label, kind, callback)
    local primary = kind == "primary"
    local inverted = kind == "inverted" -- white button on a black bar
    local fill = primary and C.ink or (inverted and C.paper or nil)
    local color = primary and C.paper or C.ink
    local b = box(text(label, F.sans_medium, 15, color), {
        padding = { 13, 22 }, fill = fill, radius = 6,
        stroke = (not primary and not inverted) and C.ink or nil, stroke_width = 1.5,
    })
    return tap(b, callback)
end

local function toggle(on, callback)
    local knob = dot(18, on and C.paper or C.faint)
    local track_w, track_h = px(48), px(26)
    local bw, pad = px(1.5), px(4)
    local kw = knob:getSize().w
    local pl = (on and (track_w - kw - pad) or pad) - bw
    local pt = math.floor((track_h - kw) / 2) - bw
    local t = FrameContainer:new{
        knob, background = on and C.ink or C.paper, color = C.ink, bordersize = bw,
        radius = math.floor(track_h / 2), margin = 0, padding = 0,
        padding_left = pl, padding_top = pt,
        padding_right = track_w - kw - pl - 2 * bw, padding_bottom = track_h - kw - pt - 2 * bw,
    }
    return tap(t, callback)
end

UI.text, UI.para, UI.row, UI.col, UI.box, UI.tap, UI.button = text, para, row, col, box, tap, button

-- ─── formatting ──────────────────────────────────────────────────────────────

local NUMBER_WORDS = { "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten" }

--- D1 'YYYY-MM-DD HH:MM:SS' (UTC) → epoch seconds.
local function utc(ts)
    if type(ts) ~= "string" then return nil end
    local y, m, d, hh, mm, ss = ts:match("(%d+)-(%d+)-(%d+)[ T](%d+):(%d+):(%d+)")
    if not y then return nil end
    local t = os.time{ year = y, month = m, day = d, hour = hh, min = mm, sec = ss }
    -- os.time() reads the table as local time: shift by the local UTC offset.
    local now = os.time()
    return t + os.difftime(now, os.time(os.date("!*t", now)))
end
UI.utc = utc

local function clock(epoch)
    if G_reader_settings:isTrue("twelve_hour_clock") then
        return (os.date("%I:%M %p", epoch):gsub("^0", ""))
    end
    return os.date("%H:%M", epoch)
end
UI.clock = clock

local function minutes(n)
    n = tonumber(n) or 0
    if n < 60 then return T(_("%1 min"), n) end
    local h, m = math.floor(n / 60), n % 60
    return m > 0 and T(_("%1 h %2 min"), h, m) or T(_("%1 h"), h)
end

local function issueTitle(issue)
    return (issue.title and issue.title ~= "") and issue.title or "The Weekly Quiet"
end

--- KOReader's own reading state for a downloaded issue: "complete", a percent, or nil.
local function readState(path)
    if not path or lfs.attributes(path, "mode") ~= "file" then return "missing" end
    if not DocSettings:hasSidecarFile(path) then return "unread" end
    local ds = DocSettings:open(path)
    local summary = ds:readSetting("summary")
    if summary and summary.status == "complete" then return "complete" end
    return ds:readSetting("percent_finished") or 0
end
UI.readState = readState

local function statusLine(state)
    if state == "complete" then return row({ icon("check", 13), text(_("Finished"), F.sans, 12, C.muted) }, 6) end
    if state == "missing" then return row({ icon("cloud-download", 13), text(_("Not downloaded"), F.sans, 12, C.faint) }, 6) end
    if state == "unread" or state == 0 then return row({ dot(6), text(_("Unread"), F.sans_bold, 12, C.ink) }, 6) end
    return text(T(_("%1% read"), math.floor(state * 100)), F.sans, 12, C.muted)
end

-- ─── chrome: status bar, Folio nav, KOReader-style footer ────────────────────

function UI.statusBar(W)
    local right = {}
    local NetworkMgr = require("ui/network/manager")
    if NetworkMgr:isWifiOn() then table.insert(right, icon("wifi", 16)) end
    local ok, cap = pcall(function() return Device:getPowerDevice():getCapacity() end)
    if ok and cap then table.insert(right, text(cap .. "%", F.sans_bold, 12)) end
    local r = row(right, 14)
    if #right == 0 then r = HorizontalSpan:new{ width = 0 } end
    return col({
        box(spread(text(clock(os.time()), F.sans_bold, 13), r, W - px(48)), { padding = { 0, 24 }, height = px(40) }),
    })
end

function UI.nav(view, W)
    local tabs = {}
    for __, t in ipairs({ { "issues", _("Issues") }, { "inbox", _("Inbox") }, { "highlights", _("Highlights") }, { "settings", _("Settings") } }) do
        local active = view.tab == t[1]
        local label = text(t[2], active and F.sans_medium or F.sans, 15, active and C.ink or C.muted)
        local under = hline(label:getSize().w, active and C.ink or C.paper, 2)
        table.insert(tabs, tap(col({ vspan(8), label, vspan(6), under }), function() view:go(t[1]) end))
    end
    local logo = ImageWidget:new{ file = DIR .. "wordmark.png", width = px(60), height = px(22.7) }
    local left = row({ logo, row(tabs, 22, "bottom") }, 28)
    local last = view.folio.settings:readSetting("last_sync")
    local sync = tap(row({
        dot(7, C.ink),
        text(last and T(_("Synced %1"), clock(last)) or _("Sync now"), F.sans, 12, C.muted),
        icon("refresh-cw", 15),
    }, 7), function() view:syncNow() end)
    return col({
        box(spread(left, sync, W - px(48)), { padding = { 0, 24 }, height = px(57) }),
        hline(W),
    })
end

function UI.footer(view, W, page, pages)
    local function arrow(name, target)
        return tap(icon(name, 24), function() if target >= 1 and target <= pages then view:setPage(target) end end)
    end
    local items = {
        tap(icon("menu", 26), function() view:close() end),
        arrow("chevrons-left", 1), arrow("chevron-left", page - 1),
        text(T(_("Page %1 of %2"), page, pages), F.sans_medium, 15),
        arrow("chevron-right", page + 1), arrow("chevrons-right", pages),
        tap(icon("layout-grid", 24), function() view:openFolder() end),
    }
    local total = 0
    for __, w in ipairs(items) do total = total + w:getSize().w end
    local gap = math.floor((W - px(56) - total) / (#items - 1))
    local g = HorizontalGroup:new{ align = "center" }
    for i, w in ipairs(items) do
        if i > 1 then table.insert(g, HorizontalSpan:new{ width = gap }) end
        table.insert(g, w)
    end
    return col({ hline(W), box(g, { padding = { 0, 28 }, height = px(63) }) })
end

-- ─── covers ──────────────────────────────────────────────────────────────────

local function cover(view, issue, w, h)
    local file = view.folio:coverPath(issue)
    return FrameContainer:new{ image(file, w, h), bordersize = 0, padding = 0, margin = 0 }
end

-- ─── pages ───────────────────────────────────────────────────────────────────

--- Split rows into pages that fit `avail` pixels (with `gap` design px between).
local function paginate(rows, avail, gap)
    local pages, cur, used = {}, {}, 0
    local g = px(gap or 0)
    for __, r in ipairs(rows) do
        local h = r:getSize().h + (#cur > 0 and g or 0)
        if #cur > 0 and used + h > avail then
            table.insert(pages, cur)
            cur, used = {}, 0
            h = r:getSize().h
        end
        table.insert(cur, r)
        used = used + h
    end
    if #cur > 0 or #pages == 0 then table.insert(pages, cur) end
    return pages
end

local function heading(title, sub, right, W)
    local left = col({ text(title, F.serif, 36), sub and text(sub, F.sans, 14, C.muted, W - (right and right:getSize().w + px(16) or 0)) or nil }, 4)
    if right then return spread(left, right, W, "bottom") end
    return left
end

-- Issues ---------------------------------------------------------------------

function UI.issues(view, W, H)
    local issues = view.data.issues or {}
    if #issues == 0 then
        return { col({
            text(_("Library"), F.serif, 36), vspan(10),
            para(_("No issues yet. Pick articles in your Inbox and tap Generate issue, or set a schedule at myfolio.so."), F.sans, 15, C.muted, W, 1.6),
        }) }, 1
    end
    local latest = issues[1]
    local path = view.folio:localPath(latest)
    local state = readState(path)
    local detail = view.data.details and view.data.details[latest.id]

    -- Hero
    local cw, ch = px(222), px(296)
    local info_w = W - cw - px(28)
    local arrived = utc(latest.completed_at or latest.created_at)
    local eyebrow_text = (state == "unread" or state == "missing") and _("New") or _("Latest")
    if arrived then eyebrow_text = eyebrow_text .. " · " .. T(_("arrived %1"), clock(arrived)) end
    local body
    if detail and detail.articles and #detail.articles > 0 then
        local a = detail.articles
        body = #a == 1 and a[1].title or T(_("%1, %2 and %3 more."), a[1].title or "", a[2].title or "", #a - 2)
        if #a == 2 then body = T(_("%1 and %2."), a[1].title or "", a[2].title or "") end
        if latest.total_read_time then body = body .. " " .. T(_("About %1."), minutes(latest.total_read_time)) end
    else
        body = T(_("%1 articles, about %2."), latest.article_count or "?", minutes(latest.total_read_time))
    end
    local pct = (state == "complete") and 1 or (type(state) == "number" and state or 0)
    local track_w = info_w - px(12) - px(80)
    local progress = row({
        OverlapGroup:new{ dimen = Geom:new{ w = track_w, h = px(3) },
            hline(track_w, C.line, 3), hline(math.max(1, math.floor(track_w * pct)), C.ink, 3) },
        text(state == "missing" and _("Not downloaded") or (state == "complete" and _("Finished") or T(_("%1% read"), math.floor(pct * 100))), F.sans, 12, C.muted),
    }, 12)
    local primary_label = state == "missing" and _("Download") or ((state == "unread") and _("Start reading") or _("Continue reading"))
    local hero = row({
        tap(cover(view, latest, cw, ch), function() view:openIssue(latest) end),
        col({
            eyebrow(eyebrow_text, C.ink),
            col({ text(issueTitle(latest) .. ",", F.serif, 38, C.ink, info_w),
                  text(T(_("issue #%1."), latest.issue_number or "?"), F.serif_italic, 38, C.ink, info_w) }),
            para(body, F.sans, 15, C.muted, info_w, 1.6),
            progress,
            row({ button(primary_label, "primary", function() view:openIssue(latest) end),
                  button(_("Contents"), "secondary", function() view:showContents(latest) end) }, 10),
        }, 14),
    }, 28)

    local blocks = { hero }

    -- "Arrived while you were away" card
    local unseen = view.folio.settings:readSetting("unseen_new") or 0
    if unseen > 0 then
        local word = NUMBER_WORDS[unseen] or tostring(unseen)
        local title = unseen == 1 and _("A new issue arrived while you were away.") or T(_("%1 issues arrived while you were away."), word)
        local iconbox = center(icon("wifi", 17), px(36), px(36), { stroke = C.line, radius = 8 })
        table.insert(blocks, box(row({ iconbox, col({
            text(title, F.serif, 17, C.ink, W - px(100)),
            text(T(_("Downloaded when Wi-Fi came on. Saved to %1."), view.folio:folderLabel()), F.sans, 13, C.muted, W - px(100)),
        }, 2) }, 14), { padding = { 14, 18 }, stroke = C.line, radius = 8, width = W }))
    end

    -- Library grid
    table.insert(blocks, col({
        spread(text(_("Library"), F.serif, 28), text(T(_("%1 issues"), #issues), F.sans, 13, C.muted), W, "bottom"),
        vspan(10), hline(W),
    }))
    local fixed = col(blocks, 32)
    local grid_h = H - fixed:getSize().h - px(32)

    local per_row = 5
    local gw = math.floor((W - px(16) * (per_row - 1)) / per_row)
    local gh = math.floor(gw * 4 / 3)
    local rest = {}
    for i = 2, #issues do table.insert(rest, issues[i]) end
    local row_h = gh + px(8) + px(18)
    local rows_per_page = math.max(1, math.floor((grid_h + px(20)) / (row_h + px(20))))
    local per_page = per_row * rows_per_page
    local pages = math.max(1, math.ceil(#rest / per_page))
    local page = math.min(view.page, pages)
    local grid = VerticalGroup:new{ align = "left" }
    for r = 0, rows_per_page - 1 do
        local line = HorizontalGroup:new{ align = "top" }
        for c = 1, per_row do
            local issue = rest[(page - 1) * per_page + r * per_row + c]
            if not issue then break end
            if c > 1 then table.insert(line, HorizontalSpan:new{ width = px(16) }) end
            table.insert(line, tap(col({ cover(view, issue, gw, gh), statusLine(readState(view.folio:localPath(issue))) }, 8),
                function() view:showContents(issue) end))
        end
        if #line > 0 then
            if r > 0 then table.insert(grid, vspan(20)) end
            table.insert(grid, line)
        end
    end
    table.insert(blocks, grid)
    return { col(blocks, 32) }, pages, page
end

-- Contents -------------------------------------------------------------------

local FORMAT_LABELS = {
    ["kindle"] = "EPUB · any screen",
    ["remarkable-paper-pro-move"] = "PDF · 7″",
    ["remarkable-2"] = "PDF · 10.3″",
    ["remarkable-paper-pro"] = "PDF · 11.8″",
    ["kindle-pdf"] = "PDF · 6–7″",
}

function UI.contents(view, W, H)
    local issue = view.contents_issue
    local detail = view.data.details and view.data.details[issue.id] or {}
    local crumb = tap(row({ icon("chevron-left", 15), text(_("Library"), F.sans, 13, C.muted), text("/", F.sans, 13, C.faint),
        text(T(_("Issue #%1"), issue.issue_number or "?"), F.sans_bold, 13) }, 6), function() view:go("issues") end)

    local info_w = W - px(96) - px(22)
    local when = utc(issue.completed_at or issue.created_at)
    local eb = (when and os.date("%A, %B ", when) .. tonumber(os.date("%d", when)) or "") ..
        (issue.total_read_time and (" · " .. minutes(issue.total_read_time)) or "")
    local formats = { text(_("Read as"), F.sans, 13, C.muted) }
    local current = view.folio:localFormat(issue)
    for __, r in ipairs(detail.renders or {}) do
        local label = FORMAT_LABELS[r.format]
        if label then
            local active = r.format == current
            local t = text(label, active and F.sans_bold or F.sans, 13, active and C.ink or C.muted)
            table.insert(formats, tap(col({ t, vspan(4), hline(t:getSize().w, active and C.ink or C.paper, 1.5) }),
                function() view:openIssue(issue, r.format) end))
        end
    end
    local header = row({
        tap(cover(view, issue, px(96), px(128)), function() view:openIssue(issue) end),
        col({
            eyebrow(eb, C.muted),
            row({ text(issueTitle(issue) .. ",", F.serif, 32), text(T(_("issue #%1."), issue.issue_number or "?"), F.serif_italic, 32) }, 8, "bottom"),
            row(formats, 20, "top"),
        }, 10),
    }, 22)

    local articles = detail.articles or {}
    local list_head = col({
        spread(eyebrow(_("In this issue")), text(T(_("%1 articles"), #articles), F.sans, 12, C.muted), W),
        vspan(8), hline(W, C.ink),
    })
    local top = col({ crumb, header, list_head }, 20)

    -- Highlights per article: KOReader stores the chapter title with each one.
    local counts = {}
    local path = view.folio:localPath(issue)
    if path and DocSettings:hasSidecarFile(path) then
        for __, a in ipairs(DocSettings:open(path):readSetting("annotations") or {}) do
            if a.chapter and a.text then counts[a.chapter] = (counts[a.chapter] or 0) + 1 end
        end
    end

    local rows, last_cat = {}, nil
    for i, a in ipairs(articles) do
        local cat = a.category
        if cat and cat ~= "" and cat ~= last_cat then
            table.insert(rows, box(text(cat, F.serif_italic, 19, C.muted), { padding = { 6, 0, 0, 0 } }))
            last_cat = cat
        end
        local n = counts[a.title] or 0
        local right = n > 0 and box(text(n == 1 and _("1 highlight") or T(_("%1 highlights"), n), F.sans_medium, 11),
            { padding = { 3, 8 }, fill = C.mark, radius = 3 }) or HorizontalSpan:new{ width = 0 }
        local tw = W - px(16) - px(32) - right:getSize().w - px(16)
        local meta = {}
        if a.source_name and a.source_name ~= "" then table.insert(meta, a.source_name) end
        if a.read_time_minutes then table.insert(meta, minutes(a.read_time_minutes)) end
        local line = HorizontalGroup:new{ align = "center",
            box(text(string.format("%02d", i), F.serif_regular, 15, C.faint), { width = px(32) }),
            hspan(16),
            col({ text(a.title or a.url or "", F.serif, 18, C.ink, tw), text(table.concat(meta, " · "), F.sans, 12, C.muted, tw) }, 2),
        }
        table.insert(rows, tap(col({ box(spread(line, right, W), { padding = { 9, 0 } }), hline(W) }),
            function() view:openIssue(issue, nil, a.title) end))
    end
    local pages = paginate(rows, H - top:getSize().h - px(20), 0)
    local page = math.min(view.page, #pages)
    local out = { top }
    local list = VerticalGroup:new{ align = "left" }
    for __, r in ipairs(pages[page]) do table.insert(list, r) end
    table.insert(out, list)
    return { col(out, 20) }, #pages, page
end

-- Inbox ----------------------------------------------------------------------

local ORIGINS = {
    { key = "link", label = _("Links"), icon = "link" },
    { key = "email", label = _("Newsletters"), icon = "mail" },
    { key = "rss", label = _("RSS"), icon = "rss" },
    { key = "extension", label = _("Extension"), icon = "puzzle" },
    { key = "webhook", label = _("Webhook"), icon = "link" },
    { key = "upload", label = _("Uploads"), icon = "link" },
}
local ORIGIN_BY_KEY = {}
for __, o in ipairs(ORIGINS) do ORIGIN_BY_KEY[o.key] = o end
local ORIGIN_SINGULAR = { link = _("Link"), email = _("Newsletter"), rss = _("RSS"), extension = _("Extension"), webhook = _("Webhook"), upload = _("Upload") }

function UI.inbox(view, W, H)
    local articles = view.data.articles or {}
    local total_min = 0
    local counts = {}
    for __, a in ipairs(articles) do
        total_min = total_min + (tonumber(a.read_time_minutes) or 0)
        local o = a.origin or "link"
        counts[o] = (counts[o] or 0) + 1
    end
    local add = tap(box(row({ icon("plus", 15), text(_("Add link"), F.sans_medium, 14) }, 6),
        { padding = { 10, 16 }, stroke = C.ink, stroke_width = 1.5, radius = 6 }), function() view.folio:promptLink(function() view:reload() end) end)
    local sub = #articles == 0 and _("Nothing waiting. Save links from your phone, or tap Add link.")
        or T(_("%1 articles waiting, about %2 of reading."), view.data.articles_total or #articles, minutes(total_min))
    local blocks = { heading(_("Inbox"), sub, add, W) }

    -- Next scheduled issue
    local nxt = view.data.next_run
    if nxt then
        local day = os.date("%A", nxt)
        if os.date("%Y%m%d", nxt) == os.date("%Y%m%d") then day = _("today") end
        table.insert(blocks, box(col({
            eyebrow(_("Next issue"), C.muted),
            row({ text(T(_("Issue #%1 arrives"), view.data.next_issue_number or "?"), F.serif, 21),
                  text(T(_("%1 at %2."), day, clock(nxt)), F.serif_italic, 21) }, 7, "bottom"),
        }, 6), { padding = { 16, 18 }, fill = C.surface, radius = 8, width = W }))
    end

    -- Origin filters
    local filters = {}
    local function filter(key, label, n)
        local active = view.inbox_filter == key
        local t = row({ text(label, active and F.sans_bold or F.sans, 14, active and C.ink or C.muted), text(tostring(n), F.sans, 14, C.faint) }, 6)
        return tap(col({ t, vspan(10), hline(t:getSize().w, active and C.ink or C.paper, 2) }),
            function() view.inbox_filter = key; view:setPage(1) end)
    end
    table.insert(filters, filter(nil, _("All"), #articles))
    for __, o in ipairs(ORIGINS) do
        if counts[o.key] then table.insert(filters, filter(o.key, o.label, counts[o.key])) end
    end
    table.insert(blocks, OverlapGroup:new{ dimen = Geom:new{ w = W, h = row(filters, 22, "bottom"):getSize().h },
        col({ vspan(0) }), row(filters, 22, "bottom") })
    table.insert(blocks, hline(W))

    -- Selection bar
    local sel_n, sel_min = 0, 0
    for __, a in ipairs(articles) do
        if view.selected[a.id] then sel_n = sel_n + 1; sel_min = sel_min + (tonumber(a.read_time_minutes) or 0) end
    end
    local bar
    if sel_n > 0 then
        local gen = tap(box(text(_("Generate issue"), F.sans_medium, 15), { padding = { 12, 18 }, fill = C.paper, radius = 6 }),
            function() view:generate() end)
        local tw = W - gen:getSize().w - px(46)
        bar = box(spread(col({
            text(T(_("%1 selected, %2."), sel_n, minutes(sel_min)), F.serif, 18, C.paper, tw),
            text(_("Turn them into an issue now."), F.sans, 12, C.line, tw),
        }, 2), gen, W - px(32)), { padding = { 12, 12, 12, 20 }, fill = C.ink, radius = 8, width = W })
    end

    -- Rows
    local rows = {}
    for __, a in ipairs(articles) do
        if not view.inbox_filter or (a.origin or "link") == view.inbox_filter then
            local ready = a.scrape_status == "done"
            local on = view.selected[a.id]
            local check = on and center(icon("check-white", 13), px(20), px(20), { fill = C.ink, stroke = C.ink, stroke_width = 1.5, radius = 4 })
                or center(VerticalSpan:new{ width = 0 }, px(20), px(20), { stroke = C.ink, stroke_width = 1.5, radius = 4 })
            local o = ORIGIN_BY_KEY[a.origin or "link"] or ORIGINS[1]
            local meta = {}
            -- Some newsletters arrive with a message id as their source name; skip those.
            local src = a.source_name
            if src and src ~= "" and not (#src > 32 and not src:find(" ")) then table.insert(meta, src) end
            table.insert(meta, ORIGIN_SINGULAR[a.origin or "link"] or "")
            if ready and a.read_time_minutes then table.insert(meta, minutes(a.read_time_minutes)) end
            if not ready then table.insert(meta, _("still loading")) end
            local tw = W - px(36)
            local r = row({ check, col({
                text(a.title or a.url or "", F.sans_medium, 15, ready and C.ink or C.faint, tw),
                row({ icon(o.icon, 12), text(table.concat(meta, " · "), F.sans, 13, C.muted, tw - px(18)) }, 6),
            }, 3) }, 16)
            table.insert(rows, tap(col({ box(r, { padding = { 11, 0 } }), hline(W) }), function()
                if not ready then return end
                view.selected[a.id] = (not on) or nil
                view:refresh()
            end))
        end
    end
    local fixed = col(blocks, 20)
    local avail = H - fixed:getSize().h - px(20) - (bar and (bar:getSize().h + px(20)) or 0)
    local pages = paginate(rows, avail, 0)
    local page = math.min(view.page, #pages)
    local list = VerticalGroup:new{ align = "left" }
    for __, r in ipairs(pages[page]) do table.insert(list, r) end
    local out = { fixed, list }
    local content = col(out, 0)
    if bar then
        -- Pin the bar to the bottom of the content area, like the design.
        local spacer = math.max(px(20), H - content:getSize().h - bar:getSize().h)
        content = col({ fixed, list, VerticalSpan:new{ width = spacer }, bar })
    end
    return { content }, #pages, page
end

-- Highlights -----------------------------------------------------------------

function UI.highlights(view, W, H)
    local groups = view.folio:collectHighlights()
    local total, articles = 0, 0
    for __, g in ipairs(groups) do total = total + #g.items; articles = articles + 1 end
    local export = tap(row({ text(_("Export"), F.sans, 13, C.muted), text(_("Markdown"), F.sans_medium, 13) }, 14),
        function() view.folio:exportHighlights(groups) end)
    local sub = total == 0 and _("Highlight text in any Folio issue and it shows up here.")
        or T(_("%1 highlights from %2 articles."), total, articles)
    local head = heading(_("Highlights"), sub, total > 0 and export or nil, W)

    -- One block per article; quotes inside it sit 12px apart, articles 30px.
    local rows = {}
    for __, g in ipairs(groups) do
        local src = eyebrow(g.source, C.muted, 10)
        local title_w = W - src:getSize().w - px(16)
        local parts = { col({ spread(text(g.title, F.serif, 20, C.ink, title_w), src, W, "bottom"), vspan(8), hline(W) }) }
        for __, h in ipairs(g.items) do
            local q = { para(h.text, F.serif_regular_italic, 20, C.ink, W - px(18), 1.45) }
            if h.note and h.note ~= "" then
                table.insert(q, box(row({ icon("pencil-line", 12), text(h.note, F.sans, 12, C.ink, W - px(60)) }, 8),
                    { padding = { 3, 8 }, fill = C.mark, radius = 3 }))
            end
            local body = col(q, 6)
            table.insert(parts, HorizontalGroup:new{ align = "top", vline(body:getSize().h, C.ink, 2), hspan(16), body })
        end
        table.insert(rows, col(parts, 12))
    end
    local pages = paginate(rows, H - head:getSize().h - px(30), 30)
    local page = math.min(view.page, #pages)
    return { col({ head, col(pages[page], 30) }, 30) }, #pages, page
end

-- Settings -------------------------------------------------------------------

function UI.settings(view, W, H)
    local folio = view.folio
    local me = view.data.me or {}
    local name = me.name or me.email or "Folio"
    local plan = me.plan and (me.plan:gsub("^%l", string.upper) .. " " .. _("plan")) or nil
    local connected = folio.settings:readSetting("connected_at")
    local device = (Device.model and Device.model ~= "") and Device.model or _("This reader")
    local avatar = center(text(name:sub(1, 1):upper(), F.serif, 20, C.paper), px(42), px(42), { fill = C.ink, radius = 21 })
    local disconnect = tap(text(_("Disconnect"), F.sans_medium, 13), function() view:disconnect() end)
    local tw = W - px(32) - px(42) - px(28) - disconnect:getSize().w
    local account = box(spread(row({ avatar, col({
        text(plan and (name .. " · " .. plan) or name, F.sans_bold, 15, C.ink, tw),
        row({ dot(6), text(connected and T(_("%1, connected %2"), device, os.date("%b ", connected) .. tonumber(os.date("%d", connected))) or device, F.sans, 13, C.muted, tw) }, 6),
    }, 3) }, 14), disconnect, W - px(32)), { padding = { 14, 16 }, fill = C.surface, radius = 8, width = W })

    local function section(title, items)
        local g = { box(eyebrow(title), { padding = { 0, 0, 8, 0 } }), hline(W, C.ink) }
        for __, it in ipairs(items) do
            local label = col({ text(it.label, F.sans_medium, 15), it.sub and text(it.sub, F.sans, 13, C.muted) or nil }, 2)
            local right
            if it.toggle ~= nil then
                right = toggle(it.toggle, it.callback)
            else
                right = row({ text(it.value or "", F.sans, 14, C.muted), icon("chevron-right", 16) }, 4)
            end
            local r = box(spread(label, right, W), { padding = { 11, 0 } })
            table.insert(g, it.toggle == nil and tap(r, it.callback) or r)
            table.insert(g, hline(W))
        end
        return col(g)
    end

    local keep = folio.settings:readSetting("keep_latest")
    local blocks = {
        text(_("Settings"), F.serif, 36),
        account,
        section(_("Sync"), {
            { label = _("Download new issues on Wi-Fi"), sub = _("Quietly, no pop-ups"), toggle = folio:autoSync(),
              callback = function() folio:save("auto_sync", not folio:autoSync()); view:refresh() end },
            { label = _("Save to"), value = folio:folderLabel(), callback = function() view:chooseFolder() end },
            { label = _("Keep on this reader"), value = keep and T(_("Latest %1 issues"), keep) or _("All issues"),
              callback = function()
                  local next_keep = { [false] = 4, [4] = 8, [8] = 12, [12] = false }
                  folio:save("keep_latest", next_keep[keep or false] or nil)
                  view:refresh()
              end },
            { label = _("Format"), value = folio:preferPdf() and "PDF" or "EPUB",
              callback = function() folio:save("prefer_pdf", not folio:preferPdf()); view:refresh() end },
        }),
        section(_("While reading"), {
            { label = _("Save links to Folio"), sub = _("Adds a button when you tap a link"), toggle = folio:linkButton(),
              callback = function() folio:save("link_button", not folio:linkButton()); view:refresh() end },
            { label = _("Delete finished issues"), sub = _("Frees space on the next sync"), toggle = folio.settings:isTrue("delete_finished"),
              callback = function() folio:save("delete_finished", not folio.settings:isTrue("delete_finished")); view:refresh() end },
        }),
    }
    local server = folio:server():gsub("^https://", "")
    table.insert(blocks, spread(
        text("folio.koplugin " .. folio.version, F.sans, 12, C.faint),
        tap(text(server == "myfolio.so" and _("Server") or server, F.sans_medium, 12), function() folio:promptServer(function() view:reload() end) end),
        W))
    return { col(blocks, 19) }, 1, 1
end

-- Connect --------------------------------------------------------------------

function UI.connect(view, W, H, full_w, full_h)
    local pairing = view.pairing
    local logo = ImageWidget:new{ file = DIR .. "wordmark.png", width = px(60), height = px(22.7) }
    local top = col({
        box(spread(row({ logo, text(_("for KOReader"), F.sans, 13, C.muted) }, 10, "bottom"),
            tap(text(_("Help"), F.sans, 14, C.muted), function() view.folio:showHelp() end), full_w - px(64)),
            { padding = { 0, 32 }, height = px(57) }),
        hline(full_w),
    })
    local cw = full_w - px(96)
    local function step(n, title, sub, extra)
        local num = center(text(tostring(n), F.serif, 17), px(36), px(36), { stroke = C.ink, stroke_width = 1.5, radius = 18 })
        local body = { text(title, F.sans_bold, 17), sub and text(sub, F.sans, 14, C.muted, cw - px(52)) or nil }
        if extra then table.insert(body, vspan(10)); table.insert(body, extra) end
        return HorizontalGroup:new{ align = "top", num, hspan(16), col({ vspan(6), col(body, 3) }) }
    end

    local code_card
    if pairing and pairing.user_code then
        local chars = {}
        local code = pairing.user_code
        for i = 1, #code do
            if i == 4 then table.insert(chars, text("–", F.serif, 54, C.faint)) end
            table.insert(chars, text(code:sub(i, i), F.serif, 54))
        end
        local code_row = row(chars, 12)
        local waiting = row({ dot(7), text(_("Waiting for approval · the code works for 10 minutes"), F.sans, 13, C.muted) }, 8)
        local inner_w = cw - px(52)
        code_card = FrameContainer:new{
            VerticalGroup:new{ align = "center", code_row, vspan(14), waiting },
            background = C.surface, bordersize = 0, radius = px(10), margin = 0,
            padding = 0, padding_top = px(20), padding_bottom = px(20),
            padding_left = math.floor((inner_w - code_row:getSize().w) / 2),
            padding_right = inner_w - code_row:getSize().w - math.floor((inner_w - code_row:getSize().w) / 2),
        }
    else
        code_card = box(text(pairing and pairing.error or _("Getting a code…"), F.sans, 15, C.muted, cw - px(96)),
            { padding = { 20, 22 }, fill = C.surface, radius = 10, width = cw - px(52) })
    end
    local host = pairing and pairing.verification_uri and pairing.verification_uri:gsub("^https?://", "") or "myfolio.so/link"
    local content = box(col({
        col({
            eyebrow(_("The Weekly Quiet · on KOReader"), C.muted),
            col({ text(_("Connect this reader."), F.serif, 50), text(_("Nothing to type."), F.serif_italic, 50) }),
            para(_("Approve one short code and your issues arrive here on their own, with covers and progress kept in step."), F.sans, 17, C.muted, cw, 1.6),
        }, 14),
        col({
            step(1, T(_("Open %1"), host), _("On your phone or computer, signed in to Folio.")),
            step(2, _("Enter this code"), nil, code_card),
            step(3, _("That is all"), _("New issues download whenever Wi-Fi is on.")),
        }, 20),
        spread(row({ text(_("New to Folio?"), F.sans, 14, C.muted), text(_("Try it at myfolio.so"), F.sans_medium, 14) }, 6),
            -- Testers point the plugin at another Folio server before pairing.
            tap(text(_("Server"), F.sans, 14, C.faint), function()
                view.folio:promptServer(function() view:close(); view.folio:showFolio() end)
            end), cw),
    }, 30), { padding = { 40, 48 } })

    -- Ghost wordmark, bleeding off the bottom like the design.
    local gw = px(580)
    local ghost = ImageWidget:new{ file = DIR .. "wordmark-ghost.png", width = gw, height = math.floor(gw * 242 / 640) }
    local fg = col({ UI.statusBar(full_w), top, content })
    return OverlapGroup:new{
        dimen = Geom:new{ w = full_w, h = full_h },
        center(VerticalSpan:new{ width = 0 }, full_w, full_h, { fill = C.paper }),
        FrameContainer:new{ ghost, bordersize = 0, padding = 0, margin = 0,
            padding_left = math.floor((full_w - gw) / 2), padding_top = full_h - math.floor(ghost:getSize().h * 0.72) },
        fg,
    }
end

-- Save-link sheet --------------------------------------------------------------

function UI.saveLinkSheet(folio, url, on_close)
    local W, H = Screen:getWidth(), Screen:getHeight()
    local sheet_w = px(624)
    local inner = sheet_w - px(44)
    local host = url:match("^%a+://([^/]+)") or url
    host = host:gsub("^www%.", "")
    local state = { category = nil }
    local widget

    local function build()
        local logo = ImageWidget:new{ file = DIR .. "wordmark.png", width = px(52), height = px(19.7) }
        local head = spread(logo, tap(icon("x", 20), function() on_close(widget) end), inner)
        local title = row({ text(_("Save this link to your"), F.serif, 26), text(_("inbox."), F.serif_italic, 26) }, 7, "bottom")
        local fav = center(icon("globe", 17), px(36), px(36), { fill = C.paper, stroke = C.line, radius = 6 })
        local path = url:gsub("^%a+://[^/]+", "")
        local link = box(row({ fav, col({
            text(host, F.sans_bold, 15, C.ink, inner - px(90)),
            text(path ~= "" and path or url, F.sans, 13, C.muted, inner - px(90)),
        }, 2) }, 12), { padding = { 12, 14 }, fill = C.surface, radius = 6, width = inner })
        local chips = { eyebrow(_("File under"), C.muted) }
        local cats = {}
        for i, c in ipairs(folio.settings:readSetting("categories") or {}) do
            if i <= 3 then table.insert(cats, c) end
        end
        table.insert(cats, false) -- "Let Folio pick"
        for __, c in ipairs(cats) do
            local active = state.category == (c or nil)
            local label = c or _("Let Folio pick")
            table.insert(chips, tap(box(text(label, F.sans_medium, 13, active and C.paper or C.ink),
                { padding = { 6, 12 }, fill = active and C.ink or C.paper, stroke = C.ink, stroke_width = 1.5, radius = 20 }),
                function() state.category = c or nil; widget:rebuild() end))
        end
        local buttons = row({
            button(_("Cancel"), "secondary", function() on_close(widget) end),
            button(_("Add to inbox"), "primary", function() on_close(widget); folio:saveLink(url, state.category) end),
        }, 10)
        local body = col({
            head, vspan(14 - 16), title, link, row(chips, 10),
            spread(HorizontalSpan:new{ width = 0 }, buttons, inner),
        }, 16)
        return box(body, { padding = { 18, 22, 20, 22 }, fill = C.paper, stroke = C.ink, stroke_width = 1.5, radius = 10 })
    end

    local Sheet = InputContainer:extend{ modal = true }
    function Sheet:init()
        self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }
        self.ges_events = { TapOutside = { GestureRange:new{ ges = "tap", range = self.dimen } } }
        self:rebuild()
    end
    function Sheet:rebuild()
        local card = build()
        local cs = card:getSize()
        self.card = card
        self[1] = FrameContainer:new{ card, bordersize = 0, margin = 0, padding = 0,
            padding_left = math.floor((W - cs.w) / 2), padding_top = H - cs.h - px(116), width = W, height = H }
        UIManager:setDirty(self, "ui")
    end
    function Sheet:onTapOutside(__, ges)
        if self.card.dimen and ges.pos:notIntersectWith(self.card.dimen) then on_close(self) end
        return true
    end
    widget = Sheet:new{}
    return widget
end

return UI
