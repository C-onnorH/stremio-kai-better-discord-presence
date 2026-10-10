# Stremio Kai Discord Presence

Shows **what you are watching** on Discord - "Watching *Dune*" instead of "Watching Stremio" - for [Stremio Kai](https://github.com/allecsc/Stremio-Kai).

- Status reads **Watching `<title>`** in the member list and DMs
- Poster as the large image, with a progress bar while playing
- Shows: episode title and season/episode, e.g. *The Ghost of Harrenhal · S2 E5*
- Movies: just the title
- **Paused** when you pause
- "View on IMDb" button
- Nothing to install or compile. Plain text files you can edit in Notepad++

> Not affiliated with Stremio, Stremio Kai, Stremio Community or Discord.

> **AI-built:** this project was written entirely by an AI (Claude, made by Anthropic) and directed by the repository owner. It has been tested by hand on one Windows PC with Stremio Kai, but it is provided as-is with no warranty and may have rough edges. Read the code before you run it - it is all plain text (Lua, JavaScript and PowerShell) - and report anything that doesn't work as an issue.

## Requirements

- Windows 10 or 11 (uses the PowerShell that ships with Windows)
- [Stremio Kai](https://github.com/allecsc/Stremio-Kai) - this is what it was built and tested with
- The Discord **desktop** app, open and logged in

Other Stremio builds are not tested. See [How it works](#how-it-works) if you want to try.

## Install

1. Close Stremio Kai completely (check the system tray).
2. Download the latest zip from [Releases](../../releases) and extract it.
3. Copy the `portable_config` folder over Kai's own `portable_config` folder and merge when asked. It only **adds** five files:
   ```
   portable_config\webmods\Discord\discord-presence-bridge.js
   portable_config\scripts\discord-presence\main.lua
   portable_config\scripts\discord-presence\discord-rpc.ps1
   portable_config\scripts\discord-presence\test-discord.bat
   portable_config\script-opts\discord_presence.conf
   ```
4. Open `portable_config\stremio-settings.ini` and change `DiscordRPC=1` to `DiscordRPC=0`. This turns off Kai's built-in "Watching Stremio" status so the two don't fight. **Do this while Kai is closed** - Kai rewrites the file when it exits.
5. Start Kai and play something.

**Check Discord first (optional):** with Discord open, double-click `test-discord.bat`. For 30 seconds your status should read "Watching Kai Test Movie".

## Updating Kai

Re-check after a Kai update: the five files may need copying back if the update replaced the folder, and `DiscordRPC` may have reset to `1`.

## Uninstall

Delete the five files above and set `DiscordRPC=1` again.

## Settings

`portable_config\script-opts\discord_presence.conf` (restart Kai after editing):

| Setting | Default | What it does |
|---|---|---|
| `enabled` | `yes` | Turn the whole thing off |
| `client_id` | *(Stremio app)* | Discord application that shows the status |
| `status_display_type` | `2` | `2` = show the title ("Watching *title*"), `0` = app name, `1` = second line |
| `show_buttons` | `yes` | "View on IMDb" button |
| `show_poster` | `yes` | Poster as the large image |
| `debug` | `no` | Extra messages in mpv's log |

### Using your own Discord application

By default the status is shown by an existing Stremio Discord application, so it works with no setup. To use your own name and icon, create an application at <https://discord.com/developers/applications> and paste its **Application ID** into `client_id`.

## Troubleshooting

- Run `test-discord.bat`. If that fails, the problem is on the Discord side (is the desktop app open?).
- The helper writes a log to `%TEMP%\kai-discord-presence.log`. If the file does not exist, the helper never started.
- Shows nothing: make sure `DiscordRPC=0` is set and Kai was restarted.
- Shows "Watching Stremio" instead of the title: Discord is ignoring `status_display_type`. The log says which version of the status it accepted.
- Title looks like a file name: the title was not in Kai's metadata yet; it falls back to a cleaned-up file name.

## Known limitations

- **While paused, Discord shows its own small elapsed counter.** It is added by Discord and cannot be hidden while a status is showing.
- Episode titles come from Stremio's public Cinemeta service. If a show is not there (some anime, obscure shows) it shows "Season X · Episode Y" instead.
- Windows only.

## How it works

Three small parts:

1. **`webmods/Discord/discord-presence-bridge.js`** - runs in Kai's page. Reads the clean title, poster and episode (from Kai's metadata, Cinemeta for episode titles) and sends them to mpv.
2. **`scripts/discord-presence/main.lua`** - runs in mpv. Tracks pause, seek, position and duration and writes what Discord should show to a small file in `%TEMP%`.
3. **`scripts/discord-presence/discord-rpc.ps1`** - a hidden PowerShell helper that keeps the connection to Discord open and sends that file's contents. It exits when Kai closes.

The mpv script and helper are generic. The web mod currently relies on two Kai internals (`RouteDetector`, `metadataHelper`); without them the title falls back to the file name. Making it work on other mpv-based Stremio builds would mean replacing those two - contributions welcome.

## Credits

- [Stremio Kai](https://github.com/allecsc/Stremio-Kai) by allecsc
- [Stremio Community](https://github.com/Zaarrg/stremio-community-v5) by Zaarrg, which Kai is built on

## Licence

[MIT](LICENSE)
