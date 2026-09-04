--!nonstrict
-- Arch Packages — Bar widget

local installedCount = 0
local orphanCount = 0
local updateCount = 0
local isChecking = false

local function refreshStatus(showLoading)
  if isChecking then return end
  isChecking = true
  if showLoading then
    barWidget.setGlyph("loader-2")
    barWidget.setGlyphColor("secondary")
  end

  noctalia.runAsync("pacman -Qe | wc -l; pacman -Qtdq 2>/dev/null | wc -l; (yay -Qu --color=never 2>/dev/null || paru -Qu --color=never 2>/dev/null || pacman -Qu --color=never 2>/dev/null) | wc -l", function(result)
    isChecking = false
    if result and result.exitCode == 0 and result.stdout then
      local lines = {}
      for l in result.stdout:gmatch("[^\r\n]+") do
        table.insert(lines, l:match("^%s*(.-)%s*$"))
      end
      installedCount = tonumber(lines[1]) or 0
      orphanCount = tonumber(lines[2]) or 0
      updateCount = tonumber(lines[3]) or 0
    end

    if updateCount > 0 then
      barWidget.setGlyph("arrow-up-circle")
      barWidget.setGlyphColor("primary")
      barWidget.setText(tostring(updateCount))
    elseif orphanCount > 0 then
      barWidget.setGlyph("alert-triangle")
      barWidget.setGlyphColor("warning")
      barWidget.setText("!" .. tostring(orphanCount))
    else
      barWidget.setGlyph("package")
      barWidget.setGlyphColor("on_surface")
      barWidget.setText("")
    end

    local rows = {
      {
        key = "Arch Packages",
        value = (updateCount > 0) and (tostring(updateCount) .. " update(s) available") or "System up to date",
      },
      {
        key = "Installed",
        value = tostring(installedCount) .. " packages",
      },
    }
    if orphanCount > 0 then
      table.insert(rows, {
        key = "Orphans",
        value = tostring(orphanCount) .. " unneeded",
      })
    end
    table.insert(rows, {
      key = "Actions",
      value = "Left-click: open · Right-click: check updates",
    })

    barWidget.setTooltip(rows)
  end, 8000)
end

function update()
  refreshStatus(false)
end

function onClick()
  if updateCount > 0 then
    noctalia.runAsync("noctalia msg panel-toggle ashur-d/arch-packages:hub updates")
  else
    noctalia.togglePanel("ashur-d/arch-packages:hub")
  end
end

function onRightClick()
  refreshStatus(true)
end

barWidget.setVisible(true)
barWidget.setGlyph("package")
refreshStatus(false)
