# Wallpaper Hub

A visual wallpaper switcher hub featuring a 4-column thumbnail grid, quick launcher provider, and interactive bar widget.

## Plugin

| Field | Value |
| --- | --- |
| ID | `ashur-d/wallpaper-hub` |
| Entries | Panel: `hub`; launcher provider: `provider`; bar widget: `widget`; shortcut: `toggle` |
| Launcher Prefix | `/wall` |

## Usage

Wallpaper Hub provides three convenient ways to browse and switch your desktop wallpapers:

### Visual Grid Panel

Open the floating grid panel directly or bind it to a custom compositor keybind:

```sh
noctalia msg panel-toggle ashur-d/wallpaper-hub:hub
```

- **Thumbnail Grid**: Browse 16:9 thumbnails of all your local wallpapers.
- **Active Indicator**: The currently active wallpaper is highlighted with a primary border and checkmark badge.
- **Search Bar**: Type to quickly filter wallpapers by name as you type.
- **Actions**: Quick buttons for Random (🎲), Next (➡), Previous (⬅), and Refresh (🔄).
- **Instant Switch**: Click any card to apply the wallpaper immediately. Noctalia automatically transitions and recalculates Material You M3 palettes.

### Launcher Provider

Type `/wall` in the Noctalia launcher:
- An empty query displays quick switcher actions: Random Wallpaper, Next Wallpaper, and Previous Wallpaper, followed by your wallpaper catalog.
- Type `/wall <query>` to fuzzy match and filter wallpapers by name.
- Press **Enter** on any result to apply that wallpaper.

### Bar Widget

Add the `widget` entry to your Noctalia bar:
- **Left click**: Toggles the Wallpaper Hub panel.
- **Right click**: Immediately picks and applies a random wallpaper.
- **Scroll wheel up / down**: Cycles to the next or previous wallpaper.
- **Tooltip**: Displays the currently active wallpaper filename and control tips.

### Control Center Shortcut

Add the `toggle` shortcut to your Control Center to toggle the hub panel with a single click.

## Settings

Configure Wallpaper Hub in **Settings -> Plugins -> Wallpaper Hub**:

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `wallpaper_dir` | `folder` | *(empty)* | Path to your wallpapers directory. Leave empty to automatically use Noctalia's configured wallpaper folder. |
| `notify_on_change` | `bool` | `true` | Send a desktop notification whenever the wallpaper is switched. |

## License

MIT
