--!nonstrict
-- Arch Packages — Launcher Provider (/pkg <query>)

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

local function extractErrorMessage(stdout, stderr)
  local full = (stderr or "") .. "\n" .. (stdout or "")
  local lines = {}
  for line in full:gmatch("[^\r\n]+") do
    table.insert(lines, line)
  end

  for _, line in ipairs(lines) do
    local l = line:match("^%s*(.-)%s*$")
    if l:find("in conflict") then
      local clean = l:gsub("^::%s*", "")
      return clean .. " (Switch to Terminal mode to confirm replacement)"
    end
  end

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
  return low:find("cancel") ~= nil or low:find("dismiss") ~= nil or low:find("not authorized") ~= nil or low:find("interrupted") ~= nil
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

function onQuery(query)
  local text = query:gsub("^%s+", ""):gsub("%s+$", "")

  if text == "" then
    local rows = {
      {
        id = "action:open_hub",
        title = "Open Arch Packages Hub",
        subtitle = "Browse, search, manage installed packages, and clean orphans",
        glyph = "package",
      },
      {
        id = "action:update_system",
        title = "Full System Upgrade",
        subtitle = "Upgrade all official and AUR packages",
        glyph = "refresh",
      },
      {
        id = "action:clean_orphans",
        title = "Clean Orphan Packages",
        subtitle = "Remove unused dependencies to free disk space",
        glyph = "trash",
      },
    }
    launcher.setResults(query, rows)
    return
  end

  local helper = getHelper()
  local cmd
  if helper == "pacman" then
    cmd = "pacman -Ss " .. shellQuote(text)
  else
    cmd = helper .. " -Ss --topdown " .. shellQuote(text)
  end

  noctalia.runAsync(cmd, function(result)
    local rows = {}
    local lowText = text:lower()

    if lowText == "update" or lowText == "upgrade" then
      table.insert(rows, {
        id = "action:update_system",
        title = "Full System Upgrade",
        subtitle = "Upgrade all official and AUR packages",
        glyph = "refresh",
      })
    elseif lowText == "clean" or lowText == "orphan" or lowText == "orphans" then
      table.insert(rows, {
        id = "action:clean_orphans",
        title = "Clean Orphan Packages",
        subtitle = "Remove unused dependencies to free disk space",
        glyph = "trash",
      })
    end

    if result and result.exitCode == 0 and result.stdout then
      local lines = {}
      for line in result.stdout:gmatch("[^\r\n]+") do
        table.insert(lines, line)
      end

      local i = 1
      while i <= #lines and #rows < 15 do
        local header = lines[i]
        i = i + 1
        local desc = ""
        while i <= #lines and lines[i]:match("^%s%s%s%s") do
          local dline = lines[i]:match("^%s*(.-)%s*$")
          desc = (desc == "") and dline or (desc .. " " .. dline)
          i = i + 1
        end

        local parts = {}
        for part in header:gmatch("%S+") do
          table.insert(parts, part)
        end

        if #parts >= 1 then
          local repo = "extra"
          local name = parts[1]
          local slashPos = parts[1]:find("/")
          if slashPos then
            repo = parts[1]:sub(1, slashPos - 1)
            name = parts[1]:sub(slashPos + 1)
          end
          local ver = parts[2] or ""
          local isInst = (header:lower():find("installed") ~= nil)

          local votes = header:match("%(%+(%d+)")
          local isOrphaned = header:find("%(Orphaned%)") ~= nil
          local prefixTag = isInst and "[Installed] " or ""
          local repoTag = "[" .. repo:upper() .. "]"
          if repo == "aur" then
            if isOrphaned then
              repoTag = "[AUR · ⚠️ Orphaned]"
            elseif votes then
              local vn = tonumber(votes) or 0
              if vn == 0 then
                repoTag = "[AUR · ⚠️ 0 votes]"
              else
                repoTag = "[AUR · 👍 " .. votes .. " votes]"
              end
            end
          else
            repoTag = "[" .. repo:upper() .. " · Verified]"
          end

          local subtitle = prefixTag .. repoTag .. " " .. desc

          table.insert(rows, {
            id = isInst and ("remove:" .. name) or ("install:" .. name),
            title = name .. " " .. ver,
            subtitle = subtitle,
            glyph = isInst and "circle-check" or "download",
          })
        end
      end
    end

    if #rows == 0 then
      table.insert(rows, {
        id = "noop",
        title = "No packages found",
        subtitle = "No results found matching '" .. text .. "'",
        glyph = "package-off",
      })
    end

    launcher.setResults(query, rows)
  end, 4000)
end

function onActivate(id)
  if id == "action:open_hub" then
    noctalia.runAsync("noctalia msg panel-open ashur-d/arch-packages:hub")
    return
  end

  local useTerminal = (noctalia.getConfig("use_terminal") == true)
  local helper = getHelper()

  if id == "action:update_system" then
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
  elseif id == "action:clean_orphans" then
    if useTerminal then
      runTerminal("ORPHANS=$(pacman -Qtdq); if [ -n \"$ORPHANS\" ]; then sudo pacman -Rns $ORPHANS; else echo 'No orphan packages found.'; fi")
    else
      if noctalia.getConfig("notify_on_action") ~= false then
        noctalia.notify("Arch Packages", tr("notify.cleaning_orphans"))
      end
      noctalia.runAsync("pacman -Qtdq 2>/dev/null", function(orpRes)
        local orphans = (orpRes and orpRes.stdout or ""):match("^%s*(.-)%s*$")
        if not orphans or orphans == "" then
          if noctalia.getConfig("notify_on_action") ~= false then
            noctalia.notify("Arch Packages", "No orphan packages found")
          end
          return
        end
        local cmd = "pkexec pacman -Rns --noconfirm " .. orphans:gsub("[\r\n]+", " ")
        noctalia.runAsync(cmd, function(result)
          if result and result.exitCode == 0 then
            if noctalia.getConfig("notify_on_action") ~= false then
              noctalia.notify("Arch Packages", tr("notify.cleaned_orphans"))
            end
          else
            local err = extractErrorMessage(result and result.stdout, result and result.stderr)
            if not isCanceledError(err) then
              noctalia.notify("Arch Packages", "Failed to clean orphans: " .. err)
            else
              if noctalia.getConfig("notify_on_action") ~= false then
                noctalia.notify("Arch Packages", "Clean orphans canceled")
              end
            end
          end
        end, 60000)
      end)
    end
  elseif id:sub(1, 8) == "install:" then
    local name = id:sub(9)
    if useTerminal then
      local cmd = (helper == "pacman") and ("sudo pacman -S --needed " .. shellQuote(name)) or (helper .. " -S --needed " .. shellQuote(name))
      runTerminal(cmd)
    else
      if noctalia.getConfig("notify_on_action") ~= false then
        noctalia.notify("Arch Packages", tr("notify.installing", { name = name }))
      end
      noctalia.runAsync("pacman -Si " .. shellQuote(name) .. " >/dev/null 2>&1", function(siRes)
        local isOfficial = (siRes and siRes.exitCode == 0)
        local cmd
        if helper == "pacman" or isOfficial then
          cmd = "pkexec pacman -S --needed --noconfirm " .. shellQuote(name)
        elseif helper == "paru" then
          cmd = "paru -S --needed --noconfirm --skipreview " .. shellQuote(name)
        else
          cmd = "yay -S --needed --noconfirm --sudo pkexec --answerclean None --answerdiff None --answeredit None " .. shellQuote(name)
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
  elseif id:sub(1, 7) == "remove:" then
    local name = id:sub(8)
    if useTerminal then
      local cmd = (helper == "pacman") and ("sudo pacman -Rns " .. shellQuote(name)) or (helper .. " -Rns " .. shellQuote(name))
      runTerminal(cmd)
    else
      if noctalia.getConfig("notify_on_action") ~= false then
        noctalia.notify("Arch Packages", tr("notify.removing", { name = name }))
      end
      local cmd = "pkexec pacman -Rns --noconfirm " .. shellQuote(name)
      noctalia.runAsync(cmd, function(result)
        if result and result.exitCode == 0 then
          if noctalia.getConfig("notify_on_action") ~= false then
            noctalia.notify("Arch Packages", tr("notify.removed", { name = name }))
          end
        else
          local err = extractErrorMessage(result and result.stdout, result and result.stderr)
          if not isCanceledError(err) then
            noctalia.notify("Arch Packages", tr("notify.remove_failed", { name = name }) .. ": " .. err)
          else
            if noctalia.getConfig("notify_on_action") ~= false then
              noctalia.notify("Arch Packages", "Removal canceled")
            end
          end
        end
      end, 60000)
    end
  end
end
