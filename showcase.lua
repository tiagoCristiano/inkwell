--[[--
Dev-only screen listing every KOReader widget this plugin actually uses, each
row opening a live example. Not linked from user-facing flows beyond the nav
menu's "Showcase (dev)" entry — exists so a new widget/style can be eyeballed
on-device without digging through the real screens that happen to use it.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local _ = require("i18n")

local Showcase = {}

-- Fake profile, shaped like what ForumClient.getUserProfile() returns, so the real
-- (already-tested) showUserProfile screen can be reused here instead of re-rendering
-- the avatar/header widgets from scratch.
local FAKE_PROFILE = {
    username = "inkwell_demo",
    display_name = "Usuário de Exemplo",
    badge = "admin",
    bio = "Bio de exemplo para o showcase de componentes.",
    avatar_url = nil,
    recent_posts = {},
}

local function showButtonDialog()
    local dialog
    dialog = ButtonDialog:new{
        title = _("Exemplo de ButtonDialog"),
        buttons = {
            {{
                text = _("Ação 1"),
                align = "left",
                callback = function() UIManager:close(dialog) end,
            }},
            {{
                text = _("Ação 2"),
                align = "left",
                callback = function() UIManager:close(dialog) end,
            }},
            {},
            {
                { text = _("Cancelar"), callback = function() UIManager:close(dialog) end },
                { text = _("OK"), callback = function() UIManager:close(dialog) end },
            },
        },
    }
    UIManager:show(dialog)
end

local function showConfirmBox()
    UIManager:show(ConfirmBox:new{
        text = _("Exemplo de ConfirmBox. Confirmar?"),
        ok_text = _("Sim"),
        cancel_text = _("Não"),
    })
end

local function showInfoMessage()
    UIManager:show(InfoMessage:new{ text = _("Exemplo de InfoMessage."), timeout = 2 })
end

local function showInputDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("Exemplo de InputDialog"),
        input_hint = _("Digite algo…"),
        buttons = {{
            { text = _("Cancelar"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("OK"), is_enter_default = true, callback = function() UIManager:close(dialog) end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local function showMultiInputDialog()
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Exemplo de MultiInputDialog"),
        fields = {
            { hint = _("Campo 1") },
            { hint = _("Campo 2 (senha)"), text_type = "password" },
        },
        buttons = {{
            { text = _("Cancelar"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("OK"), is_enter_default = true, callback = function() UIManager:close(dialog) end },
        }},
    }
    UIManager:show(dialog)
end

local function showMenuList()
    local menu
    menu = Menu:new{
        title = _("Exemplo de Menu (lista)"),
        item_table = {
            { text = _("Item simples") },
            { text = _("Item com mandatory"), mandatory = "12" },
            { text = _("Item esmaecido"), dim = true },
        },
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        close_callback = function() UIManager:close(menu) end,
    }
    UIManager:show(menu)
end

-- Index screen: one row per widget example above. inkwell is the live Inkwell
-- instance (from main.lua), reused here to show the Avatar/profile header example
-- through the same showUserProfile screen real profiles use.
function Showcase.open(inkwell)
    local item_table = {
        { text = "ButtonDialog", callback = showButtonDialog },
        { text = "ConfirmBox", callback = showConfirmBox },
        { text = "InfoMessage", callback = showInfoMessage },
        { text = "InputDialog", callback = showInputDialog },
        { text = "MultiInputDialog", callback = showMultiInputDialog },
        { text = "Menu (lista)", callback = showMenuList },
        {
            text = "Avatar + perfil (showUserProfile)",
            callback = function() inkwell:showUserProfile(FAKE_PROFILE) end,
        },
    }

    local menu
    menu = Menu:new{
        title = _("Showcase de componentes"),
        item_table = item_table,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        onMenuSelect = function(_self, item)
            if item.callback then item.callback() end
        end,
        close_callback = function() UIManager:close(menu) end,
    }
    UIManager:show(menu)
end

return Showcase
