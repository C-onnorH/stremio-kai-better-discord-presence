--[[
  Discord presence for Stremio Kai  -  scripts/discord-presence/main.lua

  What it does
    * The web mod (webmods/Discord/discord-presence-bridge.js) tells this script
      which title / episode is playing (clean name, poster, IMDb id).
    * This script watches mpv (pause, seek, position, duration) and writes the
      current "what should Discord show" as a small JSON file in %TEMP%.
    * discord-rpc.ps1 (same folder) keeps the connection to Discord open and
      pushes whatever is in that file. It is started on first use and quits
      by itself when Kai closes.

  Settings: script-opts/discord_presence.conf
  Log of the helper: %TEMP%\kai-discord-presence.log
]]

local mp      = require 'mp'
local utils   = require 'mp.utils'
local msg     = require 'mp.msg'
local options = require 'mp.options'

local opts = {
    enabled             = true,
    -- Discord application that owns the presence. This is the same ID the Stremio
    -- shell uses, so the app is called "Stremio". Use your own to rename it.
    client_id           = "1361448446862692492",
    -- 0 = app name, 1 = state line, 2 = details line (the title)  -> "Watching <title>"
    status_display_type = 2,
    show_buttons        = true,   -- "View on IMDb" button
    show_poster         = true,   -- poster as the large image
    debug               = false,
}
options.read_options(opts, "discord_presence")

if not opts.enabled then
    msg.info("disabled in script-opts/discord_presence.conf")
    return
end

local SCRIPT_DIR = mp.get_script_directory() or "."
local HELPER_PS1 = utils.join_path(SCRIPT_DIR, "discord-rpc.ps1")

local function temp_dir()
    return os.getenv("TEMP") or os.getenv("TMP") or os.getenv("TMPDIR") or "/tmp"
end
local STATE_FILE = utils.join_path(temp_dir(), "kai-discord-presence.json")

local REFRESH_DELAY = 0.5     -- seconds; collapses bursts of events into one update
local TIME_TOLERANCE = 2      -- seconds of timestamp jitter that is not worth an update

-- ---------------------------------------------------------------------------
-- state
-- ---------------------------------------------------------------------------
local web = "unknown"     -- "unknown" (web mod silent) | "active" | "cleared"
local meta = nil          -- table from the web mod
local last = nil          -- last presence table we wrote (nil = nothing shown)
local seq = 0
local helper_running = false
local helper_started_at = -1000

local function dbg(...)
    if opts.debug then msg.info(...) else msg.verbose(...) end
end

-- ---------------------------------------------------------------------------
-- title fallback (only used when the web mod gave no title)
-- ---------------------------------------------------------------------------
local JUNK = {}
for _, w in ipairs({
    "2160p", "1080p", "720p", "480p", "4k", "uhd", "bluray", "blu-ray", "brrip",
    "bdrip", "webrip", "web-dl", "webdl", "hdtv", "dvdrip", "x264", "x265",
    "h264", "h265", "hevc", "remux", "amzn", "hdr", "10bit", "aac", "ddp5",
    "dts", "atmos", "proper", "repack", "extended", "unrated",
}) do JUNK[w] = true end

local VIDEO_EXT = { "mkv", "mp4", "avi", "webm", "mov", "m4v", "wmv", "flv", "ts" }

local function fallback_title()
    local t = mp.get_property("media-title") or mp.get_property("filename") or ""
    if t == "" or t:find("://", 1, true) then return "Stremio" end

    local lower = t:lower()
    for _, ext in ipairs(VIDEO_EXT) do
        if lower:sub(-(#ext + 1)) == "." .. ext then
            t = t:sub(1, #t - #ext - 1)
            break
        end
    end

    t = t:gsub("[%._]", " ")
    local words = {}
    for word in t:gmatch("%S+") do
        local w = word:lower():gsub("[%[%]%(%)]", "")
        local is_year = (#words > 0) and w:match("^%d%d%d%d$") and (tonumber(w) >= 1900 and tonumber(w) <= 2099)
        local is_episode = (#words > 0) and w:match("^s%d%d?e%d%d?")
        if JUNK[w] or is_year or is_episode then break end
        words[#words + 1] = word
    end
    local out = table.concat(words, " ")
    if out == "" then return "Stremio" end
    return out
end

-- ---------------------------------------------------------------------------
-- build what Discord should show
-- ---------------------------------------------------------------------------
local function str(v)
    if type(v) == "string" and v ~= "" then return v end
    return nil
end

local function state_line(paused)
    if paused then return "Paused" end
    local season = meta and tonumber(meta.season)
    local episode = meta and tonumber(meta.episode)
    if meta and meta.type == "series" and season and episode then
        local ep_title = str(meta.episode_title)
        if ep_title then
            return string.format("%s \194\183 S%d E%d", ep_title, season, episode)
        end
        return string.format("Season %d \194\183 Episode %d", season, episode)
    end
    return nil   -- movies: no second line at all
end

local function build()
    if web == "cleared" then return nil end

    local path = mp.get_property("path")
    if not path or path == "" then return nil end
    if mp.get_property_bool("idle-active", false) then return nil end
    if mp.get_property_bool("eof-reached", false) then return nil end

    local paused = mp.get_property_bool("pause", false)
    local title = str(meta and meta.title) or fallback_title()

    local st = {
        active = true,
        paused = paused,
        title  = title,
        state  = state_line(paused),
    }

    if not paused then
        local pos = mp.get_property_number("time-pos")
        local dur = mp.get_property_number("duration")
        if pos and dur and dur > 0 and pos >= 0 and pos <= dur + 1 then
            st.start = os.time() - math.floor(pos)
            st["end"] = st.start + math.floor(dur)
        end
    end

    if opts.show_poster and meta and type(meta.poster) == "string"
       and meta.poster:match("^https?://") then
        st.large_image = meta.poster
    end

    if opts.show_buttons and meta and type(meta.imdb) == "string"
       and meta.imdb:match("^tt%d+$") then
        st.buttons = {
            { label = "View on IMDb", url = "https://www.imdb.com/title/" .. meta.imdb .. "/" },
        }
    end

    return st
end

local function near(a, b)
    if a == nil or b == nil then return a == b end
    return math.abs(a - b) <= TIME_TOLERANCE
end

local function same(a, b)
    if (a == nil) ~= (b == nil) then return false end
    if a == nil then return true end
    for _, k in ipairs({ "active", "paused", "title", "state", "large_image" }) do
        if a[k] ~= b[k] then return false end
    end
    if (a.buttons ~= nil) ~= (b.buttons ~= nil) then return false end
    return near(a.start, b.start) and near(a["end"], b["end"])
end

-- ---------------------------------------------------------------------------
-- talk to the helper
-- ---------------------------------------------------------------------------
local function write_state(st)
    seq = seq + 1
    local out = {}
    if st then for k, v in pairs(st) do out[k] = v end else out.active = false end
    out.seq = seq
    out.written = os.time()
    out.client_id = opts.client_id
    out.status_display_type = opts.status_display_type

    local json, jerr = utils.format_json(out)
    if not json then
        msg.warn("could not encode presence: " .. tostring(jerr))
        return false
    end
    local f, ferr = io.open(STATE_FILE, "wb")
    if not f then
        msg.warn("could not write " .. STATE_FILE .. ": " .. tostring(ferr))
        return false
    end
    f:write(json)
    f:close()
    return true
end

local function ensure_helper()
    if helper_running then return end
    local now = mp.get_time()
    if now - helper_started_at < 10 then return end   -- no restart storms
    helper_started_at = now

    local root = os.getenv("SystemRoot")
    local powershell = root and (root .. "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe")
                       or "powershell.exe"

    helper_running = true
    dbg("starting helper: " .. HELPER_PS1)
    mp.command_native_async({
        name = "subprocess",
        args = {
            powershell, "-NoProfile", "-NonInteractive",
            "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
            "-File", HELPER_PS1,
            "-StateFile", STATE_FILE,
            "-ParentPid", tostring(utils.getpid()),
        },
        playback_only  = false,   -- keep running when playback stops
        capture_stdout = true,
        capture_stderr = true,
    }, function(success, res, err)
        helper_running = false
        local lived = mp.get_time() - helper_started_at
        if not success or (res and res.status ~= 0) then
            msg.warn(string.format(
                "helper exited after %.0fs (status=%s): %s %s",
                lived, tostring(res and res.status), tostring(err or ""),
                tostring((res and (res.stderr or res.stdout)) or "")))
        else
            dbg(string.format("helper exited after %.0fs", lived))
        end
    end)
end

local function refresh()
    local st = build()
    if same(last, st) then return end
    last = st
    dbg("presence -> " .. (st and (st.title .. " | " .. tostring(st.state)) or "(none)"))
    if write_state(st) and st then ensure_helper() end
end

local timer = mp.add_timeout(REFRESH_DELAY, refresh)
timer:kill()
local function schedule()
    timer:kill()
    timer:resume()
end

-- ---------------------------------------------------------------------------
-- hooks
-- ---------------------------------------------------------------------------
mp.register_script_message("presence-meta", function(json)
    local t = utils.parse_json(json or "")
    if type(t) ~= "table" then
        msg.warn("presence-meta: not valid JSON")
        return
    end
    meta = t
    web = "active"
    schedule()
end)

mp.register_script_message("presence-clear", function()
    meta = nil
    web = "cleared"
    schedule()
end)

mp.observe_property("pause", "bool", schedule)
mp.observe_property("paused-for-cache", "bool", schedule)   -- re-sync the time bar after buffering
mp.observe_property("duration", "number", schedule)
mp.observe_property("eof-reached", "bool", schedule)
mp.register_event("file-loaded", schedule)
mp.register_event("playback-restart", schedule)             -- after a seek
mp.register_event("end-file", schedule)

mp.register_event("shutdown", function()
    write_state(nil)
end)

-- Restart the helper if it died while something is still being shown.
mp.add_periodic_timer(30, function()
    if last and last.active then ensure_helper() end
end)

msg.info("ready (script name: " .. mp.get_script_name() .. ")")
