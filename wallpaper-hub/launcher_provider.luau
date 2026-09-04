--!nonstrict
-- Wallpaper Hub — Launcher provider for quick wallpaper switching (/wall)

local cachedWallpapers = {}
local currentWallpaper = ""

local function tr(key, args)
  return noctalia.tr(key, args)
end

local function shellQuote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function getWallpaperDir()
  local configured = noctalia.getConfig("wallpaper_dir")
  if type(configured) == "string" and configured ~= "" then
    return noctalia.expandPath(configured)
  end
  if noctalia.wallpaperDirectory then
    local ok, d = pcall(function() return noctalia.wallpaperDirectory() end)
    if ok and type(d) == "string" and d ~= "" then
      return d
    end
  end
  local home = noctalia.getenv("HOME") or "/home/ash"
  return home .. "/Pictures/wallpapers"
end

local function isImage(name)
  local lower = name:lower()
  return lower:match("%.png$") ~= nil
      or lower:match("%.jpg$") ~= nil
      or lower:match("%.jpeg$") ~= nil
      or lower:match("%.webp$") ~= nil
end

local function naturalSort(a, b)
  local function pad(s)
    return s:gsub("%d+", function(n)
      return string.format("%08d", tonumber(n) or 0)
    end)
  end
  return pad(a.name:lower()) < pad(b.name:lower())
end

local function scanDirRecursive(dir, list, depth)
  if depth > 3 then return end
  local entries = noctalia.listDir(dir)
  if not entries then return end

  for _, name in ipairs(entries) do
    if name ~= "." and name ~= ".." and not name:match("^%.") then
      local fullPath = dir .. "/" .. name
      local info = noctalia.fileInfo(fullPath)
      if info then
        if info.isDir then
          scanDirRecursive(fullPath, list, depth + 1)
        elseif isImage(name) then
          local cleanName = name:gsub("%.%w+$", "")
          table.insert(list, {
            path = fullPath,
            name = cleanName,
            filename = name,
          })
        end
      end
    end
  end
end

local function refreshWallpapers()
  local dir = getWallpaperDir()
  local list = {}
  scanDirRecursive(dir, list, 0)
  if #list == 0 then
    local cmd = "find " .. shellQuote(dir) .. " -type f \\( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' \\) 2>/dev/null | sort -V"
    noctalia.runAsync(cmd, function(result)
      if result and result.exitCode == 0 and result.stdout then
        local fallbackList = {}
        for line in result.stdout:gmatch("[^\n]+") do
          local fname = line:match("([^/]+)$") or line
          local cname = fname:gsub("%.%w+$", "")
          table.insert(fallbackList, {
            path = line,
            name = cname,
            filename = fname,
          })
        end
        cachedWallpapers = fallbackList
      end
    end, 3000)
  else
    table.sort(list, naturalSort)
    cachedWallpapers = list
  end
end

local function refreshCurrentWallpaper(callback)
  noctalia.runAsync("noctalia msg wallpaper-get", function(result)
    if result and result.exitCode == 0 and result.stdout then
      currentWallpaper = result.stdout:gsub("%s+$", "")
    end
    if callback then callback() end
  end, 2000)
end

function onQuery(query)
  local text = query:gsub("^%s+", ""):gsub("%s+$", ""):lower()

  refreshCurrentWallpaper(function()
    if #cachedWallpapers == 0 then
      refreshWallpapers()
    end

    local rows = {}

    if text == "" then
      table.insert(rows, {
        id = "action:random",
        title = tr("launcher.random"),
        subtitle = tr("launcher.random_desc"),
        glyph = "arrows-shuffle",
      })
      table.insert(rows, {
        id = "action:next",
        title = tr("launcher.next"),
        subtitle = tr("launcher.next_desc"),
        glyph = "chevron-right",
      })
      table.insert(rows, {
        id = "action:prev",
        title = tr("launcher.prev"),
        subtitle = tr("launcher.prev_desc"),
        glyph = "chevron-left",
      })
    end

    local count = 0
    local maxResults = (text == "") and 8 or 15

    for _, wp in ipairs(cachedWallpapers) do
      if text == "" or wp.name:lower():find(text, 1, true) ~= nil or wp.filename:lower():find(text, 1, true) ~= nil then
        local isActive = (wp.path == currentWallpaper)
        table.insert(rows, {
          id = "set:" .. wp.path,
          title = (isActive and "[Active] " or "") .. wp.name,
          subtitle = wp.path,
          glyph = isActive and "check" or "image",
        })
        count += 1
        if count >= maxResults then
          break
        end
      end
    end

    launcher.setResults(query, rows)
  end)
end

function onActivate(id)
  if id == "action:random" then
    noctalia.runAsync("noctalia msg wallpaper-random", function()
      if noctalia.getConfig("notify_on_change") ~= false then
        noctalia.notify(tr("panel.title"), tr("notify.switched"))
      end
    end)
    return
  end

  if id == "action:next" then
    noctalia.runAsync("noctalia msg wallpaper-next", function()
      if noctalia.getConfig("notify_on_change") ~= false then
        noctalia.notify(tr("panel.title"), tr("notify.switched"))
      end
    end)
    return
  end

  if id == "action:prev" then
    noctalia.runAsync("noctalia msg wallpaper-previous", function()
      if noctalia.getConfig("notify_on_change") ~= false then
        noctalia.notify(tr("panel.title"), tr("notify.switched"))
      end
    end)
    return
  end

  if id:sub(1, 4) == "set:" then
    local path = id:sub(5)
    noctalia.runAsync("noctalia msg wallpaper-set " .. shellQuote(path), function()
      if noctalia.getConfig("notify_on_change") ~= false then
        local fname = path:match("([^/]+)$") or path
        noctalia.notify(tr("panel.title"), tr("notify.switched") .. ": " .. fname)
      end
    end)
  end
end

refreshWallpapers()
refreshCurrentWallpaper()
