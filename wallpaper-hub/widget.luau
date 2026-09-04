--!nonstrict
-- Wallpaper Hub — Bar widget

local function tr(key, args)
  return noctalia.tr(key, args)
end

local function updateTooltip()
  noctalia.runAsync("noctalia msg wallpaper-get", function(result)
    local current = ""
    if result and result.exitCode == 0 and result.stdout then
      local path = result.stdout:gsub("%s+$", "")
      current = path:match("([^/]+)$") or path
    end
    local tooltip = tr("widget.tooltip")
    if current ~= "" then
      tooltip = current .. "\n\n" .. tooltip
    end
    barWidget.setTooltip(tooltip)
  end, 2000)
end

function update()
  barWidget.setGlyph("image")
  updateTooltip()
end

function onClick()
  noctalia.togglePanel("ashur-d/wallpaper-hub:hub")
end

function onRightClick()
  noctalia.runAsync("noctalia msg wallpaper-random", function()
    if noctalia.getConfig("notify_on_change") ~= false then
      noctalia.notify(tr("panel.title"), tr("notify.switched"))
    end
    updateTooltip()
  end)
end

function onScroll(axis, steps, startsGesture)
  if axis ~= "vertical" or startsGesture then return end
  if (steps or 0) > 0 then
    noctalia.runAsync("noctalia msg wallpaper-next", function()
      updateTooltip()
    end)
  else
    noctalia.runAsync("noctalia msg wallpaper-previous", function()
      updateTooltip()
    end)
  end
end

barWidget.setGlyph("image")
updateTooltip()
