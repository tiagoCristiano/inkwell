local http = require("socket.http")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local mime = require("mime")
local socket = require("socket")
local socketutil = require("socketutil")
local url = require("socket.url")
local JSON = require("json")
local _ = require("i18n")

-- socket.http can't speak TLS; ssl.https (LuaSec, bundled with KOReader) has the same API.
local function httpFor(u)
    return u:match("^https://") and https or http
end

local ForumClient = {}

-- Used until the user types another server on the login screen (see README.md).
local DEFAULT_SERVER_URL = "https://inkwell-server-0n1p.onrender.com"

-- Base URL of the Inkwell-compatible API this client talks to.
function ForumClient.serverUrl()
    return G_reader_settings:readSetting("inkwell_server_url") or DEFAULT_SERVER_URL
end

-- Trims whitespace and trailing slashes; an empty value goes back to the default.
function ForumClient.setServerUrl(u)
    u = (u or ""):gsub("^%s+", ""):gsub("[%s/]+$", "")
    if u == "" then
        G_reader_settings:delSetting("inkwell_server_url")
    else
        G_reader_settings:saveSetting("inkwell_server_url", u)
    end
    G_reader_settings:flush()
end

-- Current session, set by ForumClient.login() and persisted in KOReader's settings so a
-- restart keeps the user logged in. Nil until the user logs in.
local session = G_reader_settings:readSetting("inkwell_session") -- { token, username, can_create_moderator }

local function setSession(new_session)
    session = new_session
    if session then
        G_reader_settings:saveSetting("inkwell_session", session)
    else
        G_reader_settings:delSetting("inkwell_session")
    end
    G_reader_settings:flush()
end

-- lua-rapidjson decodes JSON `null` as a special sentinel that is truthy in Lua, not
-- `nil`. Replace it with plain `nil` everywhere so the rest of the plugin can keep using
-- ordinary `if field then` checks on decoded API data.
-- Match by type (not just `== JSON.null`) since the exact sentinel identity/type has
-- proven unreliable in practice: it has shown up as userdata/lightuserdata in some
-- calls and as a plain function value in others. Any of those in decoded JSON is null;
-- a decoded document never legitimately contains a function.
local function isJsonNull(v)
    local t = type(v)
    return v == JSON.null or t == "userdata" or t == "lightuserdata" or t == "function"
end

local function stripJsonNull(value)
    if type(value) ~= "table" then
        return value
    end
    for k, v in pairs(value) do
        if isJsonNull(v) then
            value[k] = nil
        elseif type(v) == "table" then
            stripJsonNull(v)
        end
    end
    return value
end

local function request(method, path, body, token)
    local base_url = ForumClient.serverUrl()
    local sink = {}
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local headers = {
        ["Accept-Encoding"] = "identity",
        ["Content-Type"] = "application/json",
        ["Accept-Language"] = _.lang(), -- server-written messages (e.g. usage limits) follow the UI language
    }
    if token then
        headers["Authorization"] = "Bearer " .. token
    end
    local encoded_body = body and JSON.encode(body) or nil
    if encoded_body then
        headers["Content-Length"] = tostring(#encoded_body)
    end
    local code, resp_headers, status = socket.skip(1, httpFor(base_url).request{
        url = base_url .. path,
        method = method,
        headers = headers,
        source = encoded_body and ltn12.source.string(encoded_body) or nil,
        sink = ltn12.sink.table(sink),
    })
    socketutil:reset_timeout()

    local resp_body = table.concat(sink)
    local ok, decoded = pcall(JSON.decode, resp_body)
    return code, (ok and stripJsonNull(decoded) or nil), status
end

function ForumClient.isLoggedIn()
    return session ~= nil
end

function ForumClient.username()
    return session and session.username
end

-- Capability flag sent by the server at login; the client never looks at roles.
function ForumClient.canCreateModerator()
    return session and session.can_create_moderator == true
end

function ForumClient.logout()
    setSession(nil)
end

-- Shared by login/register: on success the returned session becomes the active one
-- (replacing any previous one) and subsequent ForumClient calls use it. On failure,
-- returns nil + the server's own error message when it sent one.
local function authenticate(path, email, password, ok_code)
    local code, data, status = request("POST", path, { email = email, password = password })
    if code ~= ok_code or not data or not data.token then
        if data and data.error then
            return nil, data.error
        end
        return nil, string.format("HTTP %s (%s)", tostring(code), tostring(status))
    end
    setSession({ token = data.token, username = data.username, can_create_moderator = data.can_create_moderator })
    return session
end

function ForumClient.login(email, password)
    return authenticate("/auth/login", email, password, 200)
end

-- Creates the account and logs straight into it.
function ForumClient.register(email, password)
    return authenticate("/auth/register", email, password, 201)
end

-- GET/POST/PUT/DELETE an API path as the logged-in user. Returns decoded JSON
-- (or true for empty 204 responses), or nil+err. Requires an active session.
function ForumClient.call(method, path, body)
    if not session then
        return nil, _("Você precisa fazer login primeiro")
    end

    local code, data, status = request(method, path, body, session.token)
    if code == 401 then
        setSession(nil)
        return nil, _("Sessão expirada, faça login novamente")
    end
    if code == 403 then
        return nil, (data and data.error) or _("Você não tem permissão para isso")
    end
    if code == 204 then
        return true
    end
    if code ~= 200 and code ~= 201 then
        local msg = (data and data.error) or string.format("HTTP %s (%s)", tostring(code), tostring(status))
        return nil, msg
    end
    return data
end

-- feed: "following" (people you follow + you), "reviews" (resenhas) or "all". Returns the raw page:
-- { topics, has_more, total, unread_notifications }, or nil+err.
function ForumClient.listTopics(offset, limit, feed)
    return ForumClient.call("GET",
        string.format("/topics?offset=%d&limit=%d&feed=%s", offset or 0, limit or 2, feed or "all"))
end

function ForumClient.search(query)
    local data, err = ForumClient.call("GET", "/topics/search?q=" .. url.escape(query))
    if not data then
        return nil, err
    end
    return data.topics
end

function ForumClient.getTopic(id)
    local data, err = ForumClient.call("GET", "/topics/" .. id)
    if not data then
        return nil, err
    end
    return data.topic
end

function ForumClient.myPosts()
    local data, err = ForumClient.call("GET", "/me/posts")
    if not data then
        return nil, err
    end
    return data.posts
end

-- post: { title, selftext, book_title, book_author, hashtags, community_id, quoted_id, rating };
-- community_id posts inside that community instead of the home feed, quoted_id quotes a post,
-- rating (0-5) makes it a resenha.
function ForumClient.createTopic(post)
    local data, err = ForumClient.call("POST", "/topics", post)
    if not data then
        return nil, err
    end
    return data.topic
end

function ForumClient.listCommunities()
    local data, err = ForumClient.call("GET", "/communities")
    if not data then
        return nil, err
    end
    return data.communities
end

-- Returns the community with its topics (summaries, newest first).
function ForumClient.getCommunity(id)
    local data, err = ForumClient.call("GET", "/communities/" .. id)
    if not data then
        return nil, err
    end
    return data.community
end

-- Join (joining=true) or leave / cancel the request. Joining returns { status = "member" |
-- "pending" } (private communities wait for the owner); leaving returns true. nil+err on failure.
function ForumClient.setCommunityMembership(id, joining)
    return ForumClient.call(joining and "POST" or "DELETE", "/communities/" .. id .. "/members")
end

-- Owner-only: approve (true) or refuse a join request. Returns true, or nil+err.
function ForumClient.answerJoinRequest(id, username, approve)
    return ForumClient.call(approve and "POST" or "DELETE", "/communities/" .. id .. "/requests/" .. url.escape(username))
end

-- Owner-only. Returns the updated community summary.
function ForumClient.setCommunityPrivacy(id, is_private)
    local data, err = ForumClient.call("PUT", "/communities/" .. id .. "/privacy", { is_private = is_private })
    if not data then
        return nil, err
    end
    return data.community
end

function ForumClient.createCommunity(title, description)
    local data, err = ForumClient.call("POST", "/communities", {
        title = title,
        description = description,
    })
    if not data then
        return nil, err
    end
    return data.community
end

function ForumClient.updateTopic(id, title, selftext)
    local data, err = ForumClient.call("PUT", "/topics/" .. id, {
        title = title,
        selftext = selftext,
    })
    if not data then
        return nil, err
    end
    return data.topic
end

function ForumClient.deleteTopic(id)
    local ok, err = ForumClient.call("DELETE", "/topics/" .. id)
    if not ok then
        return nil, err
    end
    return true
end

-- parent_id, when given, makes this comment a reply to that existing comment.
function ForumClient.addComment(topic_id, body, parent_id)
    local data, err = ForumClient.call("POST", "/topics/" .. topic_id .. "/comments", {
        body = body,
        parent_id = parent_id,
    })
    if not data then
        return nil, err
    end
    return data.topic
end

-- Deletes a comment by its own id (also cascades to its replies, server-side).
function ForumClient.deleteComment(topic_id, comment_id)
    local data, err = ForumClient.call("DELETE", "/topics/" .. topic_id .. "/comments/" .. comment_id)
    if not data then
        return nil, err
    end
    return data.topic
end

function ForumClient.getMyProfile()
    local data, err = ForumClient.call("GET", "/me/profile")
    if not data then
        return nil, err
    end
    return data.profile
end

function ForumClient.updateMyProfile(display_name, bio, gender, age, is_public)
    local data, err = ForumClient.call("PUT", "/me/profile", {
        display_name = display_name,
        bio = bio,
        gender = gender,
        age = age,
        is_public = is_public,
    })
    if not data then
        return nil, err
    end
    return data.profile
end

function ForumClient.getUserProfile(username)
    local data, err = ForumClient.call("GET", "/users/" .. url.escape(username))
    if not data then
        return nil, err
    end
    return data.profile
end

-- Admin-only: creates a new moderator account; returns { username, role }.
function ForumClient.createModerator(email, password)
    local data, err = ForumClient.call("POST", "/admin/users", {
        email = email,
        password = password,
    })
    if not data then
        return nil, err
    end
    return data
end

-- Calls the API and returns data[key] (or the whole body when key is nil), or nil+err.
local function fetch(method, path, key, body)
    local data, err = ForumClient.call(method, path, body)
    if not data then
        return nil, err
    end
    return key and data[key] or data
end

-- Like (liking=true) or unlike. Returns { liked, num_likes }.
function ForumClient.setTopicLike(id, liking)
    return fetch(liking and "POST" or "DELETE", "/topics/" .. id .. "/like")
end

function ForumClient.setCommentLike(id, liking)
    return fetch(liking and "POST" or "DELETE", "/comments/" .. id .. "/like")
end

-- Follow (following=true) or unfollow. Returns { following, num_followers }.
function ForumClient.setFollow(username, following)
    return fetch(following and "POST" or "DELETE", "/users/" .. url.escape(username) .. "/follow")
end

-- which: "followers" or "following". Returns a list of user cards.
function ForumClient.people(username, which)
    return fetch("GET", "/users/" .. url.escape(username) .. "/" .. which, "users")
end

function ForumClient.suggestions()
    return fetch("GET", "/me/suggestions", "users")
end

-- Returns { notifications, unread }.
function ForumClient.notifications()
    return fetch("GET", "/me/notifications")
end

function ForumClient.markNotificationsRead()
    return fetch("POST", "/me/notifications/read")
end

-- Updates the shelf entry for a book. status: nil (automatic sync), "want", "reading"
-- (re-read) or "finished"; background: sync on closing the book (only updates books already
-- on the shelf). Returns { entry, started, finished_now }.
function ForumClient.pushReading(book_title, book_author, progress, status, background)
    return fetch("PUT", "/me/reading", nil, {
        book_title = book_title,
        book_author = book_author,
        progress = progress,
        status = status,
        background = background,
    })
end

local function bookQuery(title, author)
    return "?title=" .. url.escape(title) .. "&author=" .. url.escape(author or "")
end

function ForumClient.removeReading(book_title, book_author)
    return fetch("DELETE", "/me/reading" .. bookQuery(book_title, book_author))
end

-- author tells apart different books with the same title (optional).
-- Returns { title, author, cover_url, my_entry, readers, topics }.
function ForumClient.getBook(title, author)
    return fetch("GET", "/books" .. bookQuery(title, author), "book")
end

-- Owner-only. cover: { data = base64, content_type }. Returns the updated community summary.
function ForumClient.setCommunityCover(id, cover)
    return fetch("PUT", "/communities/" .. id .. "/cover", "community", cover)
end

-- Returns { hashtags = {{tag, count}}, books = {{title, author, count}} }.
function ForumClient.trending()
    return fetch("GET", "/trending")
end

local CONTENT_TYPE_BY_EXT = {
    jpg = "image/jpeg",
    jpeg = "image/jpeg",
    png = "image/png",
    gif = "image/gif",
    webp = "image/webp",
}

-- Reads a local image file, base64-encodes it, and sets it as the logged-in user's avatar.
function ForumClient.uploadAvatar(file_path)
    local f = io.open(file_path, "rb")
    if not f then
        return nil, _("Não foi possível abrir o arquivo de imagem")
    end
    local raw = f:read("*a")
    f:close()
    if not raw or raw == "" then
        return nil, _("Arquivo de imagem vazio")
    end

    local ext = file_path:match("%.([%a0-9]+)$")
    local content_type = ext and CONTENT_TYPE_BY_EXT[ext:lower()] or "image/jpeg"

    local data, err = ForumClient.call("PUT", "/me/avatar", {
        data = (mime.b64(raw)),
        content_type = content_type,
    })
    if not data then
        return nil, err
    end
    return data.avatar_url
end

local EXT_BY_CONTENT_TYPE = {
    ["image/jpeg"] = "jpg",
    ["image/png"] = "png",
    ["image/gif"] = "gif",
    ["image/webp"] = "webp",
}

-- Downloads avatar_url's bytes and writes them to dest_path_no_ext + an extension picked
-- from the response's Content-Type (ImageWidget picks its decoder by file extension, so a
-- bare/generic extension makes it refuse to render the file). No auth: avatar URLs are
-- plain public image links, so this bypasses ForumClient.call (which expects JSON+token).
-- Returns the actual saved path (dest_path_no_ext .. "." .. ext) on success.
function ForumClient.downloadAvatarTo(avatar_url, dest_path_no_ext)
    local sink = {}
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local code, headers = socket.skip(1, httpFor(avatar_url).request{
        url = avatar_url,
        method = "GET",
        sink = ltn12.sink.table(sink),
    })
    socketutil:reset_timeout()

    if code ~= 200 then
        return nil, string.format("HTTP %s ao baixar avatar", tostring(code))
    end
    local body = table.concat(sink)
    if body == "" then
        return nil, _("Avatar vazio")
    end

    local content_type = headers and headers["content-type"]
    local ext = content_type and EXT_BY_CONTENT_TYPE[content_type:match("^[^;]+"):lower()] or "jpg"
    local dest_path = dest_path_no_ext .. "." .. ext

    local f, ferr = io.open(dest_path, "wb")
    if not f then
        return nil, ferr or _("Não foi possível salvar o avatar localmente")
    end
    f:write(body)
    f:close()
    return dest_path
end

return ForumClient
