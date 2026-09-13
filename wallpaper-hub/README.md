# Wallpaper Hub

A cinematic horizontal wallpaper switcher carousel, quick launcher provider, and interactive bar widget for Noctalia.

## Plugin

| Field | Value |
| --- | --- |
| ID | `ashur-d/wallpaper-hub` |
| Entries | Panel: `hub`; launcher provider: `provider`; bar widget: `widget`; shortcut: `toggle` |
| Launcher Prefix | `/wall` |

## Usage

Wallpaper Hub provides three convenient ways to browse and switch your desktop wallpapers:

### Visual Carousel Panel

Open the floating carousel panel directly or bind it to a custom compositor keybind:

```sh
noctalia msg panel-toggle ashur-d/wallpaper-hub:hub
```

- **Cinematic Carousel**: Focus on your wallpapers with an active center spotlight card and adjacent previews.
- **Active Indicator**: The currently active wallpaper is highlighted with a primary accent border and active badge.
- **Fast Keyboard Navigation**: Browse with arrow keys (`Left` / `Right` / `Up` / `Down`), and apply with `Enter`.
- **Quick Actions**: Press `Space` or `r` to instantly apply a random wallpaper, or `F5` to rescan.
- **Instant Switch**: Uses in-process wallpaper switching for seamless transitions with zero latency.

### Launcher Provider

Type `/wall` in the Noctalia launcher:
- An empty query displays quick switcher actions: Random Wallpaper, Next Wallpaper, and Previous Wallpaper, followed by your wallpaper catalog.
- Type `/wall <query>` to instantly fuzzy-match and filter wallpapers by name.
- Press **Enter** on any result to apply that wallpaper immediately.

### Bar Widget

Add the `widget` entry to your Noctalia bar:
- **Left click**: Toggles the Wallpaper Hub carousel panel.
- **Right click**: Immediately picks and applies a random wallpaper.
- **Scroll wheel up / down**: Cycles to the next or previous wallpaper.
- **Tooltip**: Displays the currently active wallpaper filename and control tips.

### Control Center Shortcut

Add the `toggle` shortcut to your Control Center to toggle the hub panel with a single click.

### Performance & Background Thumbnail Caching

Wallpaper Hub automatically generates and caches downscaled 512x288 thumbnails in `~/.cache/noctalia/wallpaper-hub/thumbnails/` for buttery-smooth 60 FPS carousel navigation:
- **Low-Priority Background Processing**: Runs thumbnail jobs in the background with `nice -n 19` so your desktop compositor and user input never hitch.
- **Auto-Detection**: Automatically detects `magick` (ImageMagick 7), `convert` (ImageMagick 6), or `ffmpeg`.
- **Graceful Fallback**: If none of these image utilities are installed, Wallpaper Hub falls back to original wallpaper files with zero required dependencies.

## Settings

Configure Wallpaper Hub in **Settings -> Plugins -> Wallpaper Hub**:

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `wallpaper_dir` | `folder` | *(empty)* | Path to your wallpapers directory. Leave empty to automatically use Noctalia's configured wallpaper folder. |
| `notify_on_change` | `bool` | `true` | Send a desktop notification whenever the wallpaper is switched. |

## License

MIT
