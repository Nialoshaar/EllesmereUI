--------------------------------------------------------------------------------
--  EllesmereUI_LocaleDev.lua
--  In-game translation harvester (/euiloc). Ships with the addon but is fully
--  inert during normal play: it does nothing until a developer runs /euiloc.
--
--  Purpose: capture the complete set of English strings that flow through the
--  localization engine (EllesmereUI.L) so a translator never has to hunt for
--  keys. Because every visible options/unlock/popup string is wrapped in L(),
--  navigating the panels with recording on captures the full key set.
--
--  Workflow:
--    /reload
--    /euiloc on              -- start recording (do this BEFORE opening options)
--    ... open every options page, cog popup, and tooltip you want covered ...
--    /euiloc dump deDE       -- write a paste-ready L["..."] = "" block to SV
--    /euiloc off             -- stop recording
--  The block is written to EllesmereUIDB._localeDump (read it from
--  WTF\Account\<acct>\SavedVariables\EllesmereUI.lua after a /reload or logout).
--------------------------------------------------------------------------------
local EllesmereUI = _G.EllesmereUI
if not EllesmereUI then return end

local recording = false
local origL, origLf = nil, nil
local seen = {}        -- set of English keys observed while recording

local function StartRec()
    if recording then
        EllesmereUI.Print("|cff0cd29fEUILoc|r: already recording.")
        return
    end
    origL  = EllesmereUI.L
    origLf = EllesmereUI.Lf
    EllesmereUI.L = function(s)
        if type(s) == "string" and s ~= "" then seen[s] = true end
        return origL(s)
    end
    -- Lf templates (e.g. "Reset %1$s") never reach the wrapped L directly, so
    -- record the template string here too.
    EllesmereUI.Lf = function(s, ...)
        if type(s) == "string" and s ~= "" then seen[s] = true end
        return origLf(s, ...)
    end
    recording = true
    EllesmereUI.Print("|cff0cd29fEUILoc|r: recording ON. Open every options page, cog and tooltip, then /euiloc dump <code>.")
end

local function StopRec()
    if not recording then return end
    if origL  then EllesmereUI.L  = origL  end
    if origLf then EllesmereUI.Lf = origLf end
    origL, origLf = nil, nil
    recording = false
    EllesmereUI.Print("|cff0cd29fEUILoc|r: recording OFF.")
end

local function CountSeen()
    local n = 0
    for _ in pairs(seen) do n = n + 1 end
    return n
end

local function Dump(code)
    code = code or "xxXX"
    local keys = {}
    for k in pairs(seen) do keys[#keys + 1] = k end
    table.sort(keys)
    local lines = {}
    lines[#lines + 1] = "-- " .. code .. " key dump from /euiloc (" .. #keys .. " keys). Fill in the right side."
    lines[#lines + 1] = 'local L = EllesmereUI.RegisterLocale("' .. code .. '")'
    lines[#lines + 1] = "if not L then return end"
    lines[#lines + 1] = ""
    for _, k in ipairs(keys) do
        -- %q produces a safely-escaped Lua string literal for the key.
        lines[#lines + 1] = string.format("L[%q] = %q", k, "")
    end
    local blob = table.concat(lines, "\n")
    if not EllesmereUIDB then EllesmereUIDB = {} end
    EllesmereUIDB._localeDump = blob
    EllesmereUI.Print("|cff0cd29fEUILoc|r: wrote " .. #keys .. " keys to EllesmereUIDB._localeDump (in SavedVariables\\EllesmereUI.lua after /reload or logout).")
end

local function Help()
    EllesmereUI.Print("|cff0cd29fEUILoc|r translation harvester:")
    EllesmereUI.Print("  /euiloc on            - start recording strings")
    EllesmereUI.Print("  /euiloc off           - stop recording")
    EllesmereUI.Print("  /euiloc dump <code>   - write seen keys to EllesmereUIDB._localeDump")
    EllesmereUI.Print("  /euiloc clear         - clear the recorded set")
    EllesmereUI.Print("  status: " .. (recording and "recording" or "idle") .. ", " .. CountSeen() .. " keys seen")
end

SLASH_EUILOC1 = "/euiloc"
SlashCmdList["EUILOC"] = function(msg)
    -- Trim only; do NOT lowercase -- the locale code arg is case-sensitive (deDE).
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local cmd, arg = msg:match("^(%S+)%s*(.-)$")
    cmd = cmd and cmd:lower() or ""
    if cmd == "on" then
        StartRec()
    elseif cmd == "off" then
        StopRec()
    elseif cmd == "dump" then
        Dump(arg ~= "" and arg or nil)
    elseif cmd == "clear" then
        seen = {}
        EllesmereUI.Print("|cff0cd29fEUILoc|r: cleared.")
    else
        Help()
    end
end
