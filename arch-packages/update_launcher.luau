--!nonstrict
-- Arch Packages — Updates Launcher Provider (/update)

local function tr(key, args)
  return noctalia.tr(key, args)
end

local function shellQuote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function getHelper()
  local configured = noctalia.getConfig("aur_helper")
  if configured and configured ~= "auto" then
    return configured
  end
  if noctalia.commandExists("yay") then
    return "yay"
  elseif noctalia.commandExists("paru") then
    return "paru"
  else
    return "pacman"
  end
end

local function runTerminal(cmd)
  local termOverride = noctalia.getConfig("terminal_cmd")
  local fullCmd = cmd .. "; echo; printf 'Press Enter to close... '; read _"

  if type(termOverride) == "string" and termOverride ~= "" then
    noctalia.runAsync(termOverride .. " " .. shellQuote(fullCmd))
  else
    noctalia.runInTerminal(fullCmd)
  end
end

local function extractErrorMessage(stdout, stderr)
  local full = (stderr or "") .. "\n" .. (stdout or "")
  local lines = {}
  for line in full:gmatch("[^\r\n]+") do
    table.insert(lines, line)
  end

  -- 1. Check for package conflicts (e.g. :: umbriel and umbriel-git are in conflict)
  for _, line in ipairs(lines) do
    local l = line:match("^%s*(.-)%s*$")
    if l:find("in conflict") then
      local clean = l:gsub("^::%s*", "")
      return clean .. " (Switch to Terminal mode to confirm replacement)"
    end
  end

  -- 2. Explicit pacman or makepkg error
  local errorLines = {}
  for _, line in ipairs(lines) do
    local l = line:match("^%s*(.-)%s*$")
    if l ~= "" 
       and not l:match("^==>%s*WARNING") 
       and not l:match("^WARNING:") 
       and not l:match("^==== AUTHENTICATING") 
       and not l:match("^Password:") 
       and not l:match("^Authentication is needed") 
       and not l:match("^Authenticating as:") then
      if l:match("^==>%s*ERROR:") or l:match("^error:") then
        table.insert(errorLines, l:gsub("^==>%s*ERROR:%s*", ""):gsub("^error:%s*", ""))
      end
    end
  end
  if #errorLines > 0 then
    local err = errorLines[#errorLines]
    return (#err > 110) and (err:sub(1, 107) .. "...") or err
  end

  -- 3. Last non-noise line
  for i = #lines, 1, -1 do
    local l = lines[i]:match("^%s*(.-)%s*$")
    if l ~= "" 
       and not l:match("^==>%s*WARNING") 
       and not l:match("^WARNING:") 
       and not l:match("^==== AUTHENTICATING") 
       and not l:match("^Password:") 
       and not l:match("^Authentication is needed") 
       and not l:match("^Authenticating as:") 
       and not l:match("^->%s*exit status") then
      return (#l > 110) and (l:sub(1, 107) .. "...") or l
    end
  end

  return "Operation failed or canceled"
end

local function isCanceledError(err)
  local low = err:lower()
  return low:find("cancel") ~= nil or low:find("dismiss") ~= nil or low:find("not authorized") ~= nil
end

function onQuery(query)
  local text = query:gsub("^%s+", ""):gsub("%s+$", ""):lower()
  local helper = getHelper()

  local defaultRows = {
    {
      id = "action:system_upgrade",
      title = "Full System Upgrade",
      subtitle = "Upgrade all official and AUR packages now",
      glyph = "refresh",
    },
    {
      id = "action:open_updates_hub",
      title = "Open Arch Packages Updates",
      subtitle = "Review and selectively manage pending package updates",
      glyph = "package",
    },
  }

  -- Return initial default actions immediately so the launcher is instant
  launcher.setResults(query, defaultRows)

  local cmd
  if helper == "paru" then
    cmd = "paru -Qu --color=never 2>/dev/null || pacman -Qu --color=never 2>/dev/null || true"
  elseif helper == "yay" then
    cmd = "yay -Qu --color=never 2>/dev/null || pacman -Qu --color=never 2>/dev/null || true"
  else
    cmd = "pacman -Qu --color=never 2>/dev/null || true"
  end

  noctalia.runAsync(cmd, function(result)
    local rows = {
      {
        id = "action:system_upgrade",
        title = "Full System Upgrade",
        subtitle = "Upgrade all official and AUR packages now",
        glyph = "refresh",
      },
      {
        id = "action:open_updates_hub",
        title = "Open Arch Packages Updates",
        subtitle = "Review and selectively manage pending package updates",
        glyph = "package",
      },
    }

    if result and result.stdout then
      local lines = {}
      for line in result.stdout:gmatch("[^\r\n]+") do
        table.insert(lines, line)
      end

      for _, line in ipairs(lines) do
        local name, oldVer, newVer = line:match("^(%S+)%s+(%S+)%s+%->%s+(%S+)")
        if name and newVer then
          if text == "" or name:lower():find(text, 1, true) then
            table.insert(rows, {
              id = "upgrade_pkg:" .. name,
              title = "Update " .. name,
              subtitle = oldVer .. " → " .. newVer,
              glyph = "arrow-up-circle",
            })
          end
        end
      end
    end

    launcher.setResults(query, rows)
  end, 6000)
end

function onActivate(id)
  if id == "action:open_updates_hub" then
    noctalia.runAsync("noctalia msg panel-open ashur-d/arch-packages:hub updates")
    return
  end

  local useTerminal = noctalia.getConfig("use_terminal") == true
  local helper = getHelper()

  if id == "action:system_upgrade" then
    if useTerminal then
      local cmd = (helper == "pacman") and "sudo pacman -Syu" or (helper .. " -Syu")
      runTerminal(cmd)
    else
      local cmd
      if helper == "pacman" then
        cmd = "pkexec pacman -Syu --noconfirm"
      elseif helper == "paru" then
        cmd = "paru -Syu --noconfirm --skipreview"
      else
        cmd = "yay -Syu --noconfirm --sudo pkexec --answerclean None --answerdiff None --answeredit None --answerupgrade None"
      end
      if noctalia.getConfig("notify_on_action") ~= false then
        noctalia.notify("Arch Packages", tr("notify.upgrading"))
      end
      noctalia.runAsync(cmd, function(result)
        if result and result.exitCode == 0 then
          if noctalia.getConfig("notify_on_action") ~= false then
            noctalia.notify("Arch Packages", tr("notify.upgraded"))
          end
        else
          local err = extractErrorMessage(result and result.stdout, result and result.stderr)
          if not isCanceledError(err) then
            noctalia.notify("Arch Packages", tr("notify.upgrade_failed") .. ": " .. err)
          else
            if noctalia.getConfig("notify_on_action") ~= false then
              noctalia.notify("Arch Packages", "Upgrade canceled")
            end
          end
        end
      end, 600000)
    end
  elseif id:sub(1, 12) == "upgrade_pkg:" then
    local name = id:sub(13)
    if useTerminal then
      local cmd = (helper == "pacman") and ("sudo pacman -S " .. shellQuote(name)) or (helper .. " -S " .. shellQuote(name))
      runTerminal(cmd)
    else
      if noctalia.getConfig("notify_on_action") ~= false then
        noctalia.notify("Arch Packages", tr("notify.installing", { name = name }))
      end
      noctalia.runAsync("pacman -Si " .. shellQuote(name) .. " >/dev/null 2>&1", function(siRes)
        local isOfficial = (siRes and siRes.exitCode == 0)
        local cmd
        if helper == "pacman" or isOfficial then
          cmd = "pkexec pacman -S --noconfirm " .. shellQuote(name)
        elseif helper == "paru" then
          cmd = "paru -S --noconfirm --skipreview " .. shellQuote(name)
        else
          cmd = "yay -S --noconfirm --sudo pkexec --answerclean None --answerdiff None --answeredit None " .. shellQuote(name)
        end
        noctalia.runAsync(cmd, function(result)
          if result and result.exitCode == 0 then
            if noctalia.getConfig("notify_on_action") ~= false then
              noctalia.notify("Arch Packages", tr("notify.installed", { name = name }))
            end
          else
            local err = extractErrorMessage(result and result.stdout, result and result.stderr)
            if not isCanceledError(err) then
              noctalia.notify("Arch Packages", tr("notify.install_failed", { name = name }) .. ": " .. err)
            else
              if noctalia.getConfig("notify_on_action") ~= false then
                noctalia.notify("Arch Packages", "Installation canceled")
              end
            end
          end
        end, 300000)
      end)
    end
  end
end
