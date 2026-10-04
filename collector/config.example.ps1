# ============================================================
#  406 Dragonwilds Dashboard collector - configuration
#  Copy this file to  config.ps1  and edit. config.ps1 is
#  gitignored. (No passwords needed: Dragonwilds has no RCON,
#  the collector just reads the server's files on this PC.)
# ============================================================
$Config = @{
  # Where the server lives (the folder with run_dragonwilds_server.bat)
  ServerRoot = "C:\DragonwildsServer"

  # --- Shown on the dashboard ---
  ServerName = "406 Dragonwilds"
  World      = "406 Dragonwilds"
  MaxPlayers = 6

  # --- Publish (leave $false until git + GitHub Pages are wired up; see README) ---
  Push       = $false
}
