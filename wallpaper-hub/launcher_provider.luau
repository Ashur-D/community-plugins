--!nonstrict
-- Wallpaper Hub — Instant Launcher provider for quick wallpaper switching (/wall)

local cachedWallpapers = {}
local currentWallpaper = ""

local function tr(key, args)
  return noctalia.tr(key, args)
end

local function shellQuote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function makeSortKey(s)
  local lower = s:lower()
  return lower:gsub("%d+", function(n)
    return string.format("%08d", tonumber(n) or 0)
  end)
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
  local home = noctalia.getenv("HOME") or "~"
  return home .. "/Pictures/wallpapers"
end

local function isImage(name)
  local lower = name:lower()
  return lower:match("%.png$") ~= nil
      or lower:match("%.jpg$") ~= nil
      or lower:match("%.jpeg$") ~= nil
      or lower:match("%.webp$") ~= nil
end

local function getCurrentWallpaper()
  if noctalia.wallpaperPath then
    local out = noctalia.focusedOutputName and noctalia.focusedOutputName()
    if out then
      local path = noctalia.wallpaperPath(out)
      if path and path ~= "" then return path end
    end
    if noctalia.outputs then
      for _, o in ipairs(noctalia.outputs()) do
        if o.name then
          local path = noctalia.wallpaperPath(o.name)
          if path and path ~= "" then return path end
        end
      end
    end
  end
  return nil
end

local function scanDirRecursive(dir, list, depth)
  if depth > 2 then return end
  local entries = noctalia.listDir(dir)
  if not entries then return end

  for _, name in ipairs(entries) do
    if name ~= "." and name ~= ".." and not name:match("^%.") then
      local fullPath = dir .. "/" .. name
      if isImage(name) then
        local cleanName = name:gsub("%.%w+$", "")
        table.insert(list, {
          path = fullPath,
          name = cleanName,
          filename = name,
          sortKey = makeSortKey(cleanName),
        })
      else
        local info = noctalia.fileInfo(fullPath)
        if info and info.isDir then
          scanDirRecursive(fullPath, list, depth + 1)
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
            sortKey = makeSortKey(cname),
          })
        end
        cachedWallpapers = fallbackList
      end
    end, 3000)
  else
    table.sort(list, function(a, b)
      return a.sortKey < b.sortKey
    end)
    cachedWallpapers = list
  end
end

local function applyWallpaper(path)
  currentWallpaper = path
  if noctalia.setWallpaper then
    noctalia.setWallpaper(path)
  else
    noctalia.runAsync("noctalia msg wallpaper-set " .. shellQuote(path))
  end

  if noctalia.getConfig("notify_on_change") ~= false then
    local fname = path:match("([^/]+)$") or path
    noctalia.notify(tr("panel.title"), tr("notify.switched") .. ": " .. fname)
  end
end

function onQuery(query)
  local text = query:gsub("^%s+", ""):gsub("%s+$", ""):lower()

  local active = getCurrentWallpaper()
  if active and active ~= "" then
    currentWallpaper = active
  end

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
  local maxResults = (text == "") and 8 or 20

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

  -- Return results synchronously for zero input lag!
  launcher.setResults(query, rows)
end

function onActivate(id)
  if id == "action:random" then
    if #cachedWallpapers > 0 then
      local rand = cachedWallpapers[math.random(1, #cachedWallpapers)]
      applyWallpaper(rand.path)
    else
      noctalia.runAsync("noctalia msg wallpaper-random")
    end
    return
  end

  if id == "action:next" then
    if #cachedWallpapers > 0 then
      local currentIdx = 1
      for i, wp in ipairs(cachedWallpapers) do
        if wp.path == currentWallpaper then
          currentIdx = i
          break
        end
      end
      local nextIdx = (currentIdx % #cachedWallpapers) + 1
      applyWallpaper(cachedWallpapers[nextIdx].path)
    else
      noctalia.runAsync("noctalia msg wallpaper-next")
    end
    return
  end

  if id == "action:prev" then
    if #cachedWallpapers > 0 then
      local currentIdx = 1
      for i, wp in ipairs(cachedWallpapers) do
        if wp.path == currentWallpaper then
          currentIdx = i
          break
        end
      end
      local prevIdx = ((currentIdx - 2 + #cachedWallpapers) % #cachedWallpapers) + 1
      applyWallpaper(cachedWallpapers[prevIdx].path)
    else
      noctalia.runAsync("noctalia msg wallpaper-previous")
    end
    return
  end

  if id:sub(1, 4) == "set:" then
    local path = id:sub(5)
    applyWallpaper(path)
  end
end

refreshWallpapers()
local initActive = getCurrentWallpaper()
if initActive and initActive ~= "" then
  currentWallpaper = initActive
end
