--[[
    Auto-open cloud storage for KOReader

    When Wi-Fi connects, opens KOReader's Cloud storage straight into one of
    your saved servers (by default the first one whose address mentions
    "koofr"). The server can be picked in Tools > Auto-open cloud storage.

    Works with KOReader versions where Cloud storage lives in
    apps/cloudstorage (no "Set as default" option), and with newer versions
    where it is a plugin.

    License: GNU AGPL v3
--]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local DataStorage     = require("datastorage")
local LuaSettings     = require("luasettings")
local UIManager       = require("ui/uimanager")
local Event           = require("ui/event")
local InfoMessage     = require("ui/widget/infomessage")
local logger          = require("logger")
local _               = require("gettext")
local T               = require("ffi/util").template

local SETTING = "autocloud"
local CS_SETTINGS_FILE = DataStorage:getSettingsDir() .. "/cloudstorage.lua"

local AutoCloud = WidgetContainer:extend{
    name = "autocloud",
    is_doc_only = false,
}

-- Seconds after startup during which the "Wi-Fi was already on" event is ignored.
local STARTUP_GRACE = 5
-- Don't reopen if we opened it this recently (cloud storage itself can trigger reconnects).
local DEBOUNCE = 30

function AutoCloud:init()
    self.settings = G_reader_settings:readSetting(SETTING) or {}
    if self.settings.enabled == nil then self.settings.enabled = true end
    if self.settings.in_reader == nil then self.settings.in_reader = false end
    if self.settings.on_startup == nil then self.settings.on_startup = false end
    self.started_at = os.time()
    self.ui.menu:registerToMainMenu(self)
end

function AutoCloud:save()
    G_reader_settings:saveSetting(SETTING, self.settings)
end

-- Servers saved in Cloud storage (both old and new versions use this file/key).
function AutoCloud:getServers()
    local cs = LuaSettings:open(CS_SETTINGS_FILE)
    return cs:readSetting("cs_servers") or {}
end

-- The chosen server's name, or the first Koofr server, or the first server.
function AutoCloud:getTargetName()
    local servers = self:getServers()
    if self.settings.server_name then
        for _, s in ipairs(servers) do
            if s.name == self.settings.server_name then return s.name end
        end
    end
    for _, s in ipairs(servers) do
        if (s.address or ""):lower():find("koofr", 1, true) then return s.name end
    end
    return servers[1] and servers[1].name
end

function AutoCloud:addToMainMenu(menu_items)
    local function toggle(key, text)
        return {
            text = text,
            checked_func = function() return self.settings[key] end,
            callback = function()
                self.settings[key] = not self.settings[key]
                self:save()
            end,
        }
    end
    menu_items.autocloud = {
        text = _("Auto-open cloud storage"),
        sorting_hint = "tools",
        sub_item_table = {
            toggle("enabled", _("Open cloud storage when Wi-Fi connects")),
            toggle("in_reader", _("Also while reading a book")),
            toggle("on_startup", _("Also if Wi-Fi is already on at startup")),
            {
                text_func = function()
                    return T(_("Server: %1"), self:getTargetName() or _("none"))
                end,
                sub_item_table_func = function() return self:getServerMenu() end,
            },
            {
                text = _("Open now"),
                separator = true,
                callback = function() self:openCloud(true) end,
            },
        },
    }
end

function AutoCloud:getServerMenu()
    local items = {}
    for _, s in ipairs(self:getServers()) do
        local name = s.name
        table.insert(items, {
            text = name,
            checked_func = function() return self:getTargetName() == name end,
            callback = function()
                self.settings.server_name = name
                self:save()
            end,
        })
    end
    if #items == 0 then
        table.insert(items, {
            text = _("No servers yet. Add Koofr in Cloud storage first."),
            enabled_func = function() return false end,
        })
    end
    return items
end

-- True if a cloud storage window is already on screen.
function AutoCloud:isCloudOpen()
    local ok, top = pcall(UIManager.getTopmostVisibleWidget, UIManager)
    if not ok or not top then return false end
    return top.cs_settings ~= nil                      -- old apps/cloudstorage widget
        or (top._manager ~= nil and top.providers ~= nil) -- new plugin widget
end

-- Old KOReader: build the Cloud storage window and "tap" the target server.
function AutoCloud:openOld(CloudStorage, name)
    local cs = CloudStorage:new{ ui = self.ui }
    UIManager:show(cs)
    if not name then return end
    for _, item in ipairs(cs.item_table or {}) do
        if item.text == name then
            UIManager:nextTick(function() cs:onMenuSelect(item) end)
            return
        end
    end
end

-- New KOReader (cloudstorage.koplugin): open that server directly.
function AutoCloud:openNew(name)
    local plugin = self.ui.cloudstorage
    if not (plugin and name) then
        self.ui:handleEvent(Event:new("ShowCloudStorageList"))
        return
    end
    plugin:loadSettings()
    local idx
    for i, s in ipairs(plugin.servers or {}) do
        if s.name == name then idx = i break end
    end
    if not idx then
        self.ui:handleEvent(Event:new("ShowCloudStorageList"))
        return
    end
    -- temporarily mark it as the default so show() goes straight in
    local cs_settings = plugin.settings
    local prev = cs_settings:readSetting("default_server")
    cs_settings:saveSetting("default_server", idx)
    plugin:onShowCloudStorageList()
    if prev then cs_settings:saveSetting("default_server", prev)
    else cs_settings:delSetting("default_server") end
end

function AutoCloud:openCloud(manual)
    if not manual then
        if not self.settings.enabled then return end
        if self.ui.document and not self.settings.in_reader then return end
        local now = os.time()
        if not self.settings.on_startup and now - self.started_at < STARTUP_GRACE then return end
        if self.last_open and now - self.last_open < DEBOUNCE then return end
        if self:isCloudOpen() then return end
        self.last_open = now
    end
    local name = self:getTargetName()
    logger.dbg("AutoCloud: opening cloud storage, server:", name)
    local ok, err = pcall(function()
        local has_old, CloudStorage = pcall(require, "apps/cloudstorage/cloudstorage")
        if has_old and type(CloudStorage) == "table" then
            self:openOld(CloudStorage, name)
        else
            self:openNew(name)
        end
    end)
    if not ok then
        logger.warn("AutoCloud: failed to open cloud storage:", err)
        if manual then
            UIManager:show(InfoMessage:new{ text = _("Could not open cloud storage."), timeout = 3 })
        end
    end
end

function AutoCloud:onNetworkConnected()
    -- let the network finish settling and other handlers run first
    UIManager:scheduleIn(1, function() self:openCloud(false) end)
end

return AutoCloud
