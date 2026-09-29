--[[--
Downloads and caches user avatar images locally, and builds a rounded-corner
avatar widget from a local image file. KOReader has no real circular image
clipping, so this renders a square photo with rounded corners rather than a
true circle.
]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local DataStorage = require("datastorage")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local ImageWidget = require("ui/widget/imagewidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local ForumClient = require("client")

local Avatar = {}

local CACHE_DIR = DataStorage:getDataDir() .. "/cache/inkwell_avatars"

local function ensureCacheDir()
    if lfs.attributes(CACHE_DIR, "mode") ~= "directory" then
        lfs.mkdir(CACHE_DIR)
    end
end

local CACHE_EXTS = { "jpg", "png", "gif", "webp" }

-- Base path (no extension): downloadAvatarTo appends the real extension it detects
-- from the response's Content-Type, since ImageWidget picks its decoder by extension.
local function cacheBasePathFor(username)
    return CACHE_DIR .. "/" .. username:gsub("[^%w_-]", "_")
end

-- Finds an already-cached avatar file for username, in any of the extensions we save
-- with. Returns nil if none exists (or exists but looks like a partial download).
local function findCached(base_path)
    for _, ext in ipairs(CACHE_EXTS) do
        local path = base_path .. "." .. ext
        -- Reject a suspiciously tiny cached file (e.g. an interrupted/partial download)
        -- as if it weren't cached at all, so it gets re-downloaded below instead of
        -- being handed to ImageWidget as-is.
        local size = lfs.attributes(path, "size")
        if size and size > 100 then
            return path
        end
    end
    return nil
end

-- Downloads username's avatar (from avatar_url) to the local cache if not already
-- there, and returns the local file path. Returns nil if there's no avatar or the
-- download fails; callers should fall back to an initial-letter avatar in that case.
function Avatar.ensureLocal(username, avatar_url)
    if not avatar_url or avatar_url == "" then
        return nil
    end
    ensureCacheDir()
    local base_path = cacheBasePathFor(username)
    local cached = findCached(base_path)
    if cached then
        return cached
    end
    local saved_path, err = ForumClient.downloadAvatarTo(avatar_url, base_path)
    if not saved_path then
        logger.warn("Inkwell: failed to download avatar for", username, "from", avatar_url, ":", err)
        return nil, err
    end
    return saved_path
end

local function initialPlaceholder(photo_size, username)
    return CenterContainer:new{
        dimen = Geom:new{ w = photo_size, h = photo_size },
        TextWidget:new{
            text = username and username:sub(1, 1):upper() or "?",
            face = Font:getFace("cfont", math.floor(photo_size * 0.5)),
            bold = true,
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        },
    }
end

-- An ImageWidget fitted (aspect kept) inside w x h, or nil when image_path is nil or
-- isn't a decodable image (e.g. a partial/corrupt download) — ImageWidget:init() can
-- raise a Lua error for unsupported/broken files, and a bad image must never take down
-- the whole screen that's trying to show it.
function Avatar.image(image_path, w, h)
    if not image_path then
        return nil
    end
    -- ImageWidget only actually decodes the file lazily, the first time its size
    -- (or draw) is queried, so the pcall must cover getSize() too, not just new{}.
    local ok, widget = pcall(function()
        local image = ImageWidget:new{
            file = image_path,
            width = w,
            height = h,
            scale_factor = 0, -- best-fit, keep aspect ratio
        }
        image:getSize()
        return image
    end)
    if ok then
        return widget
    end
    -- Corrupt/undecodable cached file: remove it so the next ensureLocal()
    -- call re-downloads instead of hitting this same broken cache forever.
    os.remove(image_path)
    return nil
end

-- A cover image (book or community), downloaded/cached like avatars. Keyed by the URL's
-- md5, so a new version (community covers carry ?v=<updated_at>) is a new cache entry.
function Avatar.cover(cover_url, w, h)
    local path = Avatar.ensureLocal("cover_" .. require("ffi/sha2").md5(cover_url), cover_url)
    return Avatar.image(path, w, h)
end

-- Builds a square avatar widget, with a thin rounded-corner frame around it.
-- KOReader doesn't clip the image itself to the frame's radius (the photo stays a
-- plain square underneath), so the border is drawn as a distinct ring around the
-- photo rather than an actual rounded crop of it.
-- image_path may be nil (no avatar set, or download failed): falls back to a plain
-- initial-letter placeholder, keyed off username, so callers never need to branch
-- (same fallback when the file isn't a decodable image).
function Avatar.widget(image_path, size, username)
    local border = Size.border.thick
    local photo_size = size - 2 * border

    local content = Avatar.image(image_path, photo_size, photo_size)
    content = content or initialPlaceholder(photo_size, username)

    return FrameContainer:new{
        bordersize = border,
        color = Blitbuffer.COLOR_LIGHT_GRAY,
        padding = 0,
        radius = Size.radius.window,
        background = Blitbuffer.COLOR_WHITE,
        width = size,
        height = size,
        content,
    }
end

return Avatar
