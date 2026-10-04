# The 406 Dragonwilds: live dashboard

A self-updating, gold-and-sparkles web dashboard for the **406 Dragonwilds** server
(RuneScape: Dragonwilds). It's the sister of the ARK "Saga of 406" dashboard and works the same
way: a collector on the server PC, a `data.json` pushed to GitHub, and a page on GitHub Pages.

**What's on it**

| Section | Where the data comes from |
|---|---|
| Live status, who's online, uptime | server process + join/leave lines in the server log |
| The Ledger, Hall of Honours (Most Devoted, Marathon Delver, Night Owl, Early Riser) | play sessions rebuilt from the log |
| Adventurers' Roll | hours / visits / last seen per player |
| When the Realm Wakes | weekday × hour heatmap of play time (viewer's local time) |
| The Chronicle | first boot, patches, crashes, first arrivals, hour milestones, record sessions |
| Heart of the Server | uptime %, days without a crash, RAM + players-online charts (7 days) |
| The Vault | `..\Backups\Saves_*` folders and world-save stats |
| Skills of the Realm + Deeds | every character's JSON inside the world `.sav`: skill XP → levels, recipes, unique foes slain, landmarks, quests, spells, journal, playtime |
| Grand Sage / Slayer honours, level-up milestones in the Chronicle | same character data (milestones every 10 levels and at 99) |
| Trophy Hall: 100 trophies (56 bronze, 34 silver, 9 gold, 1 platinum), points, rarity, hidden trophies | `trophies.json` definitions, evaluated by the collector from sessions + character stats; unlocks are permanent and time-stamped in `state.json` |
| Bosses Felled, Gravestones | **sealed for now**, see below |

## Trophies

All 100 live in [`trophies.json`](trophies.json), which both the collector and the page read. Each one is `{ id, tier, cat, name, desc, stat, min }`: it unlocks when the player's `stat` reaches `min`. The platinum (`stat: "allTrophies"`) unlocks when every other trophy is earned. `hidden: true` hides the name until it's earned. Points are PlayStation's: bronze 15, silver 30, gold 90, platinum 300.

Available stats: `hours`, `visits`, `longest`, `night`, `dawn`, `weekend`, `midnights`, `sunrise`, `days`, `streak`, `returned`, `first`, `coop`, `party`, `crash`, `patch`, `lvl.<Skill>`, `total`, `minLevel`, `recipes`, `buildings`, `spells`, `foes`, `landmarks`, `shrines`, `burrows`, `quests`, `journal`, `mounts`. Add or edit trophies freely; an unlock is never taken back.

**Characters live on each player's PC.** The server only has a character in its save while that player is online, so the collector reads both the current save and `.sav.backup` every 5 minutes and keeps the newest snapshot of each character in `state.json`.

## How it works

Dragonwilds has **no RCON**, so the collector doesn't talk to the server. It reads what the server
leaves on disk:

```
RSDragonwilds*.log ─┐
server process  ────┼─► collector\collect.ps1 ─► data.json ─► git push ─► GitHub Pages ─► index.html
SaveGames\*.sav ────┤        (every 5 min)         (state.json keeps the history)
..\Backups\ ────────┘
```

The game rotates and eventually deletes its own logs, so everything is accumulated in
`collector\state.json`. Don't delete that file: it is the long-term history.

## Preview it on this PC

```powershell
powershell -ExecutionPolicy Bypass -File C:\DragonwildsServer\Dashboard\serve.ps1
```
Open <http://localhost:8406/> for the real data, or <http://localhost:8406/?demo> for sample data
(`collect.ps1 -Offline` regenerates `data.sample.json`).

## One-time setup

1. **Create the GitHub repo.** For example `cgbeaulieu/dragonwilds-406-dashboard`, the same way as
   `ark-406-dashboard`.
2. **Push this folder.**
   ```powershell
   cd C:\DragonwildsServer\Dashboard
   git add -A; git commit -m "406 Dragonwilds dashboard"
   git remote add origin https://github.com/cgbeaulieu/dragonwilds-406-dashboard.git
   git push -u origin main
   ```
3. **Let the collector push.** Make a fine-grained token scoped to just this repo with
   *Contents: Read and write*. Store it only in the local remote URL:
   ```powershell
   git remote set-url origin https://cgbeaulieu:PASTE_TOKEN@github.com/cgbeaulieu/dragonwilds-406-dashboard.git
   ```
4. **Turn on Pages.** Repo → Settings → Pages → Deploy from a branch → `main` / root.
5. **Config.** `Copy-Item collector\config.example.ps1 collector\config.ps1`, then set `Push = $true`.
6. **Schedule it.** Run `collector\install-collector-task.ps1`. It registers
   **"406 Dragonwilds Dashboard Collector"** every 5 minutes (it pushes at most every ~10), with absolute paths and "Start in"
   set, so it avoids the ARK task's `0xFFFD0000` problem.

## Collector switches

| Command | What it does |
|---|---|
| `collect.ps1` | Normal run: read logs, process, saves and backups; write `data.json`; push if `Push = $true` |
| `collect.ps1 -NoPush` | Same, but never pushes |
| `collect.ps1 -Offline` | Writes sample data to `data.sample.json` for `?demo` |
| `collect.ps1 -TestLog <file>` | Parses one log and prints the joins, leaves, saves and build it found. Use this for tuning |
| `collect.ps1 -Rebuild` | Forgets parsed log history and re-reads every log still on disk (keeps RAM samples) |

## Things to tune after the first real play session

Joins, leaves and characters were verified against a real session (Soop, 2026-10-03). The rest:

- **Joins and leaves (working).** The parser reads standard Unreal Engine lines: `LogNet: Login request: ?Name=…
  userId: …`, `LogNet: Join succeeded: <name>` and `UNetConnection::Close … UniqueId: …`. If a join is ever missed, look at `collector\unparsed.log`. Any line that looks like a
  join, leave, death or kill and didn't parse gets copied there once.
- **Characters and skills (working).** Each character that has played the world is stored in the
  world `.sav` as a JSON string (`{"Version":..,"meta_data":{"char_name":..}, "GameProgress":{..}}`).
  Skills are listed by internal ID. The ID→name map and the XP table come from the community save
  editors (e.g. [OogaBoogaCode/RSDWSaveEditor](https://github.com/OogaBoogaCode/RSDWSaveEditor)). If a
  game patch adds a skill, add its ID to `$SkillIds` in `collect.ps1`.
- **Bosses and gravestones (not yet).** The world save has `DefeatedBossesInternalNames` and a
  `PlayerGraveyard`, but these are in Jagex's binary property format, not JSON. On its first run the
  collector snapshots the fresh world's readable strings (`collectorsave-baseline.txt`). Each later
  run writes the strings that are **new** since then to `collectorsave-strings.txt`. After a boss
  kill or a death, that file shows what to wire up. Any death-looking log lines also land in
  `unparsed.log`.
- **"Unclean stops"** counts any run whose log doesn't end with `Engine exit requested`. That means real
  crashes *and* closing the server window. Use `stop_server.bat` to keep the count honest.
