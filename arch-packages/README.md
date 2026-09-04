# Arch Packages

A native Arch Linux and AUR package installer, remover, and manager for Noctalia, featuring an interactive search hub, installed package manager, orphan cleaner, launcher provider, and status bar widget.

## Plugin

| Field | Value |
| --- | --- |
| ID | `ashur-d/arch-packages` |
| Entries | Panel: `hub`; launcher providers: `provider`, `update`; bar widget: `widget`; shortcut: `toggle` |
| Launcher Prefix | `/pkg`, `/update` |

## Requirements

This plugin requires:
- `pacman` (required): The native Arch Linux package manager for querying sync databases and managing installed packages.
- `yay` or `paru` (optional): For searching and installing packages from the Arch User Repository (AUR).

## Usage

Arch Packages provides comprehensive package management tailored for Arch Linux and Arch-based distributions:

### Interactive Hub Panel

Open the floating package hub panel or bind it to a custom compositor shortcut:

```sh
noctalia msg panel-toggle ashur-d/arch-packages:hub
```

- **Explore & Search**: Search packages across official Arch repositories (`core`, `extra`, `multilib`) and the AUR via `yay`, `paru`, or `pacman`.
- **Installed Manager**: View and search all explicitly installed packages with version and size details.
- **Orphan Cleaner**: Detect unused orphaned dependencies and clean them with a single click (`pacman -Rns $(pacman -Qtdq)`).
- **Package Details**: Inspect licenses, dependencies, packager, installed size, and open project URLs directly in your browser.
- **Safe Terminal Execution**: Installations and removals run inside your terminal emulator, ensuring `sudo` authentication, dependency confirmation, and download progress are completely transparent.

### Launcher Provider

Search and install packages directly from the Noctalia Launcher:

- Type `/pkg` to view quick actions: Open Hub, Full System Upgrade (`yay -Syu`), and Clean Orphans.
- Type `/pkg <query>` (e.g. `/pkg ripgrep` or `/pkg neovim`) to search repositories and the AUR.
- Press **Enter** on any result to install or manage it in terminal.

### Bar Widget

Add the `widget` entry to your Noctalia bar:
- **Left click**: Toggles the Arch Packages hub (opens directly to pending updates if updates are available).
- **Right click**: Refreshes package update and orphan status.
- **Badge & Tooltip**: Displays total installed packages count, update count, and warns if orphans are present.

### Shortcut

Add the `toggle` shortcut to your Control Center or compositor keybindings to toggle the panel on demand.

## Settings

Configure Arch Packages in **Settings -> Plugins -> Arch Packages**:

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `aur_helper` | `select` | `auto` | Preferred package manager helper (`auto`, `yay`, `paru`, `pacman`). |
| `use_terminal` | `bool` | `false` | Run operations in an interactive terminal window instead of Polkit background mode. |
| `terminal_cmd` | `string` | *(empty)* | Optional terminal command override (leave empty to use default terminal). |
| `notify_on_action` | `bool` | `true` | Send a desktop notification when an install or remove action finishes. |

## License

MIT
