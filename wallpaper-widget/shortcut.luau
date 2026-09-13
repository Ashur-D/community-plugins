--!nonstrict
-- Wallpaper Widget — Shortcut tile for toggling the hub

shortcut.setLabel("Wallpaper Widget")
shortcut.setIcon("image")

function onClick()
  noctalia.togglePanel("ashur-d/wallpaper-widget:hub")
end
