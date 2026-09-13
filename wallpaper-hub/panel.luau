--!nonstrict
-- Wallpaper Hub — Cinematic 3-card horizontal carousel wallpaper switcher

local selectedIndex = 1
local allWallpapers = {}
local currentWallpaper = ""
local isScanning = false
local scanError = nil

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

local render -- forward declaration

local function getWallpaperAt(offset)
  local total = #allWallpapers
  if total == 0 then return nil, 1 end
  local idx = ((selectedIndex - 1 + offset) % total) + 1
  return allWallpapers[idx], idx
end

local function syncSelectedIndexToActive()
  if currentWallpaper == "" or #allWallpapers == 0 then return end
  for i, wp in ipairs(allWallpapers) do
    if wp.path == currentWallpaper then
      selectedIndex = i
      return
    end
  end
end

local function refreshActiveWallpaper(callback)
  local active = getCurrentWallpaper()
  if active and active ~= "" then
    currentWallpaper = active
    if callback then callback() end
    return
  end

  noctalia.runAsync("noctalia msg wallpaper-get", function(result)
    if result and result.exitCode == 0 and result.stdout then
      currentWallpaper = result.stdout:gsub("%s+$", "")
    end
    if callback then callback() end
  end, 1500)
end

local function loadWallpapers(forceRescan)
  if not forceRescan and #allWallpapers > 0 then
    local active = getCurrentWallpaper()
    if active and active ~= "" then
      currentWallpaper = active
      syncSelectedIndexToActive()
    end
    render()
    return
  end

  isScanning = true
  scanError = nil
  local dir = getWallpaperDir()
  local list = {}

  scanDirRecursive(dir, list, 0)

  if #list == 0 then
    local cmd = "find " .. shellQuote(dir) .. " -type f \\( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' \\) 2>/dev/null | sort -V"
    noctalia.runAsync(cmd, function(result)
      isScanning = false
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
        allWallpapers = fallbackList
      else
        allWallpapers = {}
        scanError = tr("panel.empty")
      end
      refreshActiveWallpaper(function()
        syncSelectedIndexToActive()
        render()
      end)
    end, 4000)
  else
    table.sort(list, function(a, b)
      return a.sortKey < b.sortKey
    end)
    allWallpapers = list
    isScanning = false
    refreshActiveWallpaper(function()
      syncSelectedIndexToActive()
      render()
    end)
  end
end

local function applyWallpaper(path)
  currentWallpaper = path
  render()

  -- Instant in-process application without subprocess latency
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

local function applyRandom()
  if #allWallpapers == 0 then return end
  local randIdx = math.random(1, #allWallpapers)
  selectedIndex = randIdx
  applyWallpaper(allWallpapers[randIdx].path)
end

local function stepSelection(delta)
  local total = #allWallpapers
  if total == 0 then return end
  selectedIndex = ((selectedIndex - 1 + delta) % total) + 1
  render()
end

render = function()
  if isScanning then
    panel.render(ui.column({
      align = "center",
      justify = "center",
      flexGrow = 1,
      gap = 12,
      padding = 40,
    }, {
      ui.glyph({ name = "loader-2", size = 36, color = "primary" }),
      ui.label({ text = tr("panel.loading"), fontSize = 14, color = "on_surface_variant" }),
    }))
    return
  end

  if #allWallpapers == 0 then
    local dir = getWallpaperDir()
    panel.render(ui.column({
      align = "center",
      justify = "center",
      flexGrow = 1,
      gap = 12,
      padding = 40,
    }, {
      ui.glyph({ name = "photo-off", size = 48, color = "on_surface_variant" }),
      ui.label({ text = tr("panel.empty"), fontSize = 15, fontWeight = "bold", color = "on_surface" }),
      ui.label({ text = tr("panel.empty_hint"), fontSize = 13, color = "on_surface_variant" }),
      ui.label({ text = dir, fontSize = 11, color = "outline" }),
    }))
    return
  end

  local wpLeft, idxLeft = getWallpaperAt(-1)
  local wpCenter, idxCenter = getWallpaperAt(0)
  local wpRight, idxRight = getWallpaperAt(1)

  local isCenterActive = (wpCenter.path == currentWallpaper)

  -- Cinematic 3-Card Carousel
  local carouselRow = ui.row({
    align = "center",
    justify = "center",
    gap = 20,
    flexGrow = 1,
  }, {
    -- Previous Wallpaper Preview (Left)
    ui.column({
      align = "center",
      width = 280,
      opacity = 0.55,
      onClick = function()
        selectedIndex = idxLeft
        render()
      end,
    }, {
      ui.image({
        path = wpLeft.path,
        width = 280,
        height = 158,
        fit = "cover",
        radius = 12,
        borderWidth = (wpLeft.path == currentWallpaper) and 2 or 0,
        border = (wpLeft.path == currentWallpaper) and "primary" or nil,
      }),
    }),

    -- Current Focused Wallpaper (Center Spotlight)
    ui.column({
      align = "center",
      width = 460,
      onClick = function()
        applyWallpaper(wpCenter.path)
      end,
    }, {
      ui.image({
        path = wpCenter.path,
        width = 460,
        height = 259,
        fit = "cover",
        radius = 16,
        borderWidth = isCenterActive and 3 or 1,
        border = isCenterActive and "primary" or "outline",
      }),
    }),

    -- Next Wallpaper Preview (Right)
    ui.column({
      align = "center",
      width = 280,
      opacity = 0.55,
      onClick = function()
        selectedIndex = idxRight
        render()
      end,
    }, {
      ui.image({
        path = wpRight.path,
        width = 280,
        height = 158,
        fit = "cover",
        radius = 12,
        borderWidth = (wpRight.path == currentWallpaper) and 2 or 0,
        border = (wpRight.path == currentWallpaper) and "primary" or nil,
      }),
    }),
  })

  -- Info & Controls Section below cards
  local infoSection = ui.column({
    align = "center",
    gap = 4,
  }, {
    -- Active badge row
    ui.row({
      align = "center",
      justify = "center",
      height = 22,
    }, {
      isCenterActive and ui.row({
        align = "center",
        gap = 4,
        paddingH = 8,
        paddingV = 2,
        radius = 10,
        fill = "primary/0.2",
      }, {
        ui.glyph({ name = "check", size = 13, color = "primary" }),
        ui.label({ text = tr("panel.active"), fontSize = 10, fontWeight = "bold", color = "primary" }),
      }) or nil,
    }),

    -- Index counter
    ui.label({
      text = tostring(idxCenter) .. " / " .. tostring(#allWallpapers),
      fontSize = 12,
      color = "on_surface_variant",
    }),

    -- Navigation hints
    ui.label({
      text = tr("panel.hint"),
      fontSize = 11,
      color = "on_surface_variant",
    }),
  })

  panel.render(ui.column({
    padding = 24,
    gap = 14,
    align = "stretch",
    flexGrow = 1,
  }, {
    carouselRow,
    infoSection,
  }))
end

function onKey(chord, pressed)
  if not pressed then return end

  if chord == "Left" or chord == "Up" then
    stepSelection(-1)
  elseif chord == "Right" or chord == "Down" then
    stepSelection(1)
  elseif chord == "PageUp" then
    stepSelection(-5)
  elseif chord == "PageDown" then
    stepSelection(5)
  elseif chord == "Home" then
    if #allWallpapers > 0 then
      selectedIndex = 1
      render()
    end
  elseif chord == "End" then
    if #allWallpapers > 0 then
      selectedIndex = #allWallpapers
      render()
    end
  elseif chord == "Return" then
    if #allWallpapers > 0 and selectedIndex >= 1 and selectedIndex <= #allWallpapers then
      applyWallpaper(allWallpapers[selectedIndex].path)
    end
  elseif chord == "Space" or chord == "r" or chord == "R" then
    applyRandom()
  elseif chord == "F5" then
    loadWallpapers(true)
  elseif chord == "Escape" then
    panel.close()
  end
end

function onScroll(axis, steps, startsGesture)
  if axis ~= "vertical" or startsGesture then return end
  if #allWallpapers == 0 then return end

  if (steps or 0) > 0 then
    stepSelection(1)
  else
    stepSelection(-1)
  end
end

function onOpen(_context)
  local active = getCurrentWallpaper()
  if active and active ~= "" then
    currentWallpaper = active
    syncSelectedIndexToActive()
  end

  -- If we already have wallpapers in memory, render immediately with 0ms delay!
  if #allWallpapers > 0 then
    render()
  else
    loadWallpapers(false)
  end
end

function onClose()
end

-- Warm up cache immediately upon plugin script load
loadWallpapers(false)
