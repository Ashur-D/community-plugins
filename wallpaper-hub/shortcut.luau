--!nonstrict
-- Wallpaper Hub — Shortcut tile for toggling the hub

shortcut.setLabel("Wallpaper Hub")
shortcut.setIcon("image")

function onClick()
  noctalia.togglePanel("ashur-d/wallpaper-hub:hub")
end
