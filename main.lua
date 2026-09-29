local ConfirmBox = require("ui/widget/confirmbox")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Screen = require("device").screen
local logger = require("logger")
local util = require("util")
local _ = require("i18n")
local T = require("ffi/util").template

local ForumClient = require("client")

local HOME_PAGE_SIZE = 10
local COMMENTS_PAGE_SIZE = 20
local COVER_UPLOAD_MAX_H = 400 -- px; plenty for a card thumbnail, keeps the upload ~20-40 KB
-- Only BMP symbols: the Kindle's fallback fonts (Noto/FreeSerif) have no color emoji.
local HEART_ON, HEART_OFF = "♥", "♡"

-- Splits "kindle, leitura #resenha" into {"kindle", "leitura", "resenha"} (# and , /  both work as separators).
local function parseHashtags(text)
    local tags = {}
    if not text or text == "" then
        return tags
    end
    for tag in text:gmatch("[#,]?%s*([%w_]+)") do
        table.insert(tags, tag:lower())
    end
    return tags
end

local function formatHashtags(tags)
    if not tags or #tags == 0 then
        return nil
    end
    local prefixed = {}
    for _idx, tag in ipairs(tags) do
        table.insert(prefixed, "#" .. tag)
    end
    return table.concat(prefixed, " ")
end

-- "2026-09-13T17:40:03.000Z" -> "13/09/2026 17:40" (pt_BR) or "09/13/2026 17:40" (en)
local function formatTimestamp(iso)
    if not iso then
        return nil
    end
    local y, mo, d, h, mi = iso:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+)")
    if not y then
        return iso
    end
    return T(_("%1/%2/%3 %4"), d, mo, y, h .. ":" .. mi)
end

-- "há 5 min", "há 3 h", "há 2 d"; older than a week falls back to the date.
local function relativeTime(iso)
    local y, mo, d, h, mi, s = (iso or ""):match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
    if not y then
        return formatTimestamp(iso) or ""
    end
    local now = os.time()
    -- os.time() reads the table as local time; shift by the local UTC offset to get the real epoch.
    local utc_offset = os.difftime(now, os.time(os.date("!*t", now)))
    local then_ = os.time{ year = tonumber(y), month = tonumber(mo), day = tonumber(d),
        hour = tonumber(h), min = tonumber(mi), sec = tonumber(s) } + utc_offset
    local diff = now - then_
    if diff < 60 then
        return _("agora")
    elseif diff < 3600 then
        return T(_("há %1 min"), math.floor(diff / 60))
    elseif diff < 86400 then
        return T(_("há %1 h"), math.floor(diff / 3600))
    elseif diff < 7 * 86400 then
        return T(_("há %1 d"), math.floor(diff / 86400))
    end
    return T(_("%1/%2/%3"), d, mo, y)
end

local function bookLine(title, author)
    if not title or title == "" then
        return nil
    end
    if author and author ~= "" then
        return T(_("%1, de %2"), title, author)
    end
    return title
end

-- Context shown above a composer: short enough to leave room for the field above the keyboard.
local function excerpt(text, max_chars)
    max_chars = max_chars or 140
    -- util.splitToChars keeps multibyte UTF-8 (accents) intact when cutting.
    local chars = util.splitToChars(text:gsub("%s+", " "))
    if #chars <= max_chars then
        return table.concat(chars)
    end
    return util.trim(table.concat(chars, "", 1, max_chars)) .. "…"
end

local function displayName(name, username)
    return (name and name ~= "") and name or username or "?"
end

-- 0-5 rating as ★★★☆☆ (★/☆ come from KOReader's own fallback fonts).
local function stars(rating)
    return string.rep("★", rating) .. string.rep("☆", 5 - rating)
end

local function likeLabel(item)
    return T("%1 %2", item.liked and HEART_ON or HEART_OFF, item.num_likes or 0)
end

-- The Kindle's UI fonts have no emoji, so the plugin ships Noto Emoji (monochrome,
-- crisp on e-ink; SIL OFL, see fonts/NotoEmoji-OFL.txt) and appends it to KOReader's UI
-- fallback fonts: emoji then render everywhere (picker, posts, comments, buttons).
local function registerEmojiFont(plugin_path)
    local Font = require("ui/font")
    local FontList = require("fontlist")
    local lfs = require("libs/libkoreader-lfs")
    -- Font:getFace opens FontList.fontdir .. "/" .. name, so point back up to the plugin dir.
    local name = "../" .. plugin_path .. "/fonts/NotoEmoji.ttf"
    if plugin_path:sub(1, 1) == "/" then
        -- Absolute plugin dir (desktop: ~/.config/koreader/plugins): climb from fontdir to "/".
        -- ponytail: one "../" per path segment of cwd+fontdir; extra ".." at "/" are harmless.
        local _, depth = (lfs.currentdir() .. "/" .. FontList.fontdir):gsub("[^/]+", "")
        name = string.rep("../", depth) .. plugin_path:sub(2) .. "/fonts/NotoEmoji.ttf"
    end
    if lfs.attributes(FontList.fontdir .. "/" .. name, "mode") ~= "file" then
        logger.warn("Inkwell: emoji font not found, emoji will show as boxes:", name)
        return
    end
    for _idx, fallback in ipairs(Font.fallbacks) do
        if fallback == name then
            return
        end
    end
    table.insert(Font.fallbacks, name)
    -- Faces already built cached "no more fallbacks" (false) past the old list's end.
    for _hash, face in pairs(Font.faces) do
        face.fallbacks = nil
    end
end

-- Picker tabs. Single-codepoint emoji only: they're one "char" for InputText, so the
-- cursor and backspace behave, and all are in Noto Emoji.
local EMOJI_CATEGORIES = {
    { label = "😀", emoji = { "😀", "😃", "😄", "😁", "😆", "😅", "😂", "🤣", "😊", "😇", "🙂", "😉",
        "😍", "🥰", "😘", "😋", "😎", "🤓", "🤔", "🤨", "😐", "😴", "🥱", "😢", "😭", "😱", "😡", "🤯",
        "🥳", "😬", "🙄", "😏" } },
    { label = "👍", emoji = { "👍", "👎", "👏", "🙌", "🙏", "👋", "🤞", "💪", "👀", "🤝", "👌", "🤘",
        "👉", "👆", "🫶", "🤗", "🤫", "🤷", "🙋", "🙇", "💁", "🧐", "🫡", "💃" } },
    { label = "❤", emoji = { "❤", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍", "💔", "💕", "💖", "💘",
        "✨", "⭐", "🌟", "🔥", "💯", "🎉", "🎊", "🏆", "👑", "💎", "🌈", "🍀" } },
    { label = "📚", emoji = { "📚", "📖", "📕", "📗", "📘", "📙", "📓", "📔", "📝", "🔖", "📑", "📜",
        "🖋", "🖊", "💡", "🧠", "☕", "🍵", "🍷", "🌙", "🕯", "🛋", "🎧", "🐱" } },
}
local EMOJI_PER_ROW = 8

-- Runs fn inside Trapper:wrap on the next UIManager tick, instead of immediately.
-- Needed because our callers just closed a dialog (and its virtual keyboard); starting
-- the blocking network call in the same tick can make the UI stack skip showing the
-- next widget and fall back to whatever was behind it (e.g. the book being read).
local function deferredTrap(fn)
    UIManager:scheduleIn(0, function()
        Trapper:wrap(fn)
    end)
end

local Inkwell = WidgetContainer:extend{
    name = "inkwell",
    is_doc_only = false,
}

function Inkwell:onDispatcherRegisterActions()
    Dispatcher:registerAction("inkwell_open", {
        category = "none",
        event = "InkwellOpen",
        title = _("Open Inkwell"),
        general = true,
    })
end

function Inkwell:init()
    registerEmojiFont(self.path)
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    if self.document then
        self:addToHighlightDialog()
    end
end

function Inkwell:addToHighlightDialog()
    self.ui.highlight:addToHighlightDialog("inkwell_publish", function(this)
        return {
            text = _("Publicar no Inkwell"),
            callback = function()
                local text = util.cleanupSelectedText(this.selected_text.text)
                this:onClose()
                local book = self:currentBook() or {}
                self:openPublishDialog(text, book.title, book.author)
            end,
        }
    end)
    self.ui.highlight:addToHighlightDialog("inkwell_bio", function(this)
        return {
            text = _("Usar como bio no Inkwell"),
            callback = function()
                local text = util.cleanupSelectedText(this.selected_text.text)
                this:onClose()
                if not ForumClient.isLoggedIn() then
                    self:openLoginDialog()
                    return
                end
                NetworkMgr:runWhenOnline(function() self:openEditProfile(text) end)
            end,
        }
    end)
end

function Inkwell:addToMainMenu(menu_items)
    menu_items.inkwell = {
        text = _("Inkwell"),
        sorting_hint = "tools",
        callback = function()
            self:openForum()
        end,
    }
end

function Inkwell:onInkwellOpen()
    self:openForum()
    return true
end

-- Runs fetch_fn() (a blocking ForumClient call returning value or nil+err) behind a
-- "Carregando…" notice, then on_ok(value); on failure shows the error instead.
function Inkwell:load(fetch_fn, on_ok, busy_text)
    deferredTrap(function()
        Trapper:info(busy_text or _("Carregando…"))
        local result, err = fetch_fn()
        Trapper:clear()
        if not result then
            UIManager:show(InfoMessage:new{ text = T(_("Falha: %1"), err) })
            return
        end
        on_ok(result)
    end)
end

-- ---------------------------------------------------------------------------
-- Reading: shelf sync and auto-posts
-- ---------------------------------------------------------------------------

-- The book open in this reader instance, or nil (file browser / no metadata).
function Inkwell:currentBook()
    if not self.document then
        return nil
    end
    local props = self.ui.doc_props or {}
    local title = props.display_title or props.title
    if not title or title == "" then
        return nil
    end
    local page, total = self.ui:getCurrentPage(), self.document:getPageCount()
    return {
        title = title,
        author = props.authors and props.authors:gsub("\n", ", ") or nil,
        progress = (page and total and total > 0) and math.floor(page * 100 / total) or 0,
    }
end

-- Scales bb down to fit max_w x max_h (aspect kept), frees it, and returns it as
-- { data = base64 JPEG, content_type } for upload, or nil if encoding failed.
local function encodeJpeg(bb, max_w, max_h)
    local scale = math.min(1, max_w / bb:getWidth(), max_h / bb:getHeight())
    bb = require("ui/renderimage"):scaleBlitBuffer(bb,
        math.floor(bb:getWidth() * scale), math.floor(bb:getHeight() * scale), true)
    local path = require("datastorage"):getDataDir() .. "/cache/inkwell_upload.jpg"
    bb:writeToFile(path, "jpg", 80)
    bb:free()
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local raw = f:read("*a")
    f:close()
    os.remove(path)
    if not raw or raw == "" then
        return nil
    end
    return { data = (require("mime").b64(raw)), content_type = "image/jpeg" }
end

-- Blocking: the open book's cover (custom cover if set) as { data = base64 JPEG,
-- content_type }, scaled down to COVER_UPLOAD_MAX_H, or nil when there's no document
-- open, it's a different book than book_title, or it has no cover.
function Inkwell:currentCover(book_title)
    local book = self:currentBook()
    if not book or book.title ~= book_title or not self.ui.bookinfo then
        return nil
    end
    local ok, cover = pcall(function()
        local bb = self.ui.bookinfo:getCoverImage(self.document)
        return bb and encodeJpeg(bb, math.huge, COVER_UPLOAD_MAX_H)
    end)
    if not ok then
        logger.warn("Inkwell: cover extraction failed", cover)
        return nil
    end
    return cover
end

-- Blocking: pushes the open book to the user's shelf. Returns "started" / "finished" when
-- this push started or finished the book (the server reports it once per book) and the
-- user wants to be asked about sharing it (see offerReadingPost).
function Inkwell:syncReading(status)
    local book = self:currentBook()
    if not book or not ForumClient.isLoggedIn() then
        return
    end
    local result = ForumClient.pushReading(book.title, book.author, status == "finished" and 100 or book.progress, status)
    if not result or not G_reader_settings:nilOrTrue("inkwell_auto_share") then
        return
    end
    return (result.finished_now and "finished") or (result.started and "started") or nil
end

-- Asks before posting "comecei/terminei o livro"; nothing is posted without an OK. The
-- server writes the post and checks the event against the shelf; the client only sends
-- the event, its UI language and the cover.
function Inkwell:offerReadingPost(event)
    local book = self:currentBook()
    if not event or not book then
        return
    end
    UIManager:show(ConfirmBox:new{
        text = T(event == "finished" and _("Postar que você terminou “%1”?") or _("Postar que você começou a ler “%1”?"),
            book.title),
        ok_text = _("Publicar"),
        cancel_text = _("Agora não"),
        ok_callback = function()
            self:load(function()
                return ForumClient.createTopic{
                    reading_event = event,
                    lang = _.lang(),
                    book_title = book.title,
                    book_author = book.author,
                    cover = self:currentCover(book.title),
                }
            end, function()
                UIManager:show(InfoMessage:new{ text = _("Publicado no Inkwell!"), timeout = 2 })
            end, _("Publicando…"))
        end,
    })
end

-- KOReader broadcasts this at the last page. Not returning true lets its own end-of-book dialog run.
function Inkwell:onEndOfBook()
    if ForumClient.isLoggedIn() and NetworkMgr:isOnline() then
        UIManager:scheduleIn(1, function()
            local ok, event = pcall(self.syncReading, self, "finished")
            if ok then
                self:offerReadingPost(event)
            else
                logger.warn("Inkwell: end-of-book sync failed", event)
            end
        end)
    end
end

-- Closing the book saves where the user stopped, so the shelf % is current even when
-- Inkwell wasn't opened. Background push: the server only updates books already on the
-- shelf and never finishes one here, since there's no book left to ask about sharing.
function Inkwell:onCloseDocument()
    local book = self:currentBook()
    if not book or not ForumClient.isLoggedIn() or not NetworkMgr:isOnline() then
        return
    end
    -- Next tick: the book closes first instead of waiting on the network.
    UIManager:scheduleIn(0, function()
        local ok, err = pcall(ForumClient.pushReading, book.title, book.author, book.progress, nil, true)
        if not ok then
            logger.warn("Inkwell: close sync failed", err)
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Screen building blocks
-- ---------------------------------------------------------------------------

-- Every full screen in the plugin uses this, so the UI stays consistent: the same frame
-- as TextViewer — centered, rounded, 30px smaller than the screen —
-- with a title bar, a vertically scrollable column of rows and a ButtonTable footer.
-- opts: title, subtitle, on_menu (☰ tap; no icon if nil), build_rows(row_w, container) ->
-- widgets no wider than row_w, buttons (ButtonTable rows; no footer when empty — the title bar X closes).
-- Returns the shown widget, for callers that need to UIManager:close() it.
function Inkwell:showModal(opts)
    local Blitbuffer = require("ffi/blitbuffer")
    local ButtonTable = require("ui/widget/buttontable")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local Geom = require("ui/geometry")
    local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
    local Size = require("ui/size")
    local TitleBar = require("ui/widget/titlebar")
    local VerticalGroup = require("ui/widget/verticalgroup")

    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    -- Full screen: every pixel goes to content, nothing of the file browser shows around it.
    local modal_w, modal_h = screen_w, screen_h

    -- Created up front (child set below) so build_rows can use it as a parent, e.g. for InputText.
    local container = CenterContainer:new{ dimen = Geom:new{ w = screen_w, h = screen_h } }
    local titlebar = TitleBar:new{
        title = opts.title,
        subtitle = opts.subtitle,
        width = modal_w,
        align = "left",
        with_bottom_line = true,
        left_icon = opts.on_menu and "appbar.menu" or nil,
        left_icon_tap_callback = opts.on_menu,
        close_callback = function() UIManager:close(container) end,
    }

    local button_table = opts.buttons and #opts.buttons > 0 and ButtonTable:new{
        width = modal_w - 2 * Size.padding.default,
        zero_sep = true,
        buttons = opts.buttons,
    }
    local footer_h = button_table and button_table:getSize().h or 0

    -- Rows leave room for the vertical scrollbar; wider rows would overflow the crop
    -- area and make ScrollableContainer add a horizontal scroll.
    local row_w = modal_w - ScrollableContainer:getScrollbarWidth()
    local content_h = modal_h - titlebar:getHeight() - footer_h
    local scroll = ScrollableContainer:new{
        dimen = Geom:new{ w = modal_w, h = content_h }, -- must be a Geom: its gesture check calls dimen:area()
        VerticalGroup:new(opts.build_rows(row_w, container)),
    }

    container[1] = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            titlebar,
            scroll,
            button_table and CenterContainer:new{
                dimen = Geom:new{ w = modal_w, h = footer_h },
                button_table,
            } or nil,
        },
    }
    -- Children are built before container is complete; without show_parent the
    -- scroll's setDirty targets nil and swipes never repaint.
    scroll.show_parent = container
    if button_table then button_table.show_parent = container end
    titlebar.show_parent = container
    container.cropping_widget = scroll
    container.covers_fullscreen = true -- UIManager skips repainting what's beneath
    -- Explicit refresh: without it the screen is only painted to the framebuffer, and a
    -- modal opened straight from a tap (e.g. ☰, with nothing closing beneath it) stays
    -- invisible on e-ink except for whatever the tap's own highlight refreshes.
    UIManager:show(container, "ui", container.dimen)
    return container
end

-- Text inputs for a showModal form. InputText expects its parent to switch focus between
-- fields (MultiInputDialog's onSwitchFocus); here the modal container takes that role.
-- specs: { text, hint, label, text_type, input_type, multiline }. Enter moves to the next field, and submits
-- on the last; in a multiline field Enter is a newline instead (tap the next field).
-- Returns rows (fields + "show password" toggles) and the InputText list, for getText().
function Inkwell:buildFormFields(container, row_w, specs, on_submit)
    local FrameContainer = require("ui/widget/container/framecontainer")
    local InputText = require("ui/widget/inputtext")
    local Size = require("ui/size")

    local fields, rows = {}, {}
    local current
    -- While the keyboard is open it's the top window, and UIManager only hands taps it
    -- ignores to windows flagged always-active (as InputDialog is) — without this, tapping
    -- another field did nothing and Enter was the only way to move on.
    container.is_always_active = true
    function container:onSwitchFocus(inputbox)
        if inputbox ~= current then
            if current then
                current:unfocus()
                current:onCloseKeyboard()
            end
            current = inputbox
            current:focus()
            container.focused_field = current
        end
        current:onShowKeyboard()
    end
    -- On DPad devices (desktop, Kindles with keys) InputText's tap calls this unguarded,
    -- expecting a FocusManager parent. No DPad focus here: nil skips its moveFocusTo.
    function container:getFocusableWidgetXY() end
    -- The keyboard is its own window: close it along with the modal (X, submit).
    function container:onCloseWidget()
        if current then current:onCloseKeyboard() end
    end

    -- InputText's width is its text area; its frame adds padding + margin + border on each side.
    local frame_extra = 2 * (Size.padding.default + Size.margin.default + Size.border.inputtext)
    for i, spec in ipairs(specs) do
        -- The hint disappears once a field has text, so forms with prefilled values need a label.
        if spec.label then
            table.insert(rows, self:textRow(spec.label, row_w, { dim = true, size = 14, compact = true }))
        end
        fields[i] = InputText:new{
            text = spec.text or "",
            hint = spec.hint,
            text_type = spec.text_type,
            input_type = spec.input_type,
            width = row_w - 2 * Size.padding.large - frame_extra,
            height = spec.multiline and Screen:scaleBySize(150) or nil,
            scroll = spec.multiline or nil,
            parent = container,
            focused = false, -- nothing focused until the user taps a field
            -- no enter_callback on multiline fields: InputText then inserts "\n"
            enter_callback = not spec.multiline and function()
                if fields[i + 1] then
                    container:onSwitchFocus(fields[i + 1])
                else
                    on_submit()
                end
            end or nil,
        }
        for _idx, widget in ipairs({ fields[i], fields[i]:getPasswordToggleWidget() }) do
            table.insert(rows, FrameContainer:new{
                bordersize = 0,
                padding = 0,
                padding_left = Size.padding.large,
                padding_right = Size.padding.large,
                widget,
            })
        end
    end
    return rows, fields
end

-- A row of buttons inside showModal content (not the footer). Forms use it for their
-- actions: the footer sits at the screen bottom, where the virtual keyboard covers it.
-- Light by default (16, regular): content is what's read, actions stay secondary.
-- indent (px, optional) shifts the row right, e.g. under a reply.
function Inkwell:buttonRow(buttons, row_w, container, indent)
    local ButtonTable = require("ui/widget/buttontable")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local Size = require("ui/size")
    indent = indent or 0
    for _idx, button in ipairs(buttons) do
        button.font_size = button.font_size or 16
        if button.font_bold == nil then button.font_bold = false end
    end
    return FrameContainer:new{
        bordersize = 0,
        padding = Size.padding.large,
        padding_left = Size.padding.large + indent,
        padding_top = Size.padding.small,
        padding_bottom = Size.padding.small,
        ButtonTable:new{
            width = row_w - 2 * Size.padding.large - indent,
            buttons = { buttons },
            show_parent = container,
        },
    }
end

-- Splits a flat button list into buttonRows of up to per_row buttons each.
function Inkwell:buttonRows(buttons, per_row, row_w, container)
    local rows, current = {}, {}
    for _idx, button in ipairs(buttons) do
        table.insert(current, button)
        if #current == per_row then
            table.insert(rows, self:buttonRow(current, row_w, container))
            current = {}
        end
    end
    if #current > 0 then
        table.insert(rows, self:buttonRow(current, row_w, container))
    end
    return rows
end

-- A plain padded text row for showModal. opts: bold, dim, size (font size, default 16), indent (px),
-- compact (small vertical padding, for dense lists).
function Inkwell:textRow(text, row_w, opts)
    opts = opts or {}
    local Blitbuffer = require("ffi/blitbuffer")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local Size = require("ui/size")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local indent = opts.indent or 0
    return FrameContainer:new{
        bordersize = 0,
        padding = Size.padding.large,
        padding_left = Size.padding.large + indent,
        padding_top = opts.compact and Size.padding.small or nil,
        padding_bottom = opts.compact and Size.padding.small or nil,
        TextBoxWidget:new{
            text = text,
            face = require("ui/font"):getFace("cfont", opts.size or 16),
            bold = opts.bold,
            fgcolor = opts.dim and Blitbuffer.COLOR_DARK_GRAY or nil,
            width = row_w - 2 * Size.padding.large - indent,
        },
    }
end

function Inkwell:sectionRow(text, row_w)
    return self:textRow(text, row_w, { bold = true, size = 18 })
end

function Inkwell:separator(row_w)
    local Blitbuffer = require("ffi/blitbuffer")
    local Geom = require("ui/geometry")
    local LineWidget = require("ui/widget/linewidget")
    local Size = require("ui/size")
    return LineWidget:new{
        dimen = Geom:new{ w = row_w, h = Size.line.thin },
        background = Blitbuffer.COLOR_LIGHT_GRAY,
    }
end

-- Wraps an arbitrary widget in an InputContainer so tapping anywhere on it fires
-- on_tap — used to make a whole feed card tappable without turning it into a Menu row.
function Inkwell:wrapTappable(widget, on_tap)
    local Geom = require("ui/geometry")
    local GestureRange = require("ui/gesturerange")
    local InputContainer = require("ui/widget/container/inputcontainer")

    local size = widget:getSize()
    local wrapped = InputContainer:new{
        dimen = Geom:new{ w = size.w, h = size.h },
        widget,
    }
    wrapped.ges_events = {
        Tap = {
            GestureRange:new{
                ges = "tap",
                range = wrapped.dimen,
            },
        },
    }
    function wrapped:onTap()
        on_tap()
        return true
    end
    return wrapped
end

-- Avatar + bold name + dim second line, as used by cards, people lists and notifications.
-- verified: a seal after the name (supporters, per the server's author_premium).
function Inkwell:avatarHeader(username, avatar_url, name, subline, w, avatar_size, verified)
    local Avatar = require("avatar")
    local Blitbuffer = require("ffi/blitbuffer")
    local Font = require("ui/font")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local LeftContainer = require("ui/widget/container/leftcontainer")
    local Size = require("ui/size")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local VerticalGroup = require("ui/widget/verticalgroup")

    avatar_size = avatar_size or Screen:scaleBySize(40)
    local col_w = w - avatar_size - Size.span.horizontal_default
    local name_face = Font:getFace("cfont", 17)
    local name_widget
    if verified then
        -- Seal: white ✔ on a black circle, one line tall; the name is truncated to make room.
        local CenterContainer = require("ui/widget/container/centercontainer")
        local FrameContainer = require("ui/widget/container/framecontainer")
        local TextWidget = require("ui/widget/textwidget")
        local seal_size = math.floor(name_face.size * 0.9)
        local seal = FrameContainer:new{
            bordersize = 0,
            padding = 0,
            radius = math.floor(seal_size / 2),
            background = Blitbuffer.COLOR_BLACK,
            CenterContainer:new{
                dimen = { w = seal_size, h = seal_size },
                TextWidget:new{ text = "✔", face = Font:getFace("cfont", 10), fgcolor = Blitbuffer.COLOR_WHITE },
            },
        }
        local gap = Size.span.horizontal_small
        name_widget = HorizontalGroup:new{
            align = "center",
            TextWidget:new{ text = name, face = name_face, bold = true, max_width = col_w - seal_size - gap },
            HorizontalSpan:new{ width = gap },
            seal,
        }
    else
        name_widget = TextBoxWidget:new{ text = name, face = name_face, bold = true, width = col_w }
    end
    local col = VerticalGroup:new{ align = "left", name_widget }
    if subline and subline ~= "" then
        table.insert(col, TextBoxWidget:new{
            text = subline,
            face = Font:getFace("cfont", 14),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            width = col_w,
        })
    end
    local avatar = Avatar.widget(Avatar.ensureLocal(username, avatar_url), avatar_size, username)
    return HorizontalGroup:new{
        align = "top",
        avatar,
        HorizontalSpan:new{ width = Size.span.horizontal_default },
        LeftContainer:new{
            dimen = { w = col_w, h = math.max(avatar_size, col:getSize().h) },
            col,
        },
    }
end

-- The quoted post, as a small gray box inside a card or above the composer.
function Inkwell:quoteBox(quoted, w)
    local Blitbuffer = require("ffi/blitbuffer")
    local Font = require("ui/font")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local Size = require("ui/size")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local body = util.trim(((quoted.title or "") .. "\n" .. (quoted.selftext or "")))
    return FrameContainer:new{
        bordersize = Size.border.thin,
        color = Blitbuffer.COLOR_DARK_GRAY,
        padding = Size.padding.default,
        radius = Size.radius.button,
        TextBoxWidget:new{
            text = T(_("%1 (@%2)\n%3"), displayName(quoted.author_display_name, quoted.author), quoted.author, body),
            face = Font:getFace("cfont", 14),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            width = w - 2 * Size.padding.default - 2 * Size.border.thin,
        },
    }
end

-- One post card: avatar + name + "@handle · há 2h", then the text box (optional bold
-- title, body, quoted post), then a dim "book · #tags" line. full = post screen: shows
-- the community line and never truncates (feed summaries already come trimmed).
function Inkwell:buildFeedCard(topic, card_w, full)
    local Blitbuffer = require("ffi/blitbuffer")
    local Font = require("ui/font")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local Size = require("ui/size")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")

    local pad = Size.padding.large
    local inner_w = card_w - 2 * pad
    -- FrameContainer's size ignores `width`: subtract border too or the card overflows.
    local text_w = inner_w - 2 * Size.padding.default - 2 * Size.border.thin

    local subline = T(_("@%1 · %2"), topic.author or "?", relativeTime(topic.created_at))
    if topic.community and full then
        subline = T(_("%1 · em %2"), subline, topic.community.title)
    end

    local body = VerticalGroup:new{ align = "left" }
    if topic.rating then
        table.insert(body, TextBoxWidget:new{
            text = stars(topic.rating), face = Font:getFace("cfont", 18), width = text_w,
        })
    end
    if topic.title and topic.title ~= "" then
        table.insert(body, TextBoxWidget:new{
            text = topic.title, face = Font:getFace("cfont", 17), bold = true, width = text_w,
        })
    end
    if topic.selftext and topic.selftext ~= "" then
        table.insert(body, TextBoxWidget:new{
            text = topic.selftext, face = Font:getFace("cfont", 16), width = text_w,
        })
    end
    if topic.quoted then
        table.insert(body, VerticalSpan:new{ width = Size.span.vertical_default })
        table.insert(body, self:quoteBox(topic.quoted, text_w))
    end

    local rows = {
        align = "left",
        self:avatarHeader(topic.author, topic.author_avatar_url,
            displayName(topic.author_display_name, topic.author), subline, inner_w, nil, topic.author_premium),
        VerticalSpan:new{ width = Size.span.vertical_default },
        FrameContainer:new{
            bordersize = Size.border.thin,
            color = Blitbuffer.COLOR_LIGHT_GRAY,
            padding = Size.padding.default,
            radius = Size.radius.window,
            body,
        },
    }

    local meta = {}
    table.insert(meta, bookLine(topic.book_title, topic.book_author))
    table.insert(meta, formatHashtags(topic.hashtags))
    if #meta > 0 then
        -- With a cover, the book line sits next to its thumbnail (bigger on the post screen).
        local cover_h = Screen:scaleBySize(full and 150 or 72)
        local cover = topic.book_cover_url and topic.book_title
            and require("avatar").cover(topic.book_cover_url, math.floor(cover_h * 2 / 3), cover_h)
        local gap = Size.span.horizontal_default
        local meta_w = cover and (inner_w - cover:getSize().w - gap) or inner_w
        local meta_box = TextBoxWidget:new{
            text = table.concat(meta, " · "),
            face = Font:getFace("cfont", 14),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            width = meta_w,
        }
        table.insert(rows, VerticalSpan:new{ width = Size.span.vertical_small })
        if cover then
            table.insert(rows, require("ui/widget/horizontalgroup"):new{
                align = "center",
                cover,
                require("ui/widget/horizontalspan"):new{ width = gap },
                meta_box,
            })
        else
            table.insert(rows, meta_box)
        end
    end

    return FrameContainer:new{
        width = card_w,
        bordersize = 0,
        padding = pad,
        padding_bottom = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new(rows),
    }
end

-- A feed entry: tappable card (opens the post) + a ♥ / comments action row + separator.
-- rerender() redraws the screen after a like changed the topic in place.
function Inkwell:feedItem(topic, row_w, container, rerender)
    local VerticalGroup = require("ui/widget/verticalgroup")
    return VerticalGroup:new{
        self:wrapTappable(self:buildFeedCard(topic, row_w), function() self:openThread(topic) end),
        self:buttonRow({
            { text = likeLabel(topic), callback = function() self:toggleTopicLike(topic, rerender) end },
            { text = T(_("Comentários (%1)"), topic.num_comments or 0), callback = function() self:openThread(topic) end },
        }, row_w, container),
        self:separator(row_w),
    }
end

function Inkwell:feedItems(topics, row_w, container, rerender, empty_text)
    local rows = {}
    if #topics == 0 then
        table.insert(rows, self:textRow(empty_text or _("Nenhum post ainda."), row_w, { dim = true }))
    end
    for _idx, topic in ipairs(topics) do
        table.insert(rows, self:feedItem(topic, row_w, container, rerender))
    end
    return rows
end

-- A person: tappable avatar/name/reason (opens the profile) + Seguir/Seguindo button.
function Inkwell:personRow(user, row_w, container, rerender)
    local Button = require("ui/widget/button")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local Size = require("ui/size")

    local inner_w = row_w - 2 * Size.padding.large
    local is_me = user.username == ForumClient.username()
    local button_w = is_me and 0 or math.floor(inner_w * 0.3)
    local header_w = inner_w - button_w - (is_me and 0 or Size.span.horizontal_default)
    local subline = T(_("@%1"), user.username)
    local extra = user.reason or user.bio
    if extra and extra ~= "" then
        subline = subline .. "\n" .. extra
    end
    local group = HorizontalGroup:new{
        align = "center",
        self:wrapTappable(self:avatarHeader(user.username, user.avatar_url,
            displayName(user.display_name, user.username), subline, header_w),
            function() self:openUserProfile(user.username) end),
    }
    if not is_me then
        table.insert(group, HorizontalSpan:new{ width = Size.span.horizontal_default })
        table.insert(group, Button:new{
            text = user.followed_by_me and _("Seguindo ✓") or _("Seguir"),
            width = button_w,
            show_parent = container,
            callback = function() self:toggleFollow(user, rerender) end,
        })
    end
    return FrameContainer:new{ bordersize = 0, padding = Size.padding.large, group }
end

-- ---------------------------------------------------------------------------
-- Actions shared by several screens
-- ---------------------------------------------------------------------------

function Inkwell:toggleTopicLike(topic, rerender)
    local liking = not topic.liked
    self:load(function() return ForumClient.setTopicLike(topic.id, liking) end, function(result)
        topic.liked, topic.num_likes = result.liked, result.num_likes
        rerender()
    end, liking and _("Curtindo…") or _("Removendo curtida…"))
end

function Inkwell:toggleCommentLike(comment, rerender)
    local liking = not comment.liked
    self:load(function() return ForumClient.setCommentLike(comment.id, liking) end, function(result)
        comment.liked, comment.num_likes = result.liked, result.num_likes
        rerender()
    end, liking and _("Curtindo…") or _("Removendo curtida…"))
end

-- user: anything with username + followed_by_me (a person card or a full profile; a
-- profile also gets its follower count refreshed).
function Inkwell:toggleFollow(user, rerender)
    local following = not user.followed_by_me
    self:load(function() return ForumClient.setFollow(user.username, following) end, function(result)
        user.followed_by_me = result.following
        if user.num_followers then
            user.num_followers = result.num_followers
        end
        rerender()
    end, following and _("Seguindo…") or _("Deixando de seguir…"))
end

-- ---------------------------------------------------------------------------
-- Composer (every text input screen)
-- ---------------------------------------------------------------------------

-- Full-screen form. opts: title, intro_rows(row_w) -> rows shown above the fields,
-- fields (buildFormFields specs), submit_text, validate(values) -> error text or nil,
-- on_submit(values) (runs after the screen closes, once online), on_cancel,
-- emoji (true: offer the emoji keyboard; it inserts into the focused field, else the
-- first multiline one). emoji_tab / emoji_field are internal: the open picker tab and the
-- last focused field, kept across redraws.
function Inkwell:openComposer(opts)
    local modal, fields, container_ref
    local function values()
        local v = {}
        for i, field in ipairs(fields) do
            v[i] = field:getText()
        end
        return v
    end
    local function submit()
        local v = values()
        local problem = opts.validate and opts.validate(v)
        if problem then
            UIManager:show(InfoMessage:new{ text = problem })
            return
        end
        UIManager:close(modal)
        NetworkMgr:runWhenOnline(function() opts.on_submit(v) end)
    end
    local function cancel()
        UIManager:close(modal)
        if opts.on_cancel then opts.on_cancel() end
    end
    -- Redraw with the picker on another tab (or closed), keeping what was typed.
    local function reopenWithTab(tab)
        local v = values()
        local new_opts = {}
        for k, val in pairs(opts) do new_opts[k] = val end
        new_opts.fields = {}
        for i, spec in ipairs(opts.fields) do
            local copy = {}
            for k, val in pairs(spec) do copy[k] = val end
            copy.text = v[i]
            new_opts.fields[i] = copy
        end
        new_opts.emoji_tab = tab
        -- Redrawing drops focus: remember the field so emoji keep going where the user was typing.
        for i, field in ipairs(fields) do
            if field == container_ref.focused_field then new_opts.emoji_field = i end
        end
        UIManager:close(modal)
        self:openComposer(new_opts)
    end
    local function insertEmoji(emoji)
        local target = container_ref.focused_field or fields[opts.emoji_field]
        if not target then
            for i, spec in ipairs(opts.fields) do
                if spec.multiline then target = fields[i] break end
            end
        end
        (target or fields[1]):addChars(emoji)
    end

    modal = self:showModal{
        title = opts.title,
        build_rows = function(row_w, container)
            container_ref = container
            -- Actions go first: the virtual keyboard covers the bottom half of the screen,
            -- and ScrollableContainer doesn't scroll to keep anything below the field visible.
            local actions = {
                { text = _("Cancelar"), callback = cancel },
            }
            if opts.emoji then
                table.insert(actions, {
                    text = opts.emoji_tab and _("Fechar emojis") or _("😀 Emojis"),
                    callback = function() reopenWithTab(not opts.emoji_tab and 1 or nil) end,
                })
            end
            table.insert(actions, { text = opts.submit_text or _("Enviar"), callback = submit })
            local rows = { self:buttonRow(actions, row_w, container) }
            -- reopen() redraws the composer keeping what was typed (e.g. after picking a star).
            util.arrayAppend(rows, opts.intro_rows
                and opts.intro_rows(row_w, container, function() reopenWithTab(opts.emoji_tab) end) or {})
            -- The picker sits above the fields too, so it stays usable with the keyboard up.
            if opts.emoji_tab then
                util.arrayAppend(rows, self:emojiPicker(row_w, container, opts.emoji_tab, insertEmoji, reopenWithTab))
            end
            local field_rows
            field_rows, fields = self:buildFormFields(container, row_w, opts.fields, submit)
            util.arrayAppend(rows, field_rows)
            return rows
        end,
    }
end

-- Emoji keyboard: a tab row (one per category) and the tab's emoji in a grid.
-- Tapping an emoji calls on_pick(emoji); tapping a tab calls on_tab(index).
function Inkwell:emojiPicker(row_w, container, tab, on_pick, on_tab)
    local tabs = {}
    for i, category in ipairs(EMOJI_CATEGORIES) do
        table.insert(tabs, {
            text = (i == tab and "● " or "") .. category.label,
            callback = function()
                if i ~= tab then on_tab(i) end
            end,
        })
    end
    local rows = { self:buttonRow(tabs, row_w, container) }
    local grid = {}
    for _idx, emoji in ipairs(EMOJI_CATEGORIES[tab].emoji) do
        table.insert(grid, { text = emoji, callback = function() on_pick(emoji) end })
    end
    util.arrayAppend(rows, self:buttonRows(grid, EMOJI_PER_ROW, row_w, container))
    table.insert(rows, self:separator(row_w))
    return rows
end

-- New post (from the feed, a community, a book page, a highlight or "Citar").
-- selected_text pre-fills the body; book_title/book_author are sent along;
-- community posts inside it; quoted (a topic) makes this a quote of that post.
function Inkwell:openPublishDialog(selected_text, book_title, book_author, community, quoted)
    local title = _("Novo post")
    if quoted then
        title = _("Citar post")
    elseif community then
        title = T(_("Novo post em %1"), community.title)
    end
    self:openComposer{
        title = title,
        intro_rows = function(row_w)
            local rows = {}
            local book = bookLine(book_title, book_author)
            if book then
                table.insert(rows, self:textRow(T(_("Livro: %1"), book), row_w, { dim = true }))
            end
            if quoted then
                local FrameContainer = require("ui/widget/container/framecontainer")
                local Size = require("ui/size")
                table.insert(rows, FrameContainer:new{
                    bordersize = 0,
                    padding = Size.padding.large,
                    self:quoteBox(quoted, row_w - 2 * Size.padding.large),
                })
            end
            return rows
        end,
        fields = {
            { text = selected_text, hint = _("O que você quer compartilhar?"), multiline = true },
            { hint = _("Título (opcional)") },
            { hint = _("Hashtags (ex: kindle, leitura)") },
        },
        submit_text = _("Publicar"),
        emoji = true,
        validate = function(v)
            if not quoted and util.trim(v[1]) == "" and util.trim(v[2]) == "" then
                return _("Escreva algo para publicar.")
            end
        end,
        on_submit = function(v)
            self:publishTopic{
                selftext = util.trim(v[1]),
                title = util.trim(v[2]),
                hashtags = parseHashtags(v[3]),
                book_title = book_title,
                book_author = book_author,
                community_id = community and community.id,
                quoted_id = quoted and quoted.id,
            }
        end,
    }
end

function Inkwell:publishTopic(post)
    deferredTrap(function()
        Trapper:info(_("Publicando…"))
        -- Posting about the book that's open (e.g. from a highlight): send its cover along.
        if post.book_title and not post.cover then
            post.cover = self:currentCover(post.book_title)
        end
        local topic, err = ForumClient.createTopic(post)
        Trapper:clear()
        if not topic then
            UIManager:show(InfoMessage:new{ text = T(_("Falha ao publicar: %1"), err) })
            return
        end
        UIManager:show(InfoMessage:new{ text = _("Publicado no Inkwell!"), timeout = 2 })
        self:showPost(topic)
    end)
end

-- ---------------------------------------------------------------------------
-- Resenhas: posts with a 0-5 star rating, a title, a text and a book
-- ---------------------------------------------------------------------------

-- ponytail: latest 50 only, no paging; page like showHome if the list grows.
function Inkwell:openReviews()
    self:load(function() return ForumClient.listTopics(0, 50, "reviews") end,
        function(page) self:showReviews(page.topics) end)
end

function Inkwell:showReviews(topics)
    local modal
    local function rerender()
        UIManager:close(modal)
        self:showReviews(topics)
    end
    modal = self:showModal{
        title = _("Resenhas"),
        on_menu = function() self:openNavMenu(function() UIManager:close(modal); self:openReviews() end) end,
        build_rows = function(row_w, container)
            return self:feedItems(topics, row_w, container, rerender, _("Nenhuma resenha ainda."))
        end,
        buttons = {
            { { text = _("Nova resenha…"), callback = function()
                local book = self:currentBook()
                self:openReviewDialog(book and book.title, book and book.author)
            end } },
        },
    }
end

-- book_title/book_author prefill the book (open ebook or book page); without them the
-- user types it. Rating is picked on a 0 + five-star row above the fields.
function Inkwell:openReviewDialog(book_title, book_author)
    local rating
    local fields = {
        { hint = _("Título da resenha") },
        { hint = _("Sua resenha"), multiline = true },
    }
    if not book_title then
        table.insert(fields, 1, { hint = _("Livro") })
        table.insert(fields, 2, { hint = _("Autor (opcional)") })
    end
    self:openComposer{
        title = _("Nova resenha"),
        intro_rows = function(row_w, container, reopen)
            local rows = {}
            if book_title then
                table.insert(rows, self:textRow("📖 " .. bookLine(book_title, book_author), row_w, { dim = true, compact = true }))
            end
            local picks = { { text = rating == 0 and "● 0" or "0", callback = function() rating = 0; reopen() end } }
            for i = 1, 5 do
                table.insert(picks, {
                    text = (rating or 0) >= i and "★" or "☆",
                    font_size = 22,
                    callback = function() rating = i; reopen() end,
                })
            end
            table.insert(rows, self:buttonRow(picks, row_w, container))
            return rows
        end,
        fields = fields,
        submit_text = _("Publicar"),
        emoji = true,
        validate = function(v)
            if not rating then return _("Escolha uma nota de 0 a 5.") end
            if not book_title and util.trim(v[1]) == "" then return _("Informe o livro.") end
            if util.trim(v[#v - 1]) == "" or util.trim(v[#v]) == "" then
                return _("Resenha precisa de título e texto.")
            end
        end,
        on_submit = function(v)
            self:publishTopic{
                book_title = book_title or util.trim(v[1]),
                book_author = book_author or (util.trim(v[2]) ~= "" and util.trim(v[2]) or nil),
                title = util.trim(v[#v - 1]),
                selftext = util.trim(v[#v]),
                rating = rating,
            }
        end,
    }
end

-- reply_to (a comment), when given, makes this a reply to it, pre-filled with "@author ".
-- on_cancel reopens whatever screen was closed to show the composer.
function Inkwell:openCommentComposer(topic, reply_to, on_cancel)
    self:openComposer{
        title = reply_to and T(_("Responder a @%1"), reply_to.author) or _("Comentar"),
        intro_rows = function(row_w)
            local quoted = reply_to and reply_to.body or util.trim((topic.title or "") .. "\n" .. (topic.selftext or ""))
            return { self:textRow(excerpt(quoted), row_w, { dim = true, size = 14 }) }
        end,
        fields = {
            { text = reply_to and ("@" .. reply_to.author .. " ") or nil, hint = _("Escreva seu comentário…"), multiline = true },
        },
        submit_text = _("Enviar"),
        emoji = true,
        validate = function(v)
            if util.trim(v[1]) == "" then
                return _("Escreva um comentário.")
            end
        end,
        on_submit = function(v) self:submitComment(topic, util.trim(v[1]), reply_to and reply_to.id) end,
        on_cancel = on_cancel,
    }
end

function Inkwell:submitComment(topic, body, parent_id)
    self:load(function() return ForumClient.addComment(topic.id, body, parent_id) end, function(full_topic)
        -- Land on the page holding the new comment (highest id; replies sit mid-thread).
        local newest_index, newest_id = 1, -1
        for i, c in ipairs(self.buildCommentTree(full_topic.comments or {})) do
            if c.id > newest_id then
                newest_index, newest_id = i, c.id
            end
        end
        self:showPost(full_topic, math.ceil(newest_index / COMMENTS_PAGE_SIZE))
    end, _("Enviando comentário…"))
end

-- ---------------------------------------------------------------------------
-- Home feed
-- ---------------------------------------------------------------------------

function Inkwell:openForum()
    if not ForumClient.isLoggedIn() then
        self:openLoginDialog()
        return
    end
    NetworkMgr:runWhenOnline(function() self:loadHomePage(0) end)
end

-- feed: "following" or "all" (Descobrir); remembered between sessions.
function Inkwell:loadHomePage(offset, feed)
    feed = feed or G_reader_settings:readSetting("inkwell_feed") or "following"
    deferredTrap(function()
        Trapper:info(_("Carregando…"))
        -- Opened from inside a book: that's the moment to update the shelf ("lendo agora").
        local ok, event = pcall(self.syncReading, self)
        if not ok then
            logger.warn("Inkwell: reading sync failed", event)
            event = nil
        end
        local page, page_err = ForumClient.listTopics(offset, HOME_PAGE_SIZE, feed)
        local state = { feed = feed, offset = offset, page = page }
        if page and offset == 0 and feed == "all" then
            state.trending = ForumClient.trending()
        end
        Trapper:clear()
        if not page then
            UIManager:show(InfoMessage:new{ text = T(_("Falha ao buscar dados: %1"), page_err) })
            return
        end
        self:showHome(state)
        self:offerReadingPost(event) -- after the home, so the question shows on top of it
    end)
end

-- Social timeline with two tabs: "Seguindo" (people you follow) and "Descobrir" (everyone,
-- plus trending tags/books). Paginated HOME_PAGE_SIZE posts at a time;
-- each page rebuilds the whole screen.
function Inkwell:showHome(state)
    local page = state.page
    local offset, feed = state.offset, state.feed
    local modal
    local function reload(new_offset, new_feed)
        UIManager:close(modal)
        self:loadHomePage(new_offset, new_feed)
    end
    local function rerender()
        UIManager:close(modal)
        self:showHome(state)
    end
    local function switchTo(new_feed)
        if new_feed ~= feed then
            G_reader_settings:saveSetting("inkwell_feed", new_feed)
            reload(0, new_feed)
        end
    end
    local unread = page.unread_notifications or 0
    modal = self:showModal{
        title = _("Inkwell"),
        subtitle = T(_("@%1"), ForumClient.username()),
        on_menu = function() self:openNavMenu(function() reload(offset, feed) end) end,
        build_rows = function(row_w, container)
            local rows = {
                self:buttonRow({
                    { text = (feed == "following" and "● " or "") .. _("Seguindo"), callback = function() switchTo("following") end },
                    { text = (feed == "all" and "● " or "") .. _("Descobrir"), callback = function() switchTo("all") end },
                }, row_w, container),
            }
            local trending = state.trending
            if trending and #(trending.hashtags or {}) > 0 then
                table.insert(rows, self:sectionRow(_("Em alta"), row_w))
                -- Compact on purpose: top 4 tags in one light row, top 3 book titles.
                local tags = {}
                for i = 1, math.min(4, #trending.hashtags) do
                    local t = trending.hashtags[i]
                    table.insert(tags, { text = "#" .. t.tag, callback = function() self:openTag(t.tag) end })
                end
                table.insert(rows, self:buttonRow(tags, row_w, container))
                local books = trending.books or {}
                for i = 1, math.min(3, #books) do
                    local b = books[i]
                    table.insert(rows, self:wrapTappable(
                        self:textRow("📖 " .. b.title, row_w, { size = 14, dim = true, compact = true }),
                        function() self:openBook(b.title, b.author) end))
                end
                table.insert(rows, self:separator(row_w))
            end
            local empty = feed == "following"
                and _("Nada por aqui ainda. Siga leitores para ver os posts deles, ou veja a aba Descobrir.")
                or _("Nenhum post ainda.")
            if feed == "all" and offset == 0 then
                table.insert(rows, self:sectionRow(_("Posts recentes"), row_w))
            end
            util.arrayAppend(rows, self:feedItems(page.topics, row_w, container, rerender, empty))
            return rows
        end,
        buttons = {
            {
                -- home stays open underneath, so cancelling the composer lands back on the feed
                { text = _("Novo post…"), callback = function() self:openPublishDialog() end },
                {
                    text = unread > 0 and T(_("Atividade (%1)"), unread) or _("Atividade"),
                    callback = function()
                        page.unread_notifications = 0
                        rerender()
                        self:openActivity()
                    end,
                },
            },
            {
                {
                    text = _("‹ anterior"),
                    enabled = offset > 0,
                    callback = function() reload(math.max(offset - HOME_PAGE_SIZE, 0), feed) end,
                },
                {
                    text = T(_("pág. %1 de %2"), math.floor(offset / HOME_PAGE_SIZE) + 1,
                        math.max(math.ceil((page.total or 0) / HOME_PAGE_SIZE), 1)),
                    enabled = false,
                },
                {
                    text = _("próxima ›"),
                    enabled = page.has_more,
                    callback = function() reload(offset + HOME_PAGE_SIZE, feed) end,
                },
            },
        },
    }
end

-- A list of posts as feed items (search, tags, my posts).
function Inkwell:showPostList(title, topics)
    local modal
    local function rerender()
        UIManager:close(modal)
        self:showPostList(title, topics)
    end
    modal = self:showModal{
        title = title,
        on_menu = function() self:openNavMenu() end,
        build_rows = function(row_w, container)
            return self:feedItems(topics, row_w, container, rerender, _("Nenhum resultado."))
        end,
    }
end

function Inkwell:runQuery(title, fetch_fn)
    self:load(fetch_fn, function(topics) self:showPostList(title, topics) end)
end

function Inkwell:openTag(tag)
    self:runQuery("#" .. tag, function() return ForumClient.search("#" .. tag) end)
end

function Inkwell:openSearch()
    self:openComposer{
        title = _("Buscar"),
        intro_rows = function(row_w)
            return { self:textRow(_("Busque por texto ou livro, #hashtag, ou @usuário para ver os posts de alguém."), row_w, { dim = true }) }
        end,
        fields = { { hint = _("kindle, #resenha ou @alice") } },
        submit_text = _("Buscar"),
        validate = function(v)
            if util.trim(v[1]) == "" then
                return _("Digite algo para buscar.")
            end
        end,
        on_submit = function(v)
            local query = util.trim(v[1])
            self:runQuery(T(_("Busca: %1"), query), function() return ForumClient.search(query) end)
        end,
    }
end

function Inkwell:openMyPosts()
    self:runQuery(_("Meus posts"), ForumClient.myPosts)
end

-- ---------------------------------------------------------------------------
-- Post screen (post + actions + comments, all in one)
-- ---------------------------------------------------------------------------

function Inkwell:openThread(topic)
    self:load(function() return ForumClient.getTopic(topic.id) end, function(full_topic)
        self:showPost(full_topic)
    end, _("Carregando post…"))
end

-- Orders full_topic.comments (flat, with parent_id links) as each top-level comment
-- followed by its replies, annotated with .depth (0 or 1: replies are one level deep,
-- social style; the server already hangs replies-to-replies off the top-level one).
-- Comments whose parent is missing are treated as top-level, so nothing disappears.
function Inkwell.buildCommentTree(comments)
    local children_of = {} -- parent_id (or "root") -> array of comments
    local by_id = {}
    for _idx, c in ipairs(comments) do
        if c.id then
            by_id[c.id] = c
        end
    end
    for _idx, c in ipairs(comments) do
        local key = (c.parent_id and by_id[c.parent_id]) and c.parent_id or "root"
        children_of[key] = children_of[key] or {}
        table.insert(children_of[key], c)
    end

    local ordered = {}
    local function visit(parent_key, depth)
        for _idx, c in ipairs(children_of[parent_key] or {}) do
            c.depth = math.min(depth, 1)
            table.insert(ordered, c)
            if c.id then
                visit(c.id, depth + 1)
            end
        end
    end
    visit("root", 0)
    return ordered
end

-- The post, its actions (♥ / Comentar / Citar), tag/book/author chips, then the
-- comments (COMMENTS_PAGE_SIZE per page) each with its own ♥ / Responder / Apagar.
-- Every action redraws this same screen; nothing opens a popup menu.
function Inkwell:showPost(topic, comment_page)
    local ordered = Inkwell.buildCommentTree(topic.comments or {})
    local num_pages = math.max(math.ceil(#ordered / COMMENTS_PAGE_SIZE), 1)
    comment_page = math.min(math.max(comment_page or 1, 1), num_pages)

    local modal
    local function rerender(new_page)
        UIManager:close(modal)
        self:showPost(topic, new_page or comment_page)
    end
    local function closeThen(fn)
        return function()
            UIManager:close(modal)
            fn()
        end
    end
    local reopen = function() self:showPost(topic, comment_page) end

    local footer = {}
    if num_pages > 1 then
        table.insert(footer, {
            { text = _("‹ anteriores"), enabled = comment_page > 1, callback = function() rerender(comment_page - 1) end },
            { text = T(_("comentários %1/%2"), comment_page, num_pages), enabled = false },
            { text = _("próximos ›"), enabled = comment_page < num_pages, callback = function() rerender(comment_page + 1) end },
        })
    end
    -- The server decides who may delete what (can_delete); the client only draws the button.
    if topic.can_delete then
        table.insert(footer, {
            {
                text = _("Apagar post"),
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = _("Apagar este post e todos os seus comentários?"),
                        ok_text = _("Apagar"),
                        ok_callback = closeThen(function() self:deleteTopic(topic) end),
                    })
                end,
            },
        })
    end

    modal = self:showModal{
        title = _("Post"),
        subtitle = topic.community and topic.community.title or nil,
        on_menu = function() self:openNavMenu(function() UIManager:close(modal); self:openThread(topic) end) end,
        build_rows = function(row_w, container)
            local Size = require("ui/size")
            local rows = {
                self:buildFeedCard(topic, row_w, true),
                self:buttonRow({
                    { text = likeLabel(topic), callback = function() self:toggleTopicLike(topic, rerender) end },
                    { text = _("Comentar"), callback = closeThen(function() self:openCommentComposer(topic, nil, reopen) end) },
                    { text = _("Citar"), callback = function() self:openPublishDialog(nil, nil, nil, nil, topic) end },
                }, row_w, container),
            }

            local chips = {
                { text = T(_("@%1"), topic.author), callback = function() self:openUserProfile(topic.author) end },
            }
            if topic.book_title and topic.book_title ~= "" then
                table.insert(chips, { text = "📖 " .. topic.book_title, callback = function() self:openBook(topic.book_title, topic.book_author) end })
            end
            if topic.quoted then
                table.insert(chips, { text = _("↪ citado"), callback = function() self:openThread(topic.quoted) end })
            end
            if topic.community then
                table.insert(chips, { text = topic.community.title, callback = function() self:openCommunity(topic.community.id) end })
            end
            for _idx, tag in ipairs(topic.hashtags or {}) do
                table.insert(chips, { text = "#" .. tag, callback = function() self:openTag(tag) end })
            end
            -- Secondary links: smaller than the actions above.
            for _idx, chip in ipairs(chips) do chip.font_size = 14 end
            util.arrayAppend(rows, self:buttonRows(chips, 4, row_w, container))
            table.insert(rows, self:separator(row_w))

            table.insert(rows, self:sectionRow(#ordered == 0 and _("Comentários") or T(_("Comentários (%1)"), #ordered), row_w))
            if #ordered == 0 then
                table.insert(rows, self:textRow(_("Ninguém comentou ainda. Seja o primeiro!"), row_w, { dim = true }))
            end
            local first = (comment_page - 1) * COMMENTS_PAGE_SIZE + 1
            for i = first, math.min(first + COMMENTS_PAGE_SIZE - 1, #ordered) do
                local c = ordered[i]
                local indent = c.depth > 0 and Screen:scaleBySize(28) or 0
                local byline = T(_("%1 · @%2 · %3"), displayName(c.author_display_name, c.author), c.author, relativeTime(c.created_at))
                table.insert(rows, self:wrapTappable(self:textRow(byline, row_w, { bold = true, size = 14, indent = indent }),
                    function() self:openUserProfile(c.author) end))
                table.insert(rows, self:textRow(c.body or "", row_w, { indent = indent }))
                local actions = {
                    { text = likeLabel(c), callback = function() self:toggleCommentLike(c, rerender) end },
                    { text = _("Responder"), callback = closeThen(function() self:openCommentComposer(topic, c, reopen) end) },
                }
                if c.can_delete then
                    table.insert(actions, {
                        text = _("Apagar"),
                        callback = function()
                            UIManager:show(ConfirmBox:new{
                                text = _("Apagar este comentário? As respostas a ele também serão apagadas."),
                                ok_text = _("Apagar"),
                                ok_callback = closeThen(function() self:deleteComment(topic, c.id, comment_page) end),
                            })
                        end,
                    })
                end
                table.insert(rows, self:buttonRow(actions, row_w, container, indent))
                if i < #ordered then
                    table.insert(rows, self:separator(row_w))
                end
            end
            table.insert(rows, require("ui/widget/verticalspan"):new{ width = Size.span.vertical_large })
            return rows
        end,
        buttons = footer,
    }
end

function Inkwell:deleteTopic(topic)
    self:load(function() return ForumClient.deleteTopic(topic.id) end, function()
        UIManager:show(InfoMessage:new{ text = _("Post apagado."), timeout = 2 })
        if topic.community then
            self:openCommunity(topic.community.id)
        else
            self:openForum()
        end
    end, _("Apagando…"))
end

function Inkwell:deleteComment(topic, comment_id, comment_page)
    self:load(function() return ForumClient.deleteComment(topic.id, comment_id) end, function(updated_topic)
        self:showPost(updated_topic, comment_page)
    end, _("Apagando comentário…"))
end

-- ---------------------------------------------------------------------------
-- Profiles, people, shelf, books
-- ---------------------------------------------------------------------------

function Inkwell:openUserProfile(username)
    self:load(function() return ForumClient.getUserProfile(username) end, function(profile)
        self:showUserProfile(profile)
    end, _("Carregando perfil…"))
end

-- Builds the avatar + name + handle + bio + (optional) edit button header shown
-- at the top of a profile screen.
function Inkwell:buildProfileHeader(profile, screen_w)
    local Avatar = require("avatar")
    local Blitbuffer = require("ffi/blitbuffer")
    local Button = require("ui/widget/button")
    local Font = require("ui/font")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local LeftContainer = require("ui/widget/container/leftcontainer")
    local Size = require("ui/size")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")

    local avatar_size = Screen:scaleBySize(64)
    local content_w = screen_w - 2 * Size.padding.large

    local handle = T(_("@%1"), profile.username)
    if profile.badge then
        handle = T(_("%1 · %2"), handle, _(profile.badge))
    end
    if profile.follows_me then
        handle = T(_("%1 · segue você"), handle)
    end

    -- Extra profile facts (gender, age, public/private), joined into one line;
    -- any of them may be nil (e.g. never set, or hidden on a private profile).
    local facts = {}
    if profile.gender == "masc" then
        table.insert(facts, _("Masculino"))
    elseif profile.gender == "feminino" then
        table.insert(facts, _("Feminino"))
    elseif profile.gender == "outro" then
        table.insert(facts, _("Outro"))
    end
    if profile.age then
        table.insert(facts, T(_("%1 anos"), profile.age))
    end
    if profile.is_public ~= nil then
        table.insert(facts, profile.is_public and _("Perfil público") or _("Perfil privado"))
    end
    local facts_line = table.concat(facts, " · ")

    local name_col_width = content_w - avatar_size - Size.span.horizontal_default
    local name_col = VerticalGroup:new{
        align = "left",
        TextBoxWidget:new{
            text = displayName(profile.display_name, profile.username),
            face = Font:getFace("cfont", 22),
            bold = true,
            width = name_col_width,
        },
        TextBoxWidget:new{
            text = handle,
            face = Font:getFace("cfont", 16),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            width = name_col_width,
        },
    }
    if facts_line ~= "" then
        table.insert(name_col, TextBoxWidget:new{
            text = facts_line,
            face = Font:getFace("cfont", 14),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            width = name_col_width,
        })
    end

    local avatar_path = Avatar.ensureLocal(profile.username, profile.avatar_url)
    local avatar_widget = Avatar.widget(avatar_path, avatar_size, profile.username)

    local rows = {
        align = "left",
        HorizontalGroup:new{
            avatar_widget,
            HorizontalSpan:new{ width = Size.span.horizontal_default },
            LeftContainer:new{
                dimen = { w = name_col_width, h = name_col:getSize().h },
                name_col,
            },
        },
    }

    if profile.bio and profile.bio ~= "" then
        table.insert(rows, VerticalSpan:new{ width = Size.span.vertical_default })
        table.insert(rows, TextBoxWidget:new{
            text = profile.bio,
            face = Font:getFace("cfont", 16),
            width = content_w,
        })
    end

    if profile.username == ForumClient.username() then
        table.insert(rows, VerticalSpan:new{ width = Size.span.vertical_default })
        table.insert(rows, Button:new{
            text = _("Editar perfil…"),
            width = content_w,
            callback = function() self:openEditProfile() end,
        })
    end

    return FrameContainer:new{
        width = screen_w,
        bordersize = 0,
        padding = Size.padding.large,
        VerticalGroup:new(rows),
    }
end

-- Header, counters (tap → followers/following), Seguir, "lendo agora", shelf, posts.
function Inkwell:showUserProfile(profile)
    local is_me = profile.username == ForumClient.username()
    local modal
    local function rerender()
        UIManager:close(modal)
        self:showUserProfile(profile)
    end
    modal = self:showModal{
        title = displayName(profile.display_name, profile.username),
        on_menu = function() self:openNavMenu(function() UIManager:close(modal); self:openUserProfile(profile.username) end) end,
        build_rows = function(row_w, container)
            local rows = {
                self:buildProfileHeader(profile, row_w),
                self:buttonRow({
                    { text = T(_("%1 posts"), profile.num_posts or 0), enabled = false },
                    {
                        text = T(_("%1 seguidores"), profile.num_followers or 0),
                        callback = function() self:openPeopleOf(profile.username, "followers") end,
                    },
                    {
                        text = T(_("%1 seguindo"), profile.num_following or 0),
                        callback = function() self:openPeopleOf(profile.username, "following") end,
                    },
                }, row_w, container),
            }
            if not is_me then
                table.insert(rows, self:buttonRow({
                    {
                        text = profile.followed_by_me and _("Seguindo ✓ (toque para deixar de seguir)") or _("Seguir"),
                        callback = function() self:toggleFollow(profile, rerender) end,
                    },
                }, row_w, container))
            end
            local reading = profile.reading_now
            if reading then
                table.insert(rows, self:wrapTappable(
                    self:textRow(T(_("Lendo agora: %1 (%2%)"), bookLine(reading.book_title, reading.book_author), reading.progress), row_w),
                    function() self:openBook(reading.book_title, reading.book_author) end))
            end
            local shelf = profile.shelf or {}
            if #shelf > 0 or is_me then
                table.insert(rows, self:buttonRow({
                    { text = T(_("Estante (%1 livros)"), #shelf), callback = function() self:showShelf(profile) end },
                }, row_w, container))
            end
            table.insert(rows, self:separator(row_w))
            table.insert(rows, self:sectionRow(_("Posts"), row_w))
            util.arrayAppend(rows, self:feedItems(profile.recent_posts or {}, row_w, container, rerender))
            return rows
        end,
    }
end

-- which: "followers" or "following".
function Inkwell:openPeopleOf(username, which)
    local title = which == "followers" and T(_("Seguidores de @%1"), username) or T(_("@%1 segue"), username)
    self:openPeople(title, function() return ForumClient.people(username, which) end)
end

function Inkwell:openPeople(title, fetch_fn)
    self:load(fetch_fn, function(users) self:showPeople(title, users) end)
end

function Inkwell:showPeople(title, users)
    local modal
    local function rerender()
        UIManager:close(modal)
        self:showPeople(title, users)
    end
    modal = self:showModal{
        title = title,
        on_menu = function() self:openNavMenu() end,
        build_rows = function(row_w, container)
            if #users == 0 then
                return { self:textRow(_("Ninguém por aqui ainda."), row_w, { dim = true }) }
            end
            local rows = {}
            for _idx, user in ipairs(users) do
                table.insert(rows, self:personRow(user, row_w, container, rerender))
                table.insert(rows, self:separator(row_w))
            end
            return rows
        end,
    }
end

-- author (optional) tells apart different books with the same title.
function Inkwell:openBook(title, author)
    self:load(function() return ForumClient.getBook(title, author) end, function(book) self:showBook(book) end)
end

-- The book page's shelf buttons, depending on where the book is on the user's shelf.
-- run(fn) applies the change and reloads the page.
local function shelfButtons(book, run)
    local entry = book.my_entry
    local function set(status)
        return function() run(function() return ForumClient.pushReading(book.title, book.author, 0, status) end) end
    end
    local remove = {
        text = _("Tirar da estante"),
        callback = function() run(function() return ForumClient.removeReading(book.title, book.author) end) end,
    }
    if not entry then
        return { { text = _("Quero ler"), callback = set("want") } }
    elseif entry.status == "want" then
        return { remove }
    elseif entry.status == "reading" then
        return { { text = _("Marcar como lido"), callback = set("finished") }, remove }
    end
    return { { text = _("Ler de novo"), callback = set("reading") }, remove }
end

-- Everyone with the book on their shelf, plus every post about it.
function Inkwell:showBook(book)
    local modal
    local function rerender()
        UIManager:close(modal)
        self:showBook(book)
    end
    local function applyShelf(fn)
        self:load(fn, function()
            UIManager:close(modal)
            self:openBook(book.title, book.author)
        end)
    end
    modal = self:showModal{
        title = book.title,
        subtitle = book.author ~= "" and book.author or nil,
        on_menu = function() self:openNavMenu() end,
        build_rows = function(row_w, container)
            local rows = {}
            local cover = book.cover_url and require("avatar").cover(book.cover_url,
                math.floor(Screen:scaleBySize(240) * 2 / 3), Screen:scaleBySize(240))
            if cover then
                local Size = require("ui/size")
                table.insert(rows, require("ui/widget/container/centercontainer"):new{
                    dimen = require("ui/geometry"):new{ w = row_w, h = cover:getSize().h + 2 * Size.padding.large },
                    cover,
                })
            end
            util.arrayAppend(rows, {
                self:buttonRow({
                    { text = _("Postar…"), callback = function() self:openPublishDialog(nil, book.title, book.author) end },
                    { text = _("Resenhar…"), callback = function() self:openReviewDialog(book.title, book.author) end },
                }, row_w, container),
                self:buttonRow(shelfButtons(book, applyShelf), row_w, container),
            })
            local readers = book.readers or {}
            if #readers > 0 then
                table.insert(rows, self:sectionRow(T(_("Leitores (%1)"), #readers), row_w))
                for _idx, r in ipairs(readers) do
                    local status = (r.status == "finished" and _("leu")) or (r.status == "want" and _("quer ler"))
                        or T(_("lendo · %1%"), r.progress)
                    table.insert(rows, self:wrapTappable(
                        self:textRow(T(_("%1 (@%2) · %3"), displayName(r.display_name, r.username), r.username, status), row_w),
                        function() self:openUserProfile(r.username) end))
                end
                table.insert(rows, self:separator(row_w))
            end
            table.insert(rows, self:sectionRow(_("Posts"), row_w))
            util.arrayAppend(rows, self:feedItems(book.topics or {}, row_w, container, rerender))
            return rows
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Activity (notifications)
-- ---------------------------------------------------------------------------

-- A function, not a table: _() must run at display time so a language switch applies.
local function notificationText(type)
    return ({
    like = _("%1 curtiu seu post"),
    comment = _("%1 comentou no seu post"),
    reply = _("%1 respondeu seu comentário"),
    mention = _("%1 mencionou você"),
    follow = _("%1 começou a seguir você"),
    comment_like = _("%1 curtiu seu comentário"),
    quote = _("%1 citou seu post"),
    community_request = _("%1 pediu para entrar em %2"),
    community_approved = _("%1 aprovou sua entrada em %2"),
    })[type]
end

function Inkwell:openActivity()
    self:load(function()
        local data, err = ForumClient.notifications()
        if data and data.unread > 0 then
            ForumClient.markNotificationsRead() -- best effort: the list is already fetched
        end
        return data, err
    end, function(data) self:showActivity(data.notifications or {}) end)
end

function Inkwell:showActivity(notifications)
    self:showModal{
        title = _("Atividade"),
        on_menu = function() self:openNavMenu() end,
        build_rows = function(row_w)
            local FrameContainer = require("ui/widget/container/framecontainer")
            local Size = require("ui/size")
            if #notifications == 0 then
                return { self:textRow(_("Nada de novo por aqui. Curtidas, comentários e novos seguidores aparecem nesta tela."), row_w, { dim = true }) }
            end
            local rows = {}
            for _idx, n in ipairs(notifications) do
                local name = displayName(n.actor_display_name, n.actor)
                local text = T(notificationText(n.type) or "%1", name, n.community_title or "")
                if not n.read then
                    text = "● " .. text
                end
                local subline = relativeTime(n.created_at)
                if n.topic_excerpt and n.topic_excerpt ~= "" then
                    subline = T(_("“%1” · %2"), n.topic_excerpt, subline)
                end
                local header = self:avatarHeader(n.actor, n.actor_avatar_url, text, subline, row_w - 2 * Size.padding.large)
                table.insert(rows, self:wrapTappable(
                    FrameContainer:new{ bordersize = 0, padding = Size.padding.large, header },
                    function()
                        if n.topic_id then
                            self:openThread({ id = n.topic_id })
                        elseif n.community_id then
                            self:openCommunity(n.community_id)
                        else
                            self:openUserProfile(n.actor)
                        end
                    end))
                table.insert(rows, self:separator(row_w))
            end
            return rows
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Navigation menu (full screen)
-- ---------------------------------------------------------------------------

-- on_refresh, when given, adds an "Atualizar" item that reloads the screen that
-- opened this menu (e.g. the home timeline).
function Inkwell:openNavMenu(on_refresh)
    local me = ForumClient.username()
    local modal
    local items = {}
    local function add(text, fn)
        table.insert(items, { text = text, fn = fn })
    end
    local function gap()
        table.insert(items, false)
    end
    add(_("Início"), function() self:openForum() end)
    if on_refresh then
        add(_("Atualizar"), on_refresh)
    end
    gap()
    add(_("Buscar"), function() self:openSearch() end)
    add(_("Atividade"), function() self:openActivity() end)
    add(_("Meu perfil"), function() self:openUserProfile(me) end)
    add(_("Meus posts"), function() self:openMyPosts() end)
    gap()
    add(_("Seguindo"), function() self:openPeopleOf(me, "following") end)
    add(_("Seguidores"), function() self:openPeopleOf(me, "followers") end)
    add(_("Resenhas"), function() self:openReviews() end)
    add(_("Comunidades"), function() self:openCommunities() end)
    gap()
    if ForumClient.canCreateModerator() then
        add(_("Criar moderador…"), function() self:openCreateModeratorDialog() end)
    end
    -- Redraws in the new language: the screen behind the menu when it can reload, else the menu.
    add("🌐 " .. _("Idioma: Português (Brasil)"), function()
        _.toggle()
        if on_refresh then
            on_refresh()
        else
            self:openNavMenu()
        end
    end)
    add(T(_("Sair (@%1)"), me), function() self:logout() end)

    modal = self:showModal{
        title = _("Menu"),
        build_rows = function(row_w, container)
            local auto_share = G_reader_settings:nilOrTrue("inkwell_auto_share")
            local rows = {}
            for _idx, item in ipairs(items) do
                if item then
                    table.insert(rows, self:wrapTappable(self:textRow(item.text, row_w, { size = 18 }), function()
                        UIManager:close(modal)
                        item.fn()
                    end))
                    table.insert(rows, self:separator(row_w))
                elseif #rows > 0 then
                    -- Group break: thicker divider instead of a blank span, so every row keeps the same height.
                    rows[#rows] = require("ui/widget/linewidget"):new{
                        dimen = require("ui/geometry"):new{ w = row_w, h = require("ui/size").line.thick },
                        background = require("ffi/blitbuffer").COLOR_DARK_GRAY,
                    }
                end
            end
            table.insert(rows, self:textRow(
                _("Com o compartilhamento de leituras ligado, o Inkwell pergunta se você quer postar quando começa ou termina um livro."),
                row_w, { dim = true, size = 14 }))
            table.insert(rows, self:buttonRow({
                {
                    text = auto_share and _("Compartilhar leituras: ligado ✓") or _("Compartilhar leituras: desligado"),
                    callback = function()
                        G_reader_settings:saveSetting("inkwell_auto_share", not auto_share)
                        UIManager:close(modal)
                        self:openNavMenu(on_refresh)
                    end,
                },
            }, row_w, container))
            return rows
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Profile editing
-- ---------------------------------------------------------------------------

-- bio, when given (a highlight from the book), replaces the saved bio in the form; nothing
-- is saved until the user taps Salvar.
function Inkwell:openEditProfile(bio)
    self:load(ForumClient.getMyProfile, function(profile)
        profile.bio = bio or profile.bio
        self:showEditProfile(profile)
    end, _("Carregando perfil…"))
end

-- Same full-screen composer as posts: labelled fields, and gender / visibility as light
-- choice rows (● marks the current one; picking redraws, keeping what was typed).
-- Validation (e.g. age) is the server's: its message is shown if it rejects the save.
function Inkwell:showEditProfile(profile)
    local gender = profile.gender
    local is_public = profile.is_public ~= false
    local function choice(text, selected, on_pick)
        return { text = (selected and "● " or "") .. text, callback = on_pick }
    end
    self:openComposer{
        title = _("Editar perfil"),
        intro_rows = function(row_w, container, reopen)
            local rows = {
                self:buttonRow({
                    {
                        text = _("Escolher foto de perfil…"),
                        callback = function()
                            UIManager:close(container)
                            self:openChooseAvatar()
                        end,
                    },
                }, row_w, container),
                self:textRow(_("Gênero"), row_w, { dim = true, size = 14, compact = true }),
            }
            local genders = {}
            for _idx, g in ipairs{ { "masc", _("Masculino") }, { "feminino", _("Feminino") }, { "outro", _("Outro") } } do
                table.insert(genders, choice(g[2], gender == g[1], function() gender = g[1]; reopen() end))
            end
            table.insert(rows, self:buttonRow(genders, row_w, container))
            table.insert(rows, self:textRow(_("Visibilidade"), row_w, { dim = true, size = 14, compact = true }))
            table.insert(rows, self:buttonRow({
                choice(_("Perfil público"), is_public, function() is_public = true; reopen() end),
                choice(_("Perfil privado"), not is_public, function() is_public = false; reopen() end),
            }, row_w, container))
            return rows
        end,
        fields = {
            { label = _("Nome de exibição"), text = profile.display_name },
            { label = _("Bio"), text = profile.bio, multiline = true },
            { label = _("Idade"), text = profile.age and tostring(profile.age) or "", input_type = "number" },
        },
        submit_text = _("Salvar"),
        on_submit = function(v)
            local age_raw = util.trim(v[3])
            -- Non-numeric text goes as-is so the server rejects it with its own message.
            local age = age_raw ~= "" and (tonumber(age_raw) or age_raw) or nil
            self:saveProfile(v[1], v[2], gender, age, is_public)
        end,
    }
end

-- KOReader's file browser limited to images; on_path(path) runs once online.
function Inkwell:chooseImage(on_path)
    local PathChooser = require("ui/widget/pathchooser")
    local DocumentRegistry = require("document/documentregistry")
    UIManager:show(PathChooser:new{
        select_directory = false,
        file_filter = function(filename)
            return DocumentRegistry:isImageFile(filename)
        end,
        onConfirm = function(image_path)
            NetworkMgr:runWhenOnline(function() on_path(image_path) end)
        end,
    })
end

function Inkwell:openChooseAvatar()
    self:chooseImage(function(image_path) self:uploadAvatar(image_path) end)
end

-- Owner-only: pick an image, shrink it to banner size and set it as the community cover.
function Inkwell:openChooseCommunityCover(community)
    self:chooseImage(function(image_path)
        self:load(function()
            local bb = require("ui/renderimage"):renderImageFile(image_path, false)
            if not bb then
                return nil, _("Não foi possível abrir a imagem")
            end
            local cover = encodeJpeg(bb, 1000, 600)
            if not cover then
                return nil, _("Não foi possível converter a imagem")
            end
            return ForumClient.setCommunityCover(community.id, cover)
        end, function()
            UIManager:show(InfoMessage:new{ text = _("Capa da comunidade atualizada!"), timeout = 2 })
            self:openCommunity(community.id)
        end, _("Enviando capa…"))
    end)
end

function Inkwell:uploadAvatar(image_path)
    deferredTrap(function()
        Trapper:info(_("Enviando foto…"))
        local avatar_url, err = ForumClient.uploadAvatar(image_path)
        Trapper:clear()
        if not avatar_url then
            UIManager:show(InfoMessage:new{ text = T(_("Falha ao enviar foto: %1"), err) })
            return
        end
        UIManager:show(InfoMessage:new{ text = _("Foto de perfil atualizada!"), timeout = 2 })
        self:openUserProfile(ForumClient.username())
    end)
end

function Inkwell:saveProfile(display_name, bio, gender, age, is_public)
    deferredTrap(function()
        Trapper:info(_("Salvando perfil…"))
        local ok, err = ForumClient.updateMyProfile(display_name, bio, gender, age, is_public)
        Trapper:clear()
        if not ok then
            UIManager:show(InfoMessage:new{ text = T(_("Falha ao salvar perfil: %1"), err) })
            return
        end
        UIManager:show(InfoMessage:new{ text = _("Perfil atualizado!"), timeout = 2 })
        self:openUserProfile(ForumClient.username())
    end)
end

function Inkwell:openCreateModeratorDialog()
    self:openComposer{
        title = _("Criar moderador"),
        fields = {
            { hint = _("Email") },
            { hint = _("Senha"), text_type = "password" },
        },
        submit_text = _("Criar"),
        validate = function(v)
            if util.trim(v[1]) == "" or v[2] == "" then
                return _("Informe email e senha.")
            end
        end,
        on_submit = function(v)
            self:load(function() return ForumClient.createModerator(util.trim(v[1]), v[2]) end, function(result)
                UIManager:show(InfoMessage:new{ text = T(_("Moderador @%1 criado!"), result.username), timeout = 2 })
            end, _("Criando moderador…"))
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Communities
-- ---------------------------------------------------------------------------

function Inkwell:openCommunities()
    deferredTrap(function()
        Trapper:info(_("Carregando…"))
        local communities, err = ForumClient.listCommunities()
        Trapper:clear()
        if not communities then
            UIManager:show(InfoMessage:new{ text = T(_("Falha ao buscar dados: %1"), err) })
            return
        end
        self:showCommunityList(communities)
    end)
end

function Inkwell:showCommunityList(communities)
    local mine, others = {}, {}
    for _idx, c in ipairs(communities) do
        table.insert(c.is_member and mine or others, c)
    end

    local modal
    local function openCreate()
        UIManager:close(modal)
        self:openCreateCommunityDialog()
    end
    modal = self:showModal{
        title = _("Comunidades"),
        on_menu = function() self:openNavMenu() end,
        build_rows = function(row_w, container)
            local function communityRow(c)
                local text = (c.is_private and "🔒 " or "") .. c.title .. "\n"
                    .. (c.description ~= "" and (c.description .. "\n") or "")
                    .. T(_("%1 membros · %2 posts · criada por @%3"), c.num_members, c.num_topics, c.owner)
                    .. (c.is_pending and ("\n" .. _("Pedido enviado, aguardando aprovação")) or "")
                local row = self:textRow(text, row_w)
                local thumb_size = Screen:scaleBySize(64)
                local thumb = c.cover_url and require("avatar").cover(c.cover_url, thumb_size, thumb_size)
                if thumb then
                    local Size = require("ui/size")
                    row = require("ui/widget/horizontalgroup"):new{
                        align = "center",
                        require("ui/widget/horizontalspan"):new{ width = Size.padding.large },
                        thumb,
                        self:textRow(text, row_w - Size.padding.large - thumb:getSize().w),
                    }
                end
                return self:wrapTappable(row, function()
                    UIManager:close(modal)
                    self:openCommunity(c.id)
                end)
            end

            local rows = { self:sectionRow(_("Minhas comunidades"), row_w) }
            if #mine == 0 then
                table.insert(rows, self:textRow(
                    _("Você ainda não faz parte de nenhuma comunidade. Crie uma do zero ou participe de uma abaixo."),
                    row_w, { dim = true }))
                table.insert(rows, self:buttonRow({
                    { text = _("Criar comunidade do zero"), callback = openCreate },
                }, row_w, container))
            end
            for _idx, c in ipairs(mine) do
                table.insert(rows, communityRow(c))
            end

            if #others > 0 then
                table.insert(rows, self:sectionRow(_("Descobrir"), row_w))
                for _idx, c in ipairs(others) do
                    table.insert(rows, communityRow(c))
                end
            end
            return rows
        end,
        buttons = {
            { { text = _("Criar comunidade…"), callback = openCreate } },
        },
    }
end

function Inkwell:openCreateCommunityDialog()
    self:openComposer{
        title = _("Criar comunidade"),
        fields = {
            { hint = _("Título") },
            { hint = _("Descrição (opcional)") },
        },
        submit_text = _("Criar"),
        validate = function(v)
            if util.trim(v[1]) == "" then
                return _("Informe o título da comunidade.")
            end
        end,
        on_submit = function(v)
            self:load(function() return ForumClient.createCommunity(util.trim(v[1]), util.trim(v[2])) end, function(community)
                UIManager:show(InfoMessage:new{ text = T(_("Comunidade \"%1\" criada!"), community.title), timeout = 2 })
                self:showCommunity(community)
            end, _("Criando comunidade…"))
        end,
        on_cancel = function() self:openCommunities() end,
    }
end

function Inkwell:openCommunity(id)
    self:load(function() return ForumClient.getCommunity(id) end, function(community)
        self:showCommunity(community)
    end, _("Carregando comunidade…"))
end

-- Orkut-style community page: description on top, then its posts as feed items.
function Inkwell:showCommunity(community)
    local modal
    local function rerender()
        UIManager:close(modal)
        self:showCommunity(community)
    end
    -- Owner actions: each one applies the change and reloads the page.
    local function manage(fn)
        self:load(fn, function()
            UIManager:close(modal)
            self:openCommunity(community.id)
        end)
    end
    local function togglePrivacy()
        local function apply()
            manage(function() return ForumClient.setCommunityPrivacy(community.id, not community.is_private) end)
        end
        if not community.is_private then
            return apply()
        end
        UIManager:show(ConfirmBox:new{
            text = _("Tornar a comunidade pública? Todos passam a ver os posts, e os pedidos pendentes são aprovados."),
            ok_text = _("Tornar pública"),
            ok_callback = apply,
        })
    end
    local join_text = (community.is_member and _("Sair da comunidade"))
        or (community.is_pending and _("Cancelar pedido"))
        or (community.is_private and _("Pedir para participar"))
        or _("Participar")
    modal = self:showModal{
        title = (community.is_private and "🔒 " or "") .. community.title,
        subtitle = T(_("criada por @%1 · %2 membros · %3 posts"), community.owner, community.num_members, community.num_topics),
        on_menu = function()
            self:openNavMenu(function()
                UIManager:close(modal)
                self:openCommunity(community.id)
            end)
        end,
        build_rows = function(row_w, container)
            local rows = {}
            local banner = community.cover_url
                and require("avatar").cover(community.cover_url, row_w, Screen:scaleBySize(220))
            if banner then
                table.insert(rows, require("ui/widget/container/centercontainer"):new{
                    dimen = require("ui/geometry"):new{ w = row_w, h = banner:getSize().h },
                    banner,
                })
            end
            if community.can_manage then
                table.insert(rows, self:buttonRow({
                    {
                        text = community.cover_url and _("Trocar capa…") or _("Escolher capa…"),
                        callback = function() self:openChooseCommunityCover(community) end,
                    },
                    { text = community.is_private and _("Tornar pública") or _("Tornar privada"), callback = togglePrivacy },
                }, row_w, container))
            end
            if community.description ~= "" then
                table.insert(rows, self:textRow(community.description, row_w))
            end
            local requests = community.requests or {}
            if #requests > 0 then
                table.insert(rows, self:sectionRow(T(_("Pedidos para entrar (%1)"), #requests), row_w))
                for _idx, r in ipairs(requests) do
                    table.insert(rows, self:wrapTappable(
                        self:textRow(T("%1 (@%2)", displayName(r.display_name, r.username), r.username), row_w),
                        function() self:openUserProfile(r.username) end))
                    table.insert(rows, self:buttonRow({
                        { text = _("Aprovar"), callback = function()
                            manage(function() return ForumClient.answerJoinRequest(community.id, r.username, true) end)
                        end },
                        { text = _("Recusar"), callback = function()
                            manage(function() return ForumClient.answerJoinRequest(community.id, r.username, false) end)
                        end },
                    }, row_w, container))
                    table.insert(rows, self:separator(row_w))
                end
            end
            if not community.can_see_posts then
                table.insert(rows, self:textRow(community.is_pending
                    and T(_("Seu pedido foi enviado. Os posts aparecem aqui quando @%1 aprovar."), community.owner)
                    or T(_("Comunidade privada: só membros veem os posts. Peça para participar e aguarde a aprovação de @%1."), community.owner),
                    row_w, { dim = true }))
            end
            util.arrayAppend(rows, self:feedItems(community.topics or {}, row_w, container, rerender))
            return rows
        end,
        buttons = {
            {
                {
                    text = join_text,
                    enabled = not community.is_member or community.can_leave,
                    callback = function()
                        UIManager:close(modal)
                        self:setCommunityMembership(community, not (community.is_member or community.is_pending))
                    end,
                },
                {
                    text = _("Novo post…"),
                    enabled = community.can_post,
                    callback = function()
                        UIManager:close(modal)
                        self:openPublishDialog(nil, nil, nil, community)
                    end,
                },
            },
        },
    }
end

function Inkwell:setCommunityMembership(community, joining)
    deferredTrap(function()
        Trapper:info(joining and _("Entrando na comunidade…") or _("Saindo da comunidade…"))
        local result, err = ForumClient.setCommunityMembership(community.id, joining)
        Trapper:clear()
        if not result then
            UIManager:show(InfoMessage:new{ text = T(_("Falha: %1"), err) })
        else
            local text
            if joining then
                text = result.status == "pending" and T(_("Pedido enviado. @%1 precisa aprovar."), community.owner)
                    or T(_("Agora você faz parte de %1."), community.title)
            else
                text = community.is_pending and _("Pedido cancelado.") or T(_("Você saiu de %1."), community.title)
            end
            UIManager:show(InfoMessage:new{ text = text, timeout = 2 })
        end
        self:openCommunity(community.id)
    end)
end

-- ---------------------------------------------------------------------------
-- Login / register
-- ---------------------------------------------------------------------------

-- Test accounts seeded in mock-server (prisma/seed.js), offered as one-tap logins.
-- Labels are msgids, translated with _() when the login screen is drawn.
local TEST_ACCOUNTS = {
    { label = "Admin", email = "admin@inkwell.dev", password = "admin123" },
    { label = "Moderador", email = "moderador@inkwell.dev", password = "mod123" },
    { label = "Usuário", email = "usuario@inkwell.dev", password = "user123" },
}

-- email is only passed to refill the form after a failed attempt. The server field
-- is the API this client talks to (prefilled with the default, see README.md); it's
-- saved on submit, and clearing it goes back to the default.
function Inkwell:openLoginDialog(email)
    local modal, fields
    local function saveServer()
        ForumClient.setServerUrl(fields[1]:getText())
    end
    local function login(login_email, password)
        saveServer()
        if login_email == "" or password == "" then
            UIManager:show(InfoMessage:new{ text = _("Informe email e senha.") })
            return
        end
        UIManager:close(modal)
        NetworkMgr:runWhenOnline(function()
            self:performAuth(ForumClient.login, login_email, password, _("Entrando…"),
                function() self:openLoginDialog(login_email) end)
        end)
    end
    local function submit()
        login(util.trim(fields[2]:getText()), fields[3]:getText())
    end

    modal = self:showModal{
        title = _("Entrar no Inkwell"),
        build_rows = function(row_w, container)
            local rows
            rows, fields = self:buildFormFields(container, row_w, {
                { text = ForumClient.serverUrl(), hint = _("Servidor (ex.: https://api.exemplo.com)") },
                { text = email, hint = _("Email") },
                { hint = _("Senha"), text_type = "password" },
            }, submit)
            table.insert(rows, self:buttonRow({
                {
                    text = _("Criar conta"),
                    callback = function()
                        saveServer()
                        local typed_email = util.trim(fields[2]:getText())
                        UIManager:close(modal)
                        self:openRegisterDialog(typed_email)
                    end,
                },
                { text = _("Entrar"), callback = submit },
            }, row_w, container))
            local quick = {}
            for _idx, account in ipairs(TEST_ACCOUNTS) do
                table.insert(quick, {
                    text = _(account.label),
                    callback = function() login(account.email, account.password) end,
                })
            end
            table.insert(rows, self:textRow(_("Login rápido (contas de teste)"), row_w, { dim = true }))
            table.insert(rows, self:buttonRow(quick, row_w, container))
            return rows
        end,
    }
end

function Inkwell:openRegisterDialog(email)
    local modal, fields
    local function submit()
        local new_email, password = util.trim(fields[1]:getText()), fields[2]:getText()
        if new_email == "" or password == "" then
            UIManager:show(InfoMessage:new{ text = _("Informe email e senha.") })
            return
        end
        logger.info("Inkwell: register submit", new_email)
        UIManager:close(modal)
        NetworkMgr:runWhenOnline(function()
            logger.info("Inkwell: register online, sending")
            self:performAuth(ForumClient.register, new_email, password, _("Criando conta…"),
                function() self:openRegisterDialog(new_email) end,
                _("Conta criada! Bem-vindo(a), @%1."))
        end)
    end

    modal = self:showModal{
        title = _("Criar conta no Inkwell"),
        build_rows = function(row_w, container)
            local rows
            rows, fields = self:buildFormFields(container, row_w, {
                { text = email, hint = _("Email") },
                { hint = _("Senha"), text_type = "password" },
            }, submit)
            table.insert(rows, self:buttonRow({
                {
                    text = _("Voltar"),
                    callback = function()
                        local typed_email = util.trim(fields[1]:getText())
                        UIManager:close(modal)
                        self:openLoginDialog(typed_email)
                    end,
                },
                { text = _("Criar conta"), callback = submit },
            }, row_w, container))
            return rows
        end,
    }
end

-- auth_fn is ForumClient.login or ForumClient.register; on failure shows the server's
-- message and calls reopen so the user can fix the form without retyping the email.
-- success_text (optional, %1 = username) is shown before going to the feed.
function Inkwell:performAuth(auth_fn, email, password, busy_text, reopen, success_text)
    deferredTrap(function()
        Trapper:info(busy_text)
        local session, err = auth_fn(email, password)
        Trapper:clear()
        logger.info("Inkwell: auth result", session and session.username, err)
        if not session then
            UIManager:show(InfoMessage:new{ text = T(_("Falha: %1"), err), dismiss_callback = reopen })
            return
        end
        if success_text then
            UIManager:show(InfoMessage:new{
                text = T(success_text, session.username),
                timeout = 2,
                dismiss_callback = function() self:openForum() end,
            })
            return
        end
        self:openForum()
    end)
end

function Inkwell:logout()
    ForumClient.logout()
    UIManager:show(InfoMessage:new{ text = _("Você saiu do Inkwell."), timeout = 2 })
end

return Inkwell
