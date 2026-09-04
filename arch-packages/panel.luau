--!nonstrict
-- Arch Packages — Native Arch Linux & AUR Package Manager, Installer & Remover

local currentTab = "explore" -- "explore", "installed", "updates", "orphans"
local searchQuery = ""
local searchRevision = 0

local installedPackages = {}
local installedMap = {}
local foreignMap = {}
local orphanPackages = {}
local updatePackages = {}
local searchResults = {}

local sessionUseTerminal = nil
local searchRateLimited = false

local isSearching = false
local isLoadingInstalled = false
local isLoadingOrphans = false
local isLoadingUpdates = false

local isOperating = false
local operatingMsg = ""

local confirmingRemovalPkg = nil
local confirmingCleanOrphans = false

local selectedPkg = nil
local pkgDetails = nil
local isLoadingDetails = false

local function tr(key, args)
  return noctalia.tr(key, args)
end

local function shellQuote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function getEffectiveUseTerminal()
  if sessionUseTerminal ~= nil then
    return sessionUseTerminal
  end
  return (noctalia.getConfig("use_terminal") == true)
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

local function filterNodes(nodes)
  local clean = {}
  for _, n in ipairs(nodes) do
    if type(n) == "table" and n.type ~= nil then
      table.insert(clean, n)
    end
  end
  return clean
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

local render -- forward declaration

local function runTerminal(cmd, notifyMsg)
  local termOverride = noctalia.getConfig("terminal_cmd")
  local fullCmd = cmd .. "; echo; printf 'Press Enter to close... '; read _"

  if type(termOverride) == "string" and termOverride ~= "" then
    noctalia.runAsync(termOverride .. " " .. shellQuote(fullCmd))
  else
    noctalia.runInTerminal(fullCmd)
  end

  if notifyMsg and noctalia.getConfig("notify_on_action") ~= false then
    noctalia.notify("Arch Packages", notifyMsg)
  end
end

local function cancelOperation()
  if not isOperating then return end
  isOperating = false
  operatingMsg = ""
  noctalia.runAsync("killall -INT pacman yay paru pkexec 2>/dev/null; sleep 0.3; killall pkexec 2>/dev/null || true")
  if noctalia.getConfig("notify_on_action") ~= false then
    noctalia.notify("Arch Packages", "Operation canceled")
  end
  render()
end

local function installPackage(name, isReinstall, repo)
  local useTerminal = getEffectiveUseTerminal()
  local helper = getHelper()

  if useTerminal then
    local cmd
    if helper == "pacman" then
      cmd = (isReinstall and "sudo pacman -S " or "sudo pacman -S --needed ") .. shellQuote(name)
    else
      cmd = helper .. (isReinstall and " -S " or " -S --needed ") .. shellQuote(name)
    end
    runTerminal(cmd, tr("notify.installing", { name = name }))
    return
  end

  -- Background installation via Polkit
  isOperating = true
  operatingMsg = tr("notify.installing", { name = name })
  render()

  local isAur = (repo == "aur") or (foreignMap[name] == true)
  if not isAur and selectedPkg and selectedPkg.name == name and selectedPkg.repo == "aur" then
    isAur = true
  end

  local cmd
  if helper == "pacman" or not isAur then
    cmd = (isReinstall and "pkexec pacman -S --noconfirm " or "pkexec pacman -S --needed --noconfirm ") .. shellQuote(name)
  elseif helper == "paru" then
    cmd = helper .. (isReinstall and " -S --noconfirm --skipreview " or " -S --needed --noconfirm --skipreview ") .. shellQuote(name)
  else
    cmd = helper .. (isReinstall and " -S --noconfirm --sudo pkexec --answerclean None --answerdiff None --answeredit None " or " -S --needed --noconfirm --sudo pkexec --answerclean None --answerdiff None --answeredit None ") .. shellQuote(name)
  end

  noctalia.runAsync(cmd, function(result)
    if not isOperating then return end
    isOperating = false
    operatingMsg = ""
    if result and result.exitCode == 0 then
      if noctalia.getConfig("notify_on_action") ~= false then
        noctalia.notify("Arch Packages", tr("notify.installed", { name = name }))
      end
      loadInstalledPackages(function()
        loadUpdates()
        loadOrphans()
      end)
    else
      local err = extractErrorMessage(result and result.stdout, result and result.stderr)
      if not isCanceledError(err) then
        noctalia.notify("Arch Packages", tr("notify.install_failed", { name = name }) .. ": " .. err)
      else
        if noctalia.getConfig("notify_on_action") ~= false then
          noctalia.notify("Arch Packages", "Installation canceled")
        end
      end
      render()
    end
  end, 300000)
end

local function reinstallPackage(name)
  installPackage(name, true, selectedPkg and selectedPkg.repo)
end

local function executeRemoval(name)
  local useTerminal = getEffectiveUseTerminal()
  if useTerminal then
    local helper = getHelper()
    local cmd = (helper == "pacman") and ("sudo pacman -Rns " .. shellQuote(name)) or (helper .. " -Rns " .. shellQuote(name))
    runTerminal(cmd, tr("notify.removing", { name = name }))
    return
  end

  -- Background removal via Polkit
  isOperating = true
  operatingMsg = tr("notify.removing", { name = name })
  render()

  local cmd = "pkexec pacman -Rns --noconfirm " .. shellQuote(name)
  noctalia.runAsync(cmd, function(result)
    if not isOperating then return end
    isOperating = false
    operatingMsg = ""
    if result and result.exitCode == 0 then
      if noctalia.getConfig("notify_on_action") ~= false then
        noctalia.notify("Arch Packages", tr("notify.removed", { name = name }))
      end
      if selectedPkg and selectedPkg.name == name then
        selectedPkg = nil
        pkgDetails = nil
      end
      loadInstalledPackages(function()
        loadUpdates()
        loadOrphans()
      end)
    else
      local err = extractErrorMessage(result and result.stdout, result and result.stderr)
      if not isCanceledError(err) then
        noctalia.notify("Arch Packages", tr("notify.remove_failed", { name = name }) .. ": " .. err)
      else
        if noctalia.getConfig("notify_on_action") ~= false then
          noctalia.notify("Arch Packages", "Removal canceled")
        end
      end
      render()
    end
  end, 60000)
end

local function executeCleanOrphans()
  if #orphanPackages == 0 then
    if noctalia.getConfig("notify_on_action") ~= false then
      noctalia.notify("Arch Packages", tr("panel.status.no_orphans"))
    end
    return
  end

  local names = {}
  for _, p in ipairs(orphanPackages) do
    table.insert(names, shellQuote(p.name))
  end
  local pkgs = table.concat(names, " ")

  local useTerminal = getEffectiveUseTerminal()
  if useTerminal then
    runTerminal("sudo pacman -Rns " .. pkgs, tr("notify.cleaning_orphans"))
    return
  end

  -- Background orphan clean via Polkit
  isOperating = true
  operatingMsg = tr("notify.cleaning_orphans")
  render()

  local cmd = "pkexec pacman -Rns --noconfirm " .. pkgs
  noctalia.runAsync(cmd, function(result)
    if not isOperating then return end
    isOperating = false
    operatingMsg = ""
    if result and result.exitCode == 0 then
      if noctalia.getConfig("notify_on_action") ~= false then
        noctalia.notify("Arch Packages", tr("notify.cleaned_orphans"))
      end
      loadInstalledPackages(function()
        loadUpdates()
        loadOrphans()
      end)
    else
      local err = extractErrorMessage(result and result.stdout, result and result.stderr)
      if not isCanceledError(err) then
        noctalia.notify("Arch Packages", "Failed to clean orphans: " .. err)
      else
        if noctalia.getConfig("notify_on_action") ~= false then
          noctalia.notify("Arch Packages", "Clean orphans canceled")
        end
      end
      render()
    end
  end, 60000)
end

local function loadInstalledPackages(callback)
  isLoadingInstalled = true
  render()
  noctalia.runAsync("pacman -Qe && echo '---FOREIGN---' && (pacman -Qm || true)", function(result)
    isLoadingInstalled = false
    local list = {}
    local map = {}
    local fMap = {}

    if result and result.exitCode == 0 and result.stdout then
      local isForeignSection = false
      for line in result.stdout:gmatch("[^\r\n]+") do
        if line:find("---FOREIGN---") then
          isForeignSection = true
        elseif isForeignSection then
          local name = line:match("^(%S+)")
          if name then
            fMap[name] = true
          end
        else
          local name, ver = line:match("^(%S+)%s*(%S*)$")
          if name then
            table.insert(list, {
              name = name,
              version = ver or "",
              installed = true,
              desc = "",
              repo = "extra",
            })
            map[name] = true
          end
        end
      end

      for _, p in ipairs(list) do
        if fMap[p.name] then
          p.repo = "aur"
        else
          p.repo = "extra"
          p.isOfficial = true
        end
      end
    end

    foreignMap = fMap
    installedPackages = list
    installedMap = map
    if callback then callback() end
    render()
  end, 4000)
end

local function loadOrphans(callback)
  isLoadingOrphans = true
  render()
  noctalia.runAsync("pacman -Qtd 2>/dev/null || true", function(result)
    isLoadingOrphans = false
    local list = {}

    if result and result.stdout then
      for line in result.stdout:gmatch("[^\r\n]+") do
        local name, ver = line:match("^(%S+)%s*(%S*)$")
        if name then
          table.insert(list, {
            name = name,
            version = ver or "",
            installed = true,
            desc = "",
            repo = "orphan",
          })
        end
      end
    end

    orphanPackages = list
    if callback then callback() end
    render()
  end, 4000)
end

local function executeSystemUpgrade()
  local useTerminal = getEffectiveUseTerminal()
  local helper = getHelper()

  if useTerminal then
    local cmd = (helper == "pacman") and "sudo pacman -Syu" or (helper .. " -Syu")
    runTerminal(cmd, tr("notify.upgrading"))
    return
  end

  -- Background system upgrade via Polkit
  isOperating = true
  operatingMsg = tr("notify.upgrading")
  render()

  local cmd
  if helper == "pacman" then
    cmd = "pkexec pacman -Syu --noconfirm"
  elseif helper == "paru" then
    cmd = "paru -Syu --noconfirm --skipreview"
  else
    cmd = "yay -Syu --noconfirm --sudo pkexec --answerclean None --answerdiff None --answeredit None --answerupgrade None"
  end

  noctalia.runAsync(cmd, function(result)
    if not isOperating then return end
    isOperating = false
    operatingMsg = ""
    if result and result.exitCode == 0 then
      if noctalia.getConfig("notify_on_action") ~= false then
        noctalia.notify("Arch Packages", tr("notify.upgraded"))
      end
      loadInstalledPackages(function()
        loadUpdates()
        loadOrphans()
      end)
    else
      local err = extractErrorMessage(result and result.stdout, result and result.stderr)
      if not isCanceledError(err) then
        noctalia.notify("Arch Packages", tr("notify.upgrade_failed") .. ": " .. err)
      else
        if noctalia.getConfig("notify_on_action") ~= false then
          noctalia.notify("Arch Packages", "System upgrade canceled")
        end
      end
      render()
    end
  end, 600000)
end

local function loadUpdates(callback)
  isLoadingUpdates = true
  render()
  local helper = getHelper()
  local cmd
  if helper == "pacman" then
    cmd = "pacman -Qu --color=never 2>/dev/null || true"
  else
    cmd = helper .. " -Qu --color=never 2>/dev/null || pacman -Qu --color=never 2>/dev/null || true"
  end

  noctalia.runAsync(cmd, function(result)
    isLoadingUpdates = false
    local list = {}

    if result and result.stdout then
      for line in result.stdout:gmatch("[^\r\n]+") do
        local name, oldVer, newVer = line:match("^(%S+)%s+(%S+)%s+%->%s+(%S+)")
        if name and newVer then
          local isAur = (foreignMap[name] == true)
          table.insert(list, {
            name = name,
            oldVersion = oldVer,
            version = newVer,
            repo = isAur and "aur" or "extra",
            installed = true,
            isUpdate = true,
            desc = isAur and "AUR package update available" or "Official repository update available",
          })
        end
      end
    end

    updatePackages = list
    if callback then callback() end
    render()
  end, 8000)
end

local function loadPackageDetails(pkg)
  selectedPkg = pkg
  isLoadingDetails = true
  pkgDetails = nil
  confirmingRemovalPkg = nil
  confirmingCleanOrphans = false
  render()

  local helper = getHelper()
  local cmd
  if pkg.installed then
    cmd = "pacman -Qi " .. shellQuote(pkg.name)
    if helper ~= "pacman" and pkg.repo == "aur" then
      cmd = cmd .. " && (" .. helper .. " -Si " .. shellQuote(pkg.name) .. " 2>/dev/null || true)"
    end
  else
    if helper == "pacman" then
      cmd = "pacman -Si " .. shellQuote(pkg.name)
    else
      cmd = helper .. " -Si " .. shellQuote(pkg.name) .. " 2>/dev/null || pacman -Si " .. shellQuote(pkg.name)
    end
  end

  noctalia.runAsync(cmd, function(result)
    isLoadingDetails = false
    local details = {
      name = pkg.name,
      version = pkg.version or "",
      desc = pkg.desc or "",
      size = "",
      url = "",
      licenses = "",
      depends = "",
      repo = pkg.repo or "extra",
      installed = pkg.installed or false,
      votes = pkg.votes,
      popularity = pkg.popularity,
      isOrphaned = pkg.isOrphaned,
      isOutOfDate = pkg.isOutOfDate,
      maintainer = "",
      packager = "",
      validatedBy = "",
      aurUrl = (pkg.repo == "aur") and ("https://aur.archlinux.org/packages/" .. pkg.name) or "",
    }

    if result and result.exitCode == 0 and result.stdout then
      local lastKey = nil
      for line in result.stdout:gmatch("[^\r\n]+") do
        local k, v = line:match("^([^:]+):%s*(.*)$")
        if k and v then
          k = k:match("^%s*(.-)%s*$")
          v = v:match("^%s*(.-)%s*$")
          lastKey = k
          if k == "Description" and details.desc == "" then
            details.desc = v
          elseif k == "Installed Size" or k == "Download Size" then
            details.size = v
          elseif k == "URL" then
            details.url = v
          elseif k == "Licenses" then
            details.licenses = v
          elseif k == "Depends On" then
            details.depends = v
          elseif k == "Repository" then
            details.repo = v
          elseif k == "Version" and details.version == "" then
            details.version = v
          elseif k == "Votes" then
            local vn = tonumber(v)
            if vn then details.votes = vn end
          elseif k == "Popularity" then
            details.popularity = v
          elseif k == "Maintainer" then
            details.maintainer = v
          elseif k == "Packager" then
            details.packager = v
          elseif k == "Validated By" then
            details.validatedBy = v
          elseif k == "AUR URL" then
            details.aurUrl = v
          elseif k == "Out-of-date" then
            details.isOutOfDate = (v:lower():find("yes") ~= nil)
          end
        elseif lastKey == "Depends On" and details.depends ~= "" then
          local cont = line:match("^%s*(.-)%s*$")
          if cont and cont ~= "" then
            details.depends = details.depends .. "  " .. cont
          end
        end
      end
    end

    if details.votes == nil and pkg.votes ~= nil then
      details.votes = pkg.votes
      details.popularity = pkg.popularity
    end
    if details.repo == "aur" and (details.aurUrl == nil or details.aurUrl == "") then
      details.aurUrl = "https://aur.archlinux.org/packages/" .. details.name
    end

    pkgDetails = details
    render()
  end, 5000)
end

local function performSearch(query, immediate)
  if not query or #query < 2 then
    searchResults = {}
    isSearching = false
    searchRateLimited = false
    render()
    return
  end

  searchRevision = searchRevision + 1
  local myRev = searchRevision
  isSearching = true
  searchRateLimited = false
  render()

  local function doSearch()
    if myRev ~= searchRevision then return end
    local helper = getHelper()
    local cmd
    if helper == "pacman" then
      cmd = "pacman -Ss " .. shellQuote(query)
    else
      cmd = helper .. " -Ss --topdown " .. shellQuote(query)
    end

    noctalia.runAsync(cmd, function(result)
      if myRev ~= searchRevision then return end
      isSearching = false

      local outText = (result and result.stdout or "") .. "\n" .. (result and result.stderr or "")
      if outText:find("Rate limit reached") or outText:find("status 429") then
        searchRateLimited = true
      end

    local list = {}
    if result and result.exitCode == 0 and result.stdout then
      local lines = {}
      for line in result.stdout:gmatch("[^\r\n]+") do
        table.insert(lines, line)
      end

      local i = 1
      while i <= #lines and #list < 35 do
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
          local isInst = installedMap[name] or (header:lower():find("installed") ~= nil)

          local votesStr = header:match("%(%+(%d+)")
          local popStr = header:match("%(%+%d+%s+([%d%.]+)%)")
          local votes = votesStr and tonumber(votesStr) or nil
          local isOrphaned = header:find("%(Orphaned%)") ~= nil
          local isOutOfDate = header:find("%(Out%-of%-date%)") ~= nil

          table.insert(list, {
            name = name,
            repo = repo,
            version = ver,
            desc = desc,
            installed = isInst,
            votes = votes,
            popularity = popStr,
            isOrphaned = isOrphaned,
            isOutOfDate = isOutOfDate,
          })
        end
      end
    end

    searchResults = list
    render()
  end, 5000)
  end

  if immediate then
    doSearch()
  else
    noctalia.runAsync("sleep 0.2", doSearch)
  end
end

local function filterLocalList(list, query)
  if not query or query == "" then
    return list
  end
  local q = query:lower()
  local filtered = {}
  for _, p in ipairs(list) do
    if p.name:lower():find(q, 1, true) or (p.desc and p.desc:lower():find(q, 1, true)) then
      table.insert(filtered, p)
    end
  end
  return filtered
end

local function renderRepoBadge(repo)
  local r = (repo or "extra"):lower()
  local col = "primary"
  local bg = "primary/0.15"

  if r == "aur" then
    col = "tertiary"
    bg = "tertiary/0.15"
  elseif r == "core" then
    col = "secondary"
    bg = "secondary/0.15"
  elseif r == "multilib" or r == "local" then
    col = "outline"
    bg = "surface_variant"
  end

  return ui.row({
    align = "center",
    paddingH = 6,
    paddingV = 2,
    radius = 6,
    fill = bg,
  }, {
    ui.label({
      text = r:upper(),
      fontSize = 10,
      fontWeight = "bold",
      color = col,
    }),
  })
end

local function renderInstalledBadge()
  return ui.row({
    align = "center",
    gap = 4,
    paddingH = 6,
    paddingV = 2,
    radius = 6,
    fill = "primary/0.2",
  }, {
    ui.glyph({ name = "check", size = 11, color = "primary" }),
    ui.label({ text = tr("panel.badges.installed"), fontSize = 10, fontWeight = "bold", color = "primary" }),
  })
end

local function renderTrustBadge(pkg)
  -- 1. Official repositories (core, extra, multilib, etc.)
  if pkg.repo ~= "aur" and pkg.repo ~= "orphan" and pkg.repo ~= "local" then
    return ui.row({
      align = "center",
      gap = 4,
      paddingH = 6,
      paddingV = 2,
      radius = 6,
      fill = "primary/0.14",
    }, {
      ui.glyph({ name = "shield-check", size = 11, color = "primary" }),
      ui.label({
        text = "Official",
        fontSize = 10,
        fontWeight = "bold",
        color = "primary",
      }),
    })
  end

  -- 2. AUR Packages
  if pkg.repo == "aur" then
    if pkg.isOrphaned then
      return ui.row({
        align = "center",
        gap = 4,
        paddingH = 6,
        paddingV = 2,
        radius = 6,
        fill = "error/0.18",
      }, {
        ui.glyph({ name = "alert-triangle", size = 11, color = "error" }),
        ui.label({
          text = "Orphaned",
          fontSize = 10,
          fontWeight = "bold",
          color = "error",
        }),
      })
    end

    local v = pkg.votes
    if v ~= nil then
      local glyph = "thumbs-up"
      local col = "on_surface"
      local bg = "surface_variant/0.8"
      local border = nil

      if v >= 50 then
        glyph = "shield-check"
        col = "primary"
        bg = "primary/0.18"
      elseif v >= 5 then
        glyph = "thumbs-up"
        col = "on_surface"
        bg = "surface_variant/0.8"
      elseif v > 0 then
        glyph = "thumbs-up"
        col = "warning"
        bg = "warning/0.18"
      else
        glyph = "alert-octagon"
        col = "error"
        bg = "error/0.15"
        border = "error/0.3"
      end

      local badgeChildren = {
        ui.glyph({ name = glyph, size = 11, color = col }),
        ui.label({
          text = tostring(v),
          fontSize = 11,
          fontWeight = "bold",
          color = col,
        }),
      }

      local opts = {
        align = "center",
        gap = 4,
        paddingH = 6,
        paddingV = 2,
        radius = 6,
        fill = bg,
      }
      if border then
        opts.borderWidth = 1
        opts.border = border
      end

      return ui.row(opts, badgeChildren)
    else
      return ui.row({
        align = "center",
        gap = 4,
        paddingH = 6,
        paddingV = 2,
        radius = 6,
        fill = "surface_variant/0.8",
      }, {
        ui.glyph({ name = "users", size = 11, color = "on_surface_variant" }),
        ui.label({ text = "AUR", fontSize = 10, color = "on_surface_variant" }),
      })
    end
  end

  return nil
end

local function renderTrustDetailsCard(pkg, details)
  local isAur = (details.repo == "aur" or pkg.repo == "aur")
  local trustCardChildren = {}

  if not isAur then
    table.insert(trustCardChildren, ui.row({ align = "center", gap = 10 }, {
      ui.glyph({ name = "shield-check", size = 22, color = "primary" }),
      ui.column({ gap = 2, flexGrow = 1 }, {
        ui.label({
          text = tr("panel.trust.verified_official"),
          fontSize = 14,
          fontWeight = "bold",
          color = "primary",
        }),
        ui.label({
          text = tr("panel.trust.official_desc"),
          fontSize = 12,
          color = "on_surface",
        }),
      }),
    }))

    local officialMeta = {}
    if details.packager and details.packager ~= "" and details.packager ~= "Unknown Packager" then
      table.insert(officialMeta, ui.label({
        text = "Packager: " .. details.packager,
        fontSize = 11,
        color = "on_surface_variant",
      }))
    end
    if details.validatedBy and details.validatedBy ~= "" and details.validatedBy ~= "None" then
      table.insert(officialMeta, ui.label({
        text = "Validated: " .. details.validatedBy,
        fontSize = 11,
        fontWeight = "medium",
        color = "primary",
      }))
    end
    if #officialMeta > 0 then
      table.insert(trustCardChildren, ui.row({ align = "center", gap = 16 }, officialMeta))
    end

    return ui.column({
      align = "stretch",
      gap = 8,
      padding = 12,
      radius = 10,
      fill = "primary/0.12",
      borderWidth = 1,
      border = "primary/0.3",
    }, trustCardChildren)
  else
    local votes = details.votes or pkg.votes
    local isOrphaned = details.isOrphaned or pkg.isOrphaned or false
    local isOut = details.isOutOfDate or pkg.isOutOfDate or false

    local cardTitle = ""
    local cardDesc = ""
    local cardGlyph = "thumbs-up"
    local cardColor = "on_surface"
    local cardFill = "surface_variant/0.5"
    local cardBorder = "outline/0.3"

    if isOrphaned then
      cardTitle = "Orphaned AUR Package (Unmaintained)"
      cardDesc = "This package has no active maintainer. It may contain unmaintained or unsafe code."
      cardGlyph = "alert-triangle"
      cardColor = "error"
      cardFill = "error/0.15"
      cardBorder = "error/0.4"
    elseif votes == nil then
      cardTitle = "AUR Community Package"
      cardDesc = "Community-contributed package from the Arch User Repository. Inspect the PKGBUILD before installing."
      cardGlyph = "users"
      cardColor = "on_surface"
      cardFill = "surface_variant/0.6"
      cardBorder = "outline/0.3"
    elseif votes >= 50 then
      cardTitle = tostring(votes) .. " Community Votes · Highly Trusted"
      cardDesc = "Extensively reviewed, tested, and voted on by the Arch Linux community. Low risk of malware."
      cardGlyph = "shield-check"
      cardColor = "primary"
      cardFill = "primary/0.14"
      cardBorder = "primary/0.3"
    elseif votes >= 5 then
      cardTitle = tostring(votes) .. " Community Votes · Community Reviewed"
      cardDesc = "Established AUR package with active community usage and votes."
      cardGlyph = "thumbs-up"
      cardColor = "on_surface"
      cardFill = "surface_variant/0.6"
      cardBorder = "outline/0.3"
    elseif votes > 0 then
      cardTitle = tostring(votes) .. " Community Votes · Low Reviews"
      cardDesc = "Has only a few votes. Inspect the PKGBUILD and source code before installing."
      cardGlyph = "alert-circle"
      cardColor = "on_surface"
      cardFill = "warning/0.16"
      cardBorder = "warning/0.4"
    else
      cardTitle = "0 Community Votes · Unreviewed Caution"
      cardDesc = "Warning: 0 community votes! Anyone can upload to the AUR without review. Inspect the PKGBUILD for malicious code before installing."
      cardGlyph = "alert-octagon"
      cardColor = "error"
      cardFill = "error/0.15"
      cardBorder = "error/0.4"
    end

    local topRowChildren = {
      ui.row({ align = "center", gap = 10, flexGrow = 1 }, {
        ui.glyph({ name = cardGlyph, size = 22, color = cardColor }),
        ui.column({ gap = 2, flexGrow = 1 }, {
          ui.label({
            text = cardTitle,
            fontSize = 14,
            fontWeight = "bold",
            color = cardColor,
          }),
          ui.label({
            text = cardDesc,
            fontSize = 12,
            color = "on_surface",
          }),
        }),
      }),
    }

    if details.aurUrl and details.aurUrl ~= "" then
      table.insert(topRowChildren, ui.button({
        glyph = "external-link",
        text = tr("panel.trust.inspect_aur"),
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
          noctalia.runAsync("xdg-open " .. shellQuote(details.aurUrl))
        end,
      }))
    end

    table.insert(trustCardChildren, ui.row({
      align = "center",
      justify = "space_between",
      gap = 10,
    }, topRowChildren))

    local metaNodes = {}
    if details.maintainer and details.maintainer ~= "" then
      table.insert(metaNodes, ui.label({
        text = "Maintainer: " .. details.maintainer,
        fontSize = 11,
        color = "on_surface_variant",
      }))
    end
    if details.popularity and details.popularity ~= "" then
      local popNum = tonumber(details.popularity)
      local popStr = popNum and string.format("%.2f", popNum) or details.popularity
      table.insert(metaNodes, ui.label({
        text = "Popularity Score: " .. popStr,
        fontSize = 11,
        color = "on_surface_variant",
      }))
    end
    if isOut then
      table.insert(metaNodes, ui.label({
        text = "⚠️ Flagged Out-of-Date",
        fontSize = 11,
        fontWeight = "bold",
        color = "error",
      }))
    end

    if #metaNodes > 0 then
      table.insert(trustCardChildren, ui.row({ align = "center", gap = 16 }, metaNodes))
    end

    return ui.column({
      align = "stretch",
      gap = 8,
      padding = 12,
      radius = 10,
      fill = cardFill,
      borderWidth = 1,
      border = cardBorder,
    }, trustCardChildren)
  end
end

local function renderPackageCard(pkg)
  local isInst = pkg.installed or installedMap[pkg.name] == true
  local isOrphan = (currentTab == "orphans")

  local rightActionNodes = {
    ui.button({
      glyph = "info-circle",
      variant = "ghost",
      controlSize = "sm",
      tooltip = tr("panel.buttons.details"),
      onClick = function()
        loadPackageDetails(pkg)
      end,
    }),
  }

  if pkg.isUpdate then
    table.insert(rightActionNodes, ui.button({
      text = tr("panel.buttons.update"),
      glyph = "arrow-up-circle",
      variant = "primary",
      controlSize = "sm",
      onClick = function()
        installPackage(pkg.name, false, pkg.repo)
      end,
    }))
  elseif isInst then
    table.insert(rightActionNodes, ui.button({
      text = tr("panel.buttons.remove"),
      glyph = "trash",
      variant = "destructive",
      controlSize = "sm",
      onClick = function()
        confirmingRemovalPkg = pkg
        render()
      end,
    }))
  else
    table.insert(rightActionNodes, ui.button({
      text = tr("panel.buttons.install"),
      glyph = "download",
      variant = "primary",
      controlSize = "sm",
      onClick = function()
        installPackage(pkg.name, false, pkg.repo)
      end,
    }))
  end

  local badgeNodes = {
    ui.label({
      text = pkg.name,
      fontSize = 15,
      fontWeight = "bold",
      color = "on_surface",
    }),
  }

  -- 1. Exact Vote Count Badge immediately to the right of the package name!
  local voteBadge = renderTrustBadge(pkg)
  if voteBadge then
    table.insert(badgeNodes, voteBadge)
  end

  -- 2. Version
  if pkg.isUpdate and pkg.oldVersion then
    table.insert(badgeNodes, ui.label({
      text = pkg.oldVersion .. " → " .. pkg.version,
      fontSize = 12,
      fontWeight = "bold",
      color = "primary",
    }))
  elseif pkg.version ~= "" then
    table.insert(badgeNodes, ui.label({
      text = pkg.version,
      fontSize = 12,
      color = "on_surface_variant",
    }))
  end

  -- 3. Repo Badge
  table.insert(badgeNodes, renderRepoBadge(pkg.repo))

  -- 4. Installed Badge (only in Explore tab to avoid clutter)
  if isInst and currentTab == "explore" then
    table.insert(badgeNodes, renderInstalledBadge())
  end

  if isOrphan then
    table.insert(badgeNodes, ui.row({
      align = "center",
      gap = 4,
      paddingH = 6,
      paddingV = 2,
      radius = 6,
      fill = "error/0.15",
    }, {
      ui.glyph({ name = "alert-circle", size = 11, color = "error" }),
      ui.label({ text = tr("panel.badges.orphan"), fontSize = 10, fontWeight = "bold", color = "error" }),
    }))
  end

  local cardItems = {
    ui.row({
      align = "center",
      justify = "space_between",
      gap = 12,
    }, {
      ui.row({ align = "center", gap = 8, flexShrink = 1, wrap = true }, badgeNodes),
      ui.row({ align = "center", gap = 6, flexShrink = 0 }, rightActionNodes),
    }),
  }

  if pkg.desc ~= "" then
    table.insert(cardItems, ui.label({
      text = pkg.desc,
      fontSize = 12,
      color = "on_surface_variant",
      maxLines = 2,
    }))
  end

  return ui.column({
    align = "stretch",
    padding = 12,
    gap = 6,
    radius = 10,
    fill = "surface_variant/0.55",
    borderWidth = 1,
    border = "outline/0.2",
  }, cardItems)
end

local function renderDetailsView()
  local pkg = pkgDetails or selectedPkg
  local isInst = pkg.installed or installedMap[pkg.name] == true

  local topActionNodes = {}
  if isInst then
    table.insert(topActionNodes, ui.button({
      text = tr("panel.buttons.remove"),
      glyph = "trash",
      variant = "destructive",
      controlSize = "sm",
      onClick = function()
        confirmingRemovalPkg = pkg
        render()
      end,
    }))
  else
    table.insert(topActionNodes, ui.button({
      text = tr("panel.buttons.install"),
      glyph = "download",
      variant = "primary",
      controlSize = "sm",
      onClick = function()
        installPackage(pkg.name, false, pkg.repo)
      end,
    }))
  end

  local headerBadgeNodes = {
    renderRepoBadge(pkg.repo),
  }
  local detailsTrustBadge = renderTrustBadge(pkgDetails or pkg)
  if detailsTrustBadge then
    table.insert(headerBadgeNodes, detailsTrustBadge)
  end
  if isInst then
    table.insert(headerBadgeNodes, renderInstalledBadge())
  end

  local metaRowNodes = {}
  if pkg.size and pkg.size ~= "" then
    table.insert(metaRowNodes, ui.column({ gap = 2 }, {
      ui.label({ text = tr("panel.details.size"), fontSize = 11, color = "outline" }),
      ui.label({ text = pkg.size, fontSize = 13, fontWeight = "bold", color = "on_surface" }),
    }))
  end

  if pkg.licenses and pkg.licenses ~= "" then
    table.insert(metaRowNodes, ui.column({ gap = 2 }, {
      ui.label({ text = tr("panel.details.licenses"), fontSize = 11, color = "outline" }),
      ui.label({ text = pkg.licenses, fontSize = 13, color = "on_surface" }),
    }))
  end

  if pkg.url and pkg.url ~= "" then
    table.insert(metaRowNodes, ui.column({ gap = 2 }, {
      ui.label({ text = tr("panel.details.url"), fontSize = 11, color = "outline" }),
      ui.button({
        text = (#pkg.url > 40) and (pkg.url:sub(1, 37) .. "...") or pkg.url,
        tooltip = pkg.url,
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
          noctalia.runAsync("xdg-open " .. shellQuote(pkg.url))
        end,
      }),
    }))
  end

  local detailCardNodes = {
    ui.row({
      align = "center",
      gap = 10,
    }, {
      ui.glyph({ name = isLoadingDetails and "loader-2" or "package", size = 26, color = "primary" }),
      ui.column({ gap = 2 }, {
        ui.label({ text = pkg.name, fontSize = 20, fontWeight = "bold", color = "on_surface" }),
        ui.label({ text = (pkg.version and pkg.version ~= "") and pkg.version or (isLoadingDetails and "Fetching details..." or ""), fontSize = 13, color = "on_surface_variant" }),
      }),
      ui.spacer(),
      ui.row({ align = "center", gap = 8 }, headerBadgeNodes),
    }),

    ui.separator({}),
  }

  table.insert(detailCardNodes, renderTrustDetailsCard(pkg, pkgDetails or pkg))

  if pkg.desc and pkg.desc ~= "" then
    table.insert(detailCardNodes, ui.column({ gap = 4 }, {
      ui.label({ text = "Description", fontSize = 12, fontWeight = "bold", color = "outline" }),
      ui.label({ text = pkg.desc, fontSize = 13, color = "on_surface" }),
    }))
  end

  if #metaRowNodes > 0 then
    table.insert(detailCardNodes, ui.row({
      align = "start",
      gap = 24,
    }, metaRowNodes))
  end

  if pkg.depends and pkg.depends ~= "" and pkg.depends ~= "None" then
    table.insert(detailCardNodes, ui.column({ gap = 4 }, {
      ui.label({ text = tr("panel.details.depends"), fontSize = 11, color = "outline" }),
      ui.label({ text = pkg.depends, fontSize = 12, color = "on_surface_variant" }),
    }))
  end

  return ui.column({
    align = "stretch",
    gap = 14,
    flexGrow = 1,
  }, {
    ui.row({
      align = "center",
      justify = "space_between",
    }, {
      ui.button({
        glyph = "arrow-left",
        text = "Back to List",
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
          selectedPkg = nil
          pkgDetails = nil
          render()
        end,
      }),
      ui.row({ align = "center", gap = 8 }, topActionNodes),
    }),

    ui.column({
      align = "stretch",
      gap = 12,
      padding = 18,
      radius = 12,
      fill = "surface_variant",
      borderWidth = 1,
      border = "outline/0.3",
      flexGrow = 1,
    }, detailCardNodes),
  })
end

render = function()
  -- Header
  local header = ui.row({
    align = "center",
    justify = "space_between",
  }, {
    ui.row({ align = "center", gap = 10 }, {
      ui.glyph({ name = "package", size = 24, color = "primary" }),
      ui.label({ text = tr("panel.title"), fontSize = 18, fontWeight = "bold", color = "on_surface" }),
    }),

    -- Tab Switcher
    ui.row({
      align = "center",
      gap = 4,
      padding = 3,
      radius = 8,
      fill = "surface_variant",
    }, {
      ui.button({
        text = tr("panel.tabs.explore"),
        glyph = "compass",
        variant = (currentTab == "explore") and "primary" or "ghost",
        controlSize = "sm",
        onClick = function()
          currentTab = "explore"
          selectedPkg = nil
          confirmingRemovalPkg = nil
          confirmingCleanOrphans = false
          if searchQuery ~= "" and #searchResults == 0 then
            performSearch(searchQuery)
          else
            render()
          end
        end,
      }),
      ui.button({
        text = tr("panel.tabs.installed") .. " (" .. tostring(#installedPackages) .. ")",
        glyph = "circle-check",
        variant = (currentTab == "installed") and "primary" or "ghost",
        controlSize = "sm",
        onClick = function()
          currentTab = "installed"
          selectedPkg = nil
          confirmingRemovalPkg = nil
          confirmingCleanOrphans = false
          render()
        end,
      }),
      ui.button({
        text = tr("panel.tabs.updates") .. " (" .. tostring(#updatePackages) .. ")",
        glyph = "arrow-up-circle",
        variant = (currentTab == "updates") and "primary" or "ghost",
        controlSize = "sm",
        onClick = function()
          currentTab = "updates"
          selectedPkg = nil
          confirmingRemovalPkg = nil
          confirmingCleanOrphans = false
          render()
        end,
      }),
      ui.button({
        text = tr("panel.tabs.orphans") .. " (" .. tostring(#orphanPackages) .. ")",
        glyph = "trash",
        variant = (currentTab == "orphans") and "primary" or "ghost",
        controlSize = "sm",
        onClick = function()
          currentTab = "orphans"
          selectedPkg = nil
          confirmingRemovalPkg = nil
          confirmingCleanOrphans = false
          render()
        end,
      }),
    }),

    ui.button({
      glyph = "x",
      variant = "ghost",
      controlSize = "sm",
      onClick = function()
        panel.close()
      end,
    }),
  })

  -- Search bar nodes
  local searchRowNodes = {
    ui.input({
      value = searchQuery,
      placeholder = tr("panel.search_placeholder"),
      controlSize = "md",
      flexGrow = 1,
      onChange = function(val)
        searchQuery = val
        if currentTab == "explore" then
          performSearch(val)
        else
          render()
        end
      end,
      onSubmit = function(val)
        searchQuery = val
        if currentTab == "explore" then
          performSearch(val, true)
        end
      end,
    }),
  }

  if searchQuery ~= "" then
    table.insert(searchRowNodes, ui.button({
      glyph = "x",
      variant = "ghost",
      controlSize = "sm",
      tooltip = tr("panel.buttons.clear"),
      onClick = function()
        searchQuery = ""
        searchResults = {}
        render()
      end,
    }))
  end

  table.insert(searchRowNodes, ui.button({
    glyph = "refresh",
    variant = "ghost",
    controlSize = "sm",
    tooltip = tr("panel.buttons.refresh"),
    onClick = function()
      loadInstalledPackages(function()
        loadUpdates()
        loadOrphans()
      end)
      if currentTab == "explore" and searchQuery ~= "" then
        performSearch(searchQuery)
      end
    end,
  }))

  local searchRow = ui.row({ align = "center", gap = 8 }, searchRowNodes)

  -- In-Panel Removal Confirmation Dialog (if active)
  local confirmationBanner = nil
  if confirmingRemovalPkg ~= nil then
    confirmationBanner = ui.column({
      align = "stretch",
      gap = 10,
      padding = 14,
      radius = 10,
      fill = "error/0.14",
      borderWidth = 1,
      border = "error/0.4",
    }, {
      ui.row({ align = "center", gap = 10 }, {
        ui.glyph({ name = "alert-triangle", size = 22, color = "error" }),
        ui.column({ gap = 2, flexGrow = 1 }, {
          ui.label({
            text = tr("panel.confirm.remove_title") .. ": " .. confirmingRemovalPkg.name,
            fontSize = 15,
            fontWeight = "bold",
            color = "error",
          }),
          ui.label({
            text = tr("panel.confirm.remove_desc", { name = confirmingRemovalPkg.name }),
            fontSize = 12,
            color = "on_surface",
          }),
        }),
      }),
      ui.row({ align = "center", justify = "end", gap = 8 }, {
        ui.button({
          text = tr("panel.buttons.cancel"),
          variant = "ghost",
          controlSize = "sm",
          onClick = function()
            confirmingRemovalPkg = nil
            render()
          end,
        }),
        ui.button({
          text = tr("panel.buttons.confirm_remove"),
          glyph = "trash",
          variant = "destructive",
          controlSize = "sm",
          onClick = function()
            local p = confirmingRemovalPkg
            confirmingRemovalPkg = nil
            executeRemoval(p.name)
          end,
        }),
      }),
    })
  elseif confirmingCleanOrphans then
    confirmationBanner = ui.column({
      align = "stretch",
      gap = 10,
      padding = 14,
      radius = 10,
      fill = "error/0.14",
      borderWidth = 1,
      border = "error/0.4",
    }, {
      ui.row({ align = "center", gap = 10 }, {
        ui.glyph({ name = "alert-triangle", size = 22, color = "error" }),
        ui.column({ gap = 2, flexGrow = 1 }, {
          ui.label({
            text = tr("panel.confirm.clean_title"),
            fontSize = 15,
            fontWeight = "bold",
            color = "error",
          }),
          ui.label({
            text = tr("panel.confirm.clean_desc", { count = tostring(#orphanPackages) }),
            fontSize = 12,
            color = "on_surface",
          }),
        }),
      }),
      ui.row({ align = "center", justify = "end", gap = 8 }, {
        ui.button({
          text = tr("panel.buttons.cancel"),
          variant = "ghost",
          controlSize = "sm",
          onClick = function()
            confirmingCleanOrphans = false
            render()
          end,
        }),
        ui.button({
          text = tr("panel.buttons.confirm_clean"),
          glyph = "trash",
          variant = "destructive",
          controlSize = "sm",
          onClick = function()
            confirmingCleanOrphans = false
            executeCleanOrphans()
          end,
        }),
      }),
    })
  elseif isOperating then
    confirmationBanner = ui.row({
      align = "center",
      justify = "space_between",
      gap = 12,
      padding = 10,
      radius = 8,
      fill = "primary/0.15",
      borderWidth = 1,
      border = "primary/0.3",
    }, {
      ui.row({ align = "center", gap = 8 }, {
        ui.glyph({ name = "loader-2", size = 18, color = "primary" }),
        ui.label({ text = operatingMsg, fontSize = 13, fontWeight = "bold", color = "primary" }),
      }),
      ui.button({
        text = tr("panel.buttons.cancel"),
        glyph = "x",
        variant = "destructive",
        controlSize = "sm",
        onClick = function()
          cancelOperation()
        end,
      }),
    })
  end

  -- Content Area
  local content
  if selectedPkg ~= nil then
    content = renderDetailsView()
  else
    local itemsToRender = {}

    if currentTab == "explore" then
      if isSearching then
        content = ui.column({
          align = "center",
          justify = "center",
          flexGrow = 1,
          gap = 12,
          padding = 24,
          radius = 12,
          fill = "surface_variant",
          borderWidth = 1,
          border = "outline/0.2",
        }, {
          ui.glyph({ name = "loader-2", size = 36, color = "primary" }),
          ui.label({ text = tr("panel.status.searching"), fontSize = 14, color = "on_surface_variant" }),
        })
      elseif searchQuery == "" or #searchQuery < 2 then
        content = ui.column({
          align = "center",
          justify = "center",
          flexGrow = 1,
          gap = 14,
          padding = 24,
          radius = 12,
          fill = "surface_variant/0.45",
          borderWidth = 1,
          border = "outline/0.2",
        }, {
          ui.glyph({ name = "search", size = 48, color = "primary" }),
          ui.label({ text = tr("panel.status.empty_search"), fontSize = 14, color = "on_surface_variant" }),
        })
      elseif #searchResults == 0 then
        content = ui.column({
          align = "center",
          justify = "center",
          flexGrow = 1,
          gap = 14,
          padding = 24,
          radius = 12,
          fill = "surface_variant/0.45",
          borderWidth = 1,
          border = "outline/0.2",
        }, {
          ui.glyph({ name = searchRateLimited and "alert-triangle" or "package-off", size = 48, color = searchRateLimited and "warning" or "outline" }),
          ui.label({ text = searchRateLimited and tr("panel.status.rate_limited") or tr("panel.status.no_search_results"), fontSize = 14, color = searchRateLimited and "warning" or "on_surface_variant" }),
        })
      else
        itemsToRender = searchResults
      end
    elseif currentTab == "installed" then
      if isLoadingInstalled then
        content = ui.column({
          align = "center",
          justify = "center",
          flexGrow = 1,
          gap = 12,
          padding = 24,
          radius = 12,
          fill = "surface_variant",
          borderWidth = 1,
          border = "outline/0.2",
        }, {
          ui.glyph({ name = "loader-2", size = 36, color = "primary" }),
          ui.label({ text = tr("panel.status.loading"), fontSize = 14, color = "on_surface_variant" }),
        })
      else
        itemsToRender = filterLocalList(installedPackages, searchQuery)
        if #itemsToRender == 0 then
          content = ui.column({
            align = "center",
            justify = "center",
            flexGrow = 1,
            gap = 14,
            padding = 24,
            radius = 12,
            fill = "surface_variant",
            borderWidth = 1,
            border = "outline/0.2",
          }, {
            ui.glyph({ name = "package-off", size = 48, color = "outline" }),
            ui.label({ text = tr("panel.status.no_installed"), fontSize = 14, color = "on_surface_variant" }),
          })
        end
      end
    elseif currentTab == "updates" then
      if isLoadingUpdates then
        content = ui.column({
          align = "center",
          justify = "center",
          flexGrow = 1,
          gap = 12,
          padding = 24,
          radius = 12,
          fill = "surface_variant",
          borderWidth = 1,
          border = "outline/0.2",
        }, {
          ui.glyph({ name = "loader-2", size = 36, color = "primary" }),
          ui.label({ text = tr("panel.status.checking_updates"), fontSize = 14, color = "on_surface_variant" }),
        })
      else
        itemsToRender = filterLocalList(updatePackages, searchQuery)
        if #itemsToRender == 0 then
          content = ui.column({
            align = "center",
            justify = "center",
            flexGrow = 1,
            gap = 12,
            padding = 24,
            radius = 12,
            fill = "surface_variant",
            borderWidth = 1,
            border = "outline/0.2",
          }, {
            ui.glyph({ name = "circle-check", size = 48, color = "primary" }),
            ui.label({ text = tr("panel.status.no_updates"), fontSize = 15, fontWeight = "bold", color = "on_surface" }),
            ui.label({ text = tr("panel.status.no_updates_desc"), fontSize = 13, color = "on_surface_variant" }),
          })
        end
      end
    elseif currentTab == "orphans" then
      if isLoadingOrphans then
        content = ui.column({
          align = "center",
          justify = "center",
          flexGrow = 1,
          gap = 12,
          padding = 24,
          radius = 12,
          fill = "surface_variant",
          borderWidth = 1,
          border = "outline/0.2",
        }, {
          ui.glyph({ name = "loader-2", size = 36, color = "primary" }),
          ui.label({ text = tr("panel.status.loading"), fontSize = 14, color = "on_surface_variant" }),
        })
      else
        itemsToRender = filterLocalList(orphanPackages, searchQuery)
        if #itemsToRender == 0 then
          content = ui.column({
            align = "center",
            justify = "center",
            flexGrow = 1,
            gap = 12,
            padding = 24,
            radius = 12,
            fill = "surface_variant",
            borderWidth = 1,
            border = "outline/0.2",
          }, {
            ui.glyph({ name = "circle-check", size = 48, color = "primary" }),
            ui.label({ text = tr("panel.status.no_orphans"), fontSize = 15, fontWeight = "bold", color = "on_surface" }),
          })
        end
      end
    end

    if content == nil and #itemsToRender > 0 then
      local cardNodes = {}
      for _, p in ipairs(itemsToRender) do
        table.insert(cardNodes, renderPackageCard(p))
      end

      local contentChildren = {}

      if currentTab == "updates" and #updatePackages > 0 then
        table.insert(contentChildren, ui.row({
          align = "center",
          justify = "space_between",
          padding = 12,
          radius = 10,
          fill = "primary/0.12",
          borderWidth = 1,
          border = "primary/0.3",
        }, {
          ui.row({ align = "center", gap = 8 }, {
            ui.glyph({ name = "arrow-up-circle", size = 20, color = "primary" }),
            ui.label({
              text = tr("panel.status.count_updates", { count = tostring(#updatePackages) }),
              fontSize = 13,
              fontWeight = "bold",
              color = "primary",
            }),
          }),
          ui.button({
            text = tr("panel.buttons.upgrade_all"),
            glyph = "arrow-up-circle",
            variant = "primary",
            controlSize = "sm",
            onClick = function()
              executeSystemUpgrade()
            end,
          }),
        }))
      end

      if currentTab == "orphans" and #orphanPackages > 0 and not confirmingCleanOrphans then
        table.insert(contentChildren, ui.row({
          align = "center",
          justify = "space_between",
          padding = 12,
          radius = 10,
          fill = "error/0.12",
          borderWidth = 1,
          border = "error/0.3",
        }, {
          ui.row({ align = "center", gap = 8 }, {
            ui.glyph({ name = "alert-triangle", size = 20, color = "error" }),
            ui.label({
              text = tr("panel.status.count_orphans", { count = tostring(#orphanPackages) }),
              fontSize = 13,
              fontWeight = "bold",
              color = "error",
            }),
          }),
          ui.button({
            text = tr("panel.buttons.clean_orphans"),
            glyph = "trash",
            variant = "destructive",
            controlSize = "sm",
            onClick = function()
              confirmingCleanOrphans = true
              render()
            end,
          }),
        }))
      end

      table.insert(contentChildren, ui.scroll({
        align = "stretch",
        gap = 8,
        flexGrow = 1,
      }, cardNodes))

      content = ui.column({
        align = "stretch",
        gap = 10,
        flexGrow = 1,
      }, contentChildren)
    end
  end

  -- Bottom status bar (Enhanced visibility & high contrast)
  local helper = getHelper()
  local effectiveTerm = getEffectiveUseTerminal()
  local footerLeftNodes = {
    ui.row({
      align = "center",
      gap = 5,
      paddingH = 8,
      paddingV = 3,
      radius = 6,
      fill = "primary/0.18",
    }, {
      ui.glyph({ name = "terminal", size = 12, color = "primary" }),
      ui.label({ text = "Helper: " .. helper, fontSize = 11, fontWeight = "bold", color = "primary" }),
    }),
    ui.button({
      text = effectiveTerm and "Terminal Mode" or "Background Mode",
      glyph = effectiveTerm and "terminal" or "shield-check",
      variant = effectiveTerm and "primary" or "ghost",
      controlSize = "sm",
      tooltip = effectiveTerm and "Actions run in a terminal window (click to switch to background)" or "Actions run in background via Polkit (click to switch to terminal mode)",
      onClick = function()
        sessionUseTerminal = not effectiveTerm
        render()
      end,
    }),
    ui.label({
      text = tostring(#installedPackages) .. " installed",
      fontSize = 12,
      fontWeight = "medium",
      color = "on_surface",
    }),
  }

  if #updatePackages > 0 then
    table.insert(footerLeftNodes, ui.label({
      text = "·  " .. tostring(#updatePackages) .. " updates",
      fontSize = 12,
      fontWeight = "bold",
      color = "primary",
    }))
  end

  if #orphanPackages > 0 then
    table.insert(footerLeftNodes, ui.label({
      text = "·  " .. tostring(#orphanPackages) .. " orphans",
      fontSize = 12,
      fontWeight = "bold",
      color = "error",
    }))
  end

  local footer = ui.row({
    align = "center",
    justify = "space_between",
    paddingH = 14,
    paddingV = 8,
    radius = 8,
    fill = "surface_variant/0.50",
    borderWidth = 1,
    border = "outline/0.2",
  }, {
    ui.row({ align = "center", gap = 10 }, footerLeftNodes),
    ui.label({
      text = tr("panel.status.hints"),
      fontSize = 12,
      color = "on_surface_variant",
    }),
  })

  local mainChildren = {
    header,
  }
  if selectedPkg == nil then
    table.insert(mainChildren, searchRow)
  end
  if confirmationBanner ~= nil then
    table.insert(mainChildren, confirmationBanner)
  end
  if content ~= nil then
    table.insert(mainChildren, content)
  end
  table.insert(mainChildren, footer)

  panel.render(ui.column({
    padding = 16,
    gap = 12,
    align = "stretch",
    flexGrow = 1,
    fill = "surface/0.60",
    radius = 16,
    borderWidth = 1,
    border = "outline/0.25",
  }, mainChildren))
end

function onKey(chord, pressed)
  if not pressed then return end
  local key = tostring(chord):lower()

  if key == "escape" then
    if isOperating then
      cancelOperation()
    elseif confirmingRemovalPkg ~= nil then
      confirmingRemovalPkg = nil
      render()
    elseif confirmingCleanOrphans then
      confirmingCleanOrphans = false
      render()
    elseif selectedPkg ~= nil then
      selectedPkg = nil
      pkgDetails = nil
      render()
    else
      panel.close()
    end
  elseif key == "return" or key == "enter" then
    if confirmingRemovalPkg ~= nil then
      local p = confirmingRemovalPkg
      confirmingRemovalPkg = nil
      executeRemoval(p.name)
    elseif confirmingCleanOrphans then
      confirmingCleanOrphans = false
      executeCleanOrphans()
    elseif selectedPkg ~= nil then
      local pkg = pkgDetails or selectedPkg
      local isInst = pkg.installed or installedMap[pkg.name] == true
      if isInst then
        confirmingRemovalPkg = pkg
        render()
      else
        installPackage(pkg.name, false, pkg.repo)
      end
    end
  elseif key == "tab" then
    if currentTab == "explore" then
      currentTab = "installed"
    elseif currentTab == "installed" then
      currentTab = "updates"
    elseif currentTab == "updates" then
      currentTab = "orphans"
    else
      currentTab = "explore"
    end
    selectedPkg = nil
    confirmingRemovalPkg = nil
    confirmingCleanOrphans = false
    render()
  end
end

function onOpen(context)
  confirmingRemovalPkg = nil
  confirmingCleanOrphans = false
  if context == "updates" or context == "installed" or context == "orphans" or context == "explore" then
    currentTab = context
  elseif context and context:match("^search:(.+)") then
    currentTab = "explore"
    searchQuery = context:match("^search:(.+)")
  end
  loadInstalledPackages(function()
    loadUpdates()
    loadOrphans()
    if searchQuery ~= "" then
      performSearch(searchQuery, true)
    end
  end)
  render()
end

function onClose()
  selectedPkg = nil
  pkgDetails = nil
  confirmingRemovalPkg = nil
  confirmingCleanOrphans = false
end

loadInstalledPackages(function()
  loadUpdates()
  loadOrphans()
end)
