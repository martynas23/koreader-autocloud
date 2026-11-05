--[[
    Auto cloud for KOReader

    When Wi-Fi connects, asks whether to open Cloud storage or to download
    everything in a chosen cloud "inbox" folder. After downloading, the files
    in the cloud can be deleted, moved to another cloud folder, or kept.

    Opening Cloud storage uses KOReader's own Cloud storage browser (old
    apps/cloudstorage and new cloudstorage.koplugin both work). Downloading,
    deleting and moving use a small WebDAV client in this file, so that part
    needs a WebDAV server (e.g. Koofr).

    License: GNU AGPL v3
--]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ButtonDialog    = require("ui/widget/buttondialog")
local DataStorage     = require("datastorage")
local Device          = require("device")
local Event           = require("ui/event")
local InfoMessage     = require("ui/widget/infomessage")
local InputDialog     = require("ui/widget/inputdialog")
local LuaSettings     = require("luasettings")
local Menu            = require("ui/widget/menu")
local NetworkMgr      = require("ui/network/manager")
local PathChooser     = require("ui/widget/pathchooser")
local Trapper         = require("ui/trapper")
local UIManager       = require("ui/uimanager")
local ffiUtil         = require("ffi/util")
local http            = require("socket.http")
local lfs             = require("libs/libkoreader-lfs")
local logger          = require("logger")
local ltn12           = require("ltn12")
local socket          = require("socket")
local socketutil      = require("socketutil")
local util            = require("util")
local _               = require("gettext")
local N_              = _.ngettext
local T               = ffiUtil.template

local SETTING = "autocloud"
local CS_SETTINGS_FILE = DataStorage:getSettingsDir() .. "/cloudstorage.lua"

-- Seconds after startup during which the "Wi-Fi was already on" event is ignored.
local STARTUP_GRACE = 5
-- Don't prompt/open again if we did so this recently (cloud storage itself can trigger reconnects).
local DEBOUNCE = 30

local AutoCloud = WidgetContainer:extend{
    name = "autocloud",
    is_doc_only = false,
}

---------------------------------------------------------------------------
-- Paths
---------------------------------------------------------------------------

-- Remote paths are relative to the server's WebDAV address: "" is the root,
-- otherwise "/folder/sub". Never a trailing slash.
local function normPath(p)
    p = (p or ""):gsub("^/+", ""):gsub("/+$", "")
    return p == "" and "" or "/" .. p
end

local function showPath(p)
    p = normPath(p)
    return p == "" and "/" or p
end

local function parentPath(p)
    p = normPath(p)
    return (p:match("^(.*)/[^/]*$")) or ""
end

local function joinPath(dir, name)
    return normPath(normPath(dir) .. "/" .. name)
end

local function remoteUrl(server, path, is_folder)
    local address = (server.address or ""):gsub("/+$", "")
    local p = normPath(path):gsub("^/", "")
    local url = address .. "/" .. (p ~= "" and util.urlEncode(p, "/") or "")
    if is_folder and url:sub(-1) ~= "/" then url = url .. "/" end
    return url
end

local function trimSlashes(s)
    return (s:gsub("^/+", ""):gsub("/+$", ""))
end

local function ok(code) return type(code) == "number" and code >= 200 and code <= 299 end

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------

function AutoCloud:init()
    local s = G_reader_settings:readSetting(SETTING) or {}
    -- v1.0 had an on/off switch; turn it into the new "when Wi-Fi connects" choice
    if s.on_connect == nil then
        s.on_connect = (s.enabled == false) and "off" or "ask"
    end
    s.enabled = nil
    if s.in_reader == nil then s.in_reader = false end
    if s.on_startup == nil then s.on_startup = false end
    if s.after == nil then s.after = "ask" end
    if s.inbox == nil then s.inbox = "/kobo-inbox" end
    self.settings = s
    self.started_at = os.time()
    self.ui.menu:registerToMainMenu(self)
end

function AutoCloud:save()
    G_reader_settings:saveSetting(SETTING, self.settings)
end

-- Servers saved in Cloud storage (old and new KOReader use the same file/key).
function AutoCloud:getServers()
    local cs = LuaSettings:open(CS_SETTINGS_FILE)
    return cs:readSetting("cs_servers") or {}
end

-- The chosen server, or the first Koofr server, or the first server.
function AutoCloud:getServer()
    local servers = self:getServers()
    if self.settings.server_name then
        for _, s in ipairs(servers) do
            if s.name == self.settings.server_name then return s end
        end
    end
    for _, s in ipairs(servers) do
        if (s.address or ""):lower():find("koofr", 1, true) then return s end
    end
    return servers[1]
end

function AutoCloud:getLocalDir()
    local dir = self.settings.local_dir
    if dir and lfs.attributes(dir, "mode") == "directory" then return dir end
    return G_reader_settings:readSetting("home_dir") or Device.home_dir or lfs.currentdir()
end

---------------------------------------------------------------------------
-- WebDAV
---------------------------------------------------------------------------

function AutoCloud:davRequest(server, req, is_file)
    req.user = server.username
    req.password = server.password
    if is_file then
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    else
        socketutil:set_timeout()
    end
    local code, headers, status = socket.skip(1, http.request(req))
    socketutil:reset_timeout()
    if not ok(code) then
        logger.warn("AutoCloud:", req.method, req.url, "failed:", status or code)
    end
    return code, headers, status
end

-- Lists a remote folder. Returns folders, files (arrays of {name, path, size}) or nil on failure.
function AutoCloud:davList(server, path)
    local url = remoteUrl(server, path, true)
    local body = [[<?xml version="1.0"?><a:propfind xmlns:a="DAV:"><a:prop><a:resourcetype/><a:getcontentlength/></a:prop></a:propfind>]]
    local sink = {}
    local code = self:davRequest(server, {
        url = url,
        method = "PROPFIND",
        headers = {
            ["Content-Type"] = "application/xml",
            ["Depth"] = "1",
            ["Content-Length"] = #body,
        },
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(sink),
    })
    if not ok(code) then return nil end

    local self_path = trimSlashes(util.urlDecode(url:match("^%a+://[^/]+(.*)$") or "/"))
    local folders, files = {}, {}
    for item in table.concat(sink):gmatch("<[^:>]*:response[^>]*>(.-)</[^:>]*:response>") do
        local href = item:match("<[^:>]*:href[^>]*>(.-)</[^:>]*:href>")
        if href then
            local hpath = util.htmlEntitiesToUtf8(util.urlDecode(href))
            hpath = hpath:gsub("^%a+://[^/]+", "") -- some servers return full URLs
            hpath = trimSlashes(hpath)
            if hpath ~= self_path then
                local name = ffiUtil.basename(hpath)
                if item:find("<[^:>]*:collection[^<]*/>") then
                    table.insert(folders, { name = name, path = joinPath(path, name) })
                else
                    table.insert(files, {
                        name = name,
                        path = joinPath(path, name),
                        size = tonumber(item:match("getcontentlength[^>]*>(%d+)<")),
                    })
                end
            end
        end
    end
    local by_name = function(a, b) return ffiUtil.strcoll(a.name, b.name) end
    table.sort(folders, by_name)
    table.sort(files, by_name)
    return folders, files
end

function AutoCloud:davDownload(server, path, local_path)
    local tmp = local_path .. ".part"
    local fh = io.open(tmp, "wb")
    if not fh then return false end
    local code = self:davRequest(server, {
        url = remoteUrl(server, path),
        method = "GET",
        sink = ltn12.sink.file(fh), -- closes fh when done
    }, true)
    if code == 200 and os.rename(tmp, local_path) then return true end
    os.remove(tmp)
    return false
end

function AutoCloud:davDelete(server, path)
    return ok(self:davRequest(server, { url = remoteUrl(server, path), method = "DELETE" }))
end

function AutoCloud:davMove(server, path, dest_path)
    return ok(self:davRequest(server, {
        url = remoteUrl(server, path),
        method = "MOVE",
        headers = {
            ["Destination"] = remoteUrl(server, dest_path),
            ["Overwrite"] = "F",
        },
    }))
end

function AutoCloud:davMkdir(server, path)
    return ok(self:davRequest(server, { url = remoteUrl(server, path, true), method = "MKCOL" }))
end

---------------------------------------------------------------------------
-- Remote folder chooser
---------------------------------------------------------------------------

-- Lets the user browse the server's folders and pick one; calls on_choose(path).
function AutoCloud:chooseRemoteFolder(server, title, start, on_choose)
    if NetworkMgr:willRerunWhenConnected(function()
        self:chooseRemoteFolder(server, title, start, on_choose)
    end) then return end

    local menu
    local function open(path)
        local folders = self:davList(server, path)
        if not folders then
            if path ~= "" then return open("") end -- start folder gone: fall back to root
            UIManager:close(menu)
            UIManager:show(InfoMessage:new{
                text = _("Could not list cloud folders.\nCheck the server settings and your connection."),
            })
            return
        end
        local items = {
            {
                text = T(_("Use this folder: %1"), showPath(path)),
                bold = true,
                callback = function()
                    UIManager:close(menu)
                    on_choose(path)
                end,
            },
        }
        if path ~= "" then
            table.insert(items, { text = _(".. (up one folder)"), callback = function() open(parentPath(path)) end })
        end
        for _, f in ipairs(folders) do
            table.insert(items, { text = f.name .. "/", callback = function() open(f.path) end })
        end
        table.insert(items, {
            text = _("+ New folder here…"),
            callback = function()
                local dialog
                dialog = InputDialog:new{
                    title = _("New folder name"),
                    buttons = {{
                        { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
                        { text = _("Create"), is_enter_default = true, callback = function()
                            local name = dialog:getInputText()
                            UIManager:close(dialog)
                            if name and name ~= "" then
                                local new_path = joinPath(path, name)
                                if self:davMkdir(server, new_path) then
                                    open(new_path)
                                else
                                    UIManager:show(InfoMessage:new{ text = _("Could not create folder.") })
                                end
                            end
                        end },
                    }},
                }
                UIManager:show(dialog)
                dialog:onShowKeyboard()
            end,
        })
        menu:switchItemTable(T("%1: %2", title, showPath(path)), items)
    end

    menu = Menu:new{
        title = title,
        item_table = {},
        is_borderless = true,
        is_popout = false,
        covers_fullscreen = true,
    }
    UIManager:show(menu)
    open(normPath(start))
end

---------------------------------------------------------------------------
-- Opening Cloud storage
---------------------------------------------------------------------------

-- True if a cloud storage window is already on screen.
function AutoCloud:isCloudOpen()
    local okc, top = pcall(UIManager.getTopmostVisibleWidget, UIManager)
    if not okc or not top then return false end
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

function AutoCloud:openCloud()
    local server = self:getServer()
    local name = server and server.name
    local okc, err = pcall(function()
        local has_old, CloudStorage = pcall(require, "apps/cloudstorage/cloudstorage")
        if has_old and type(CloudStorage) == "table" then
            self:openOld(CloudStorage, name)
        else
            self:openNew(name)
        end
    end)
    if not okc then
        logger.warn("AutoCloud: failed to open cloud storage:", err)
        UIManager:show(InfoMessage:new{ text = _("Could not open cloud storage."), timeout = 3 })
    end
end

---------------------------------------------------------------------------
-- Downloading the inbox
---------------------------------------------------------------------------

local function needWebdav(server)
    if not server then
        UIManager:show(InfoMessage:new{ text = _("No cloud server yet. Add Koofr in Cloud storage first.") })
        return false
    end
    if server.type ~= "webdav" then
        UIManager:show(InfoMessage:new{
            text = T(_("Downloading the inbox needs a WebDAV server. \"%1\" is not one."), server.name),
        })
        return false
    end
    return true
end

-- Downloads every file in the inbox folder, then asks what to do with them in the cloud.
-- `files` may be passed in if the inbox was already listed.
function AutoCloud:downloadInbox(files)
    local server = self:getServer()
    if not needWebdav(server) then return end
    if NetworkMgr:willRerunWhenConnected(function() self:downloadInbox() end) then return end

    local inbox = normPath(self.settings.inbox)
    local local_dir = self:getLocalDir()

    Trapper:wrap(function()
        if not files then
            Trapper:info(T(_("Checking %1…"), showPath(inbox)))
            local folders
            folders, files = self:davList(server, inbox)
            if not folders then
                Trapper:clear()
                UIManager:show(InfoMessage:new{
                    text = T(_("Could not open cloud folder %1."), showPath(inbox)),
                })
                return
            end
        end
        if #files == 0 then
            Trapper:clear()
            UIManager:show(InfoMessage:new{ text = T(_("%1 is empty."), showPath(inbox)), timeout = 3 })
            return
        end

        local done, failed, existed = {}, 0, 0
        for i, f in ipairs(files) do
            local go_on = Trapper:info(T(_("Downloading %1 / %2\n%3"), i, #files, f.name))
            if not go_on then break end -- user tapped to cancel
            local local_name = util.getSafeFilename(f.name, local_dir)
            local local_path = local_dir .. "/" .. local_name
            if lfs.attributes(local_path, "mode") == "file" then
                existed = existed + 1
                table.insert(done, f) -- already on the device: still offer to clean it up in the cloud
            elseif self:davDownload(server, f.path, local_path) then
                table.insert(done, f)
            else
                failed = failed + 1
            end
        end
        Trapper:clear()

        if self.ui.file_chooser then self.ui.file_chooser:refreshPath() end

        local new = #done - existed
        local msg = T(N_("Downloaded 1 file to %2.", "Downloaded %1 files to %2.", new), new, local_dir)
        if existed > 0 then
            msg = msg .. "\n" .. T(N_("1 was already there.", "%1 were already there.", existed), existed)
        end
        if failed > 0 then
            msg = msg .. "\n" .. T(N_("1 failed.", "%1 failed.", failed), failed)
        end

        if #done == 0 then
            UIManager:show(InfoMessage:new{ text = msg })
        else
            self:afterDownload(server, inbox, done, msg)
        end
    end)
end

-- What to do with the downloaded files in the cloud: ask, delete, move or keep.
function AutoCloud:afterDownload(server, inbox, files, msg)
    local mode = self.settings.after
    local move_folder = self.settings.move_folder
    local can_move = move_folder ~= nil and normPath(move_folder) ~= inbox
    if mode == "delete" then
        return self:cleanUp(server, files, "delete", nil, msg)
    elseif mode == "move" and can_move then
        return self:cleanUp(server, files, "move", move_folder, msg)
    elseif mode == "keep" then
        return UIManager:show(InfoMessage:new{ text = msg, timeout = 4 })
    end

    local dialog
    local buttons = {
        {{ text = _("Delete from cloud"), callback = function()
            UIManager:close(dialog)
            self:cleanUp(server, files, "delete")
        end }},
    }
    if can_move then
        table.insert(buttons, {{ text = T(_("Move to %1"), showPath(move_folder)), callback = function()
            UIManager:close(dialog)
            self:cleanUp(server, files, "move", move_folder)
        end }})
    end
    table.insert(buttons, {{ text = _("Move to another folder…"), callback = function()
        UIManager:close(dialog)
        self:chooseRemoteFolder(server, _("Move to"), move_folder or "", function(path)
            if normPath(path) == inbox then
                UIManager:show(InfoMessage:new{ text = _("That's the inbox folder itself. Pick another one.") })
                return
            end
            self.settings.move_folder = path
            self:save()
            self:cleanUp(server, files, "move", path)
        end)
    end }})
    table.insert(buttons, {{ text = _("Keep in cloud"), callback = function()
        UIManager:close(dialog)
    end }})

    dialog = ButtonDialog:new{
        title = msg .. "\n\n" .. T(N_("What should happen to this file in the cloud?",
            "What should happen to these %1 files in the cloud?", #files), #files),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function AutoCloud:cleanUp(server, files, action, dest, msg)
    Trapper:wrap(function()
        local failed = 0
        for i, f in ipairs(files) do
            local label = action == "delete" and _("Deleting from cloud %1 / %2") or _("Moving %1 / %2")
            Trapper:info(T(label, i, #files), false, true) -- not cancellable: half-done is confusing
            local done_ok
            if action == "delete" then
                done_ok = self:davDelete(server, f.path)
            else
                done_ok = self:davMove(server, f.path, joinPath(dest, f.name))
            end
            if not done_ok then failed = failed + 1 end
        end
        Trapper:clear()
        local done = #files - failed
        local text
        if action == "delete" then
            text = T(N_("Deleted 1 file from the cloud.", "Deleted %1 files from the cloud.", done), done)
        else
            text = T(N_("Moved 1 file to %2.", "Moved %1 files to %2.", done), done, showPath(dest))
        end
        if failed > 0 then
            text = text .. "\n" .. T(N_("1 failed (it may already exist there).",
                "%1 failed (they may already exist there).", failed), failed)
        end
        if msg then text = msg .. "\n" .. text end
        UIManager:show(InfoMessage:new{ text = text, timeout = failed == 0 and 4 or nil })
    end)
end

---------------------------------------------------------------------------
-- Wi-Fi connected
---------------------------------------------------------------------------

function AutoCloud:showConnectPrompt()
    local server = self:getServer()
    if not server then return end
    local inbox = normPath(self.settings.inbox)

    -- peek into the inbox so the button can say how many files are waiting
    local files
    if server.type == "webdav" then
        local folders
        folders, files = self:davList(server, inbox)
        if not folders then files = nil end
    end

    local download_text, download_enabled = nil, true
    if server.type ~= "webdav" then
        download_text, download_enabled = _("Download inbox (needs WebDAV)"), false
    elseif not files then
        download_text = T(_("Download everything in %1"), showPath(inbox))
    elseif #files == 0 then
        download_text, download_enabled = T(_("%1 is empty"), showPath(inbox)), false
    else
        download_text = T(N_("Download 1 file from %2", "Download %1 files from %2", #files), #files, showPath(inbox))
    end

    local dialog
    dialog = ButtonDialog:new{
        title = T(_("Wi-Fi connected: %1"), server.name),
        buttons = {
            {{ text = _("Open cloud storage"), callback = function()
                UIManager:close(dialog)
                self:openCloud()
            end }},
            {{ text = download_text, enabled = download_enabled, callback = function()
                UIManager:close(dialog)
                self:downloadInbox(files)
            end }},
            {{ text = _("Not now"), callback = function()
                UIManager:close(dialog)
            end }},
        },
    }
    UIManager:show(dialog)
end

function AutoCloud:onWifiConnected()
    local mode = self.settings.on_connect
    if mode == "off" then return end
    if self.ui.document and not self.settings.in_reader then return end
    local now = os.time()
    if not self.settings.on_startup and now - self.started_at < STARTUP_GRACE then return end
    if self.last_run and now - self.last_run < DEBOUNCE then return end
    if self:isCloudOpen() then return end
    self.last_run = now

    if mode == "open" then
        self:openCloud()
    elseif mode == "download" then
        -- only bother the user if there is something to download
        local server = self:getServer()
        if server and server.type == "webdav" then
            local folders, files = self:davList(server, normPath(self.settings.inbox))
            if folders and #files > 0 then self:downloadInbox(files) end
        end
    else
        self:showConnectPrompt()
    end
end

function AutoCloud:onNetworkConnected()
    -- let the network finish settling and other handlers run first
    UIManager:scheduleIn(1, function() self:onWifiConnected() end)
end

---------------------------------------------------------------------------
-- Menu
---------------------------------------------------------------------------

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
    local function radio(key, value, text)
        return {
            text = text,
            radio = true,
            checked_func = function() return self.settings[key] == value end,
            callback = function()
                self.settings[key] = value
                self:save()
            end,
        }
    end
    -- picks a cloud folder from the menu and stores it in settings[key]
    local function cloudFolderItem(key, label, title)
        return {
            text_func = function()
                return T(label, self.settings[key] and showPath(self.settings[key]) or _("not set"))
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local server = self:getServer()
                if not needWebdav(server) then return end
                self:chooseRemoteFolder(server, title, self.settings[key] or "", function(path)
                    self.settings[key] = path
                    self:save()
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end)
            end,
        }
    end
    local on_connect_names = {
        ask = _("ask"), open = _("open cloud storage"), download = _("download inbox"), off = _("do nothing"),
    }
    local after_names = {
        ask = _("ask"), delete = _("delete"), move = _("move"), keep = _("keep"),
    }

    local move_item = cloudFolderItem("move_folder", _("Move to (cloud): %1"), _("Move to"))
    move_item.separator = true

    menu_items.autocloud = {
        text = _("Auto cloud"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text_func = function()
                    return T(_("When Wi-Fi connects: %1"), on_connect_names[self.settings.on_connect])
                end,
                sub_item_table = {
                    radio("on_connect", "ask", _("Ask: open cloud or download inbox")),
                    radio("on_connect", "open", _("Open cloud storage")),
                    radio("on_connect", "download", _("Download inbox (if not empty)")),
                    radio("on_connect", "off", _("Do nothing")),
                },
            },
            toggle("in_reader", _("Also while reading a book")),
            toggle("on_startup", _("Also if Wi-Fi is already on at startup")),
            {
                text_func = function()
                    local s = self:getServer()
                    return T(_("Server: %1"), s and s.name or _("none"))
                end,
                sub_item_table_func = function() return self:getServerMenu() end,
                separator = true,
            },
            cloudFolderItem("inbox", _("Download from (cloud): %1"), _("Download from")),
            {
                text_func = function()
                    return T(_("Save to (this device): %1"), self:getLocalDir())
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    UIManager:show(PathChooser:new{
                        select_directory = true,
                        select_file = false,
                        path = self:getLocalDir(),
                        onConfirm = function(path)
                            self.settings.local_dir = path
                            self:save()
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                    })
                end,
            },
            {
                text_func = function()
                    return T(_("After downloading: %1"), after_names[self.settings.after])
                end,
                sub_item_table = {
                    radio("after", "ask", _("Ask: delete, move or keep")),
                    radio("after", "delete", _("Delete from cloud")),
                    radio("after", "move", _("Move to the folder below")),
                    radio("after", "keep", _("Keep in cloud")),
                },
            },
            move_item,
            {
                text = _("Download inbox now"),
                callback = function() self:downloadInbox() end,
            },
            {
                text = _("Open cloud storage now"),
                callback = function() self:openCloud() end,
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
            radio = true,
            checked_func = function()
                local cur = self:getServer()
                return cur ~= nil and cur.name == name
            end,
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

return AutoCloud
