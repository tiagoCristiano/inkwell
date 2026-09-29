local _ = require("gettext")
-- Loaded by the plugin manager before the plugin's own modules are reachable, so this stays
-- in the default language (English) instead of going through i18n.lua.
return {
    name = "inkwell",
    fullname = _("Inkwell"),
    description = _([[A social network for readers: share posts, reviews and highlights, follow people, join communities and track your shelf.]]),
}
