<#
============================================================
  406 Dragonwilds Dashboard collector
  Runs on the SERVER PC (Task Scheduler, every 10 minutes).

  Dragonwilds has no RCON, so instead of asking the server we
  read what it leaves on disk:
    - RSDragonwilds*.log  -> joins/leaves, boots, clean stops,
                             crashes, world saves, game build
    - the server process  -> up/down, RAM, uptime
    - SaveGames\*.sav     -> world save size / last save
    - ..\Backups\Saves_*  -> the backup vault
  Everything is accumulated in state.json (logs get rotated and
  pruned by the game) and published as ..\data.json.

  Switches:
    -NoPush      write data.json but don't git push
    -Offline     write sample data to data.sample.json (page: ?demo)
    -Rebuild     forget parsed history and re-read every log on disk
    -TestLog <f> parse one log file and print joins/leaves (no state change)
============================================================
#>
param(
  [switch]$Offline,
  [switch]$NoPush,
  [switch]$Rebuild,
  [string]$TestLog    # parse one saved log file and print what it finds (for tuning)
)
$ErrorActionPreference = "Stop"
$Here      = $PSScriptRoot
$Root      = Split-Path -Parent $Here                 # the Dashboard folder (git repo)
$DataFile  = Join-Path $Root "data.json"
$StateFile = Join-Path $Here "state.json"
$Unparsed  = Join-Path $Here "unparsed.log"
$SaveProbe = Join-Path $Here "save-strings.txt"
$SaveBase  = Join-Path $Here "save-baseline.txt"

# ---------------- config ----------------
$Config = @{
  ServerRoot = "C:\DragonwildsServer"
  ServerName = "406 Dragonwilds"
  World      = "406 Dragonwilds"
  MaxPlayers = 6
  Push       = $false
}
$cfgPath = Join-Path $Here "config.ps1"
if (Test-Path $cfgPath) { . $cfgPath }

$Game     = Join-Path $Config.ServerRoot "steamcmd\steamapps\common\RuneScape Dragonwilds Dedicated Server\RSDragonwilds"
$LogDir   = Join-Path $Game "Saved\Logs"
$SaveDir  = Join-Path $Game "Saved\SaveGames"
$Backups  = Join-Path $Config.ServerRoot "Backups"
$ProcName = "RSDragonwildsServer-Win64-Shipping"
$KeepSamplesDays = 7

function Iso([datetime]$d) { $d.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ") }
function UnixMs([datetime]$d) { [DateTimeOffset]::new($d.ToUniversalTime()).ToUnixTimeMilliseconds() }
function AsList($x) { $l = New-Object System.Collections.ArrayList; if ($x) { foreach ($i in $x) { [void]$l.Add($i) } }; return ,$l }
function ToHash($o) { $h = @{}; if ($o) { foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = $p.Value } }; return $h }
# Total XP needed for each level (Dragonwilds experience table); index = level.
$XpTable = @($null,0,33,70,111,156,206,261,322,389,463,545,636,736,847,969,1104,1253,1417,1598,1798,2018,2261,2529,2825,3152,3512,3910,4349,4833,5367,5957,6608,7326,8118,8993,9958,11023,12199,13496,14929,16510,18255,20181,22307,24654,27245,30105,33262,36747,40594,44581,48717,52997,57421,61990,66702,71560,76562,81708,86998,92433,98012,103735,109603,115616,121772,128073,134518,141108,147842,154721,161743,168910,176222,183678,191278,199022,206911,214944,223122,231444,239910,248521,257276,266176,275219,284407,293740,303217,312838,322604,332514,342568,395129,447689,543044,666881,819200,1000000)
function Level([double]$xp) { $l = 1; for ($n = 2; $n -le 99; $n++) { if ($xp -ge $XpTable[$n]) { $l = $n } }; return $l }


# ================= trophies =================
# Definitions live in ..\trophies.json (shared with the page). Stats are computed per player
# from play sessions (log) and their character (world save); a trophy unlocks when
# stat >= min and is never taken back. Platinum = every other trophy.
$TrophyFile = Join-Path $Root "trophies.json"
function ParseIso([string]$s) { [datetime]::Parse($s, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime() }

function Get-PlayerStats($sessions, $characters, $events, $charOf) {
  $nowL = Get-Date
  $Sess = @(@(foreach ($s in $sessions) {
    $a = ParseIso $s.start
    $b = if ($s.end) { ParseIso $s.end } else { $nowL }
    if ($b -lt $a) { $b = $a }
    [pscustomobject]@{ who=[string]$s.who; a=$a; b=$b }
  }) | Sort-Object a)
  $crashes = @($events | Where-Object { $_.kind -eq "crash" } | ForEach-Object { ParseIso $_.t })
  $patchDays = @{}; $prevB = ""
  foreach ($e in @($events | Where-Object { $_.kind -eq "start" -and $_.note } | Sort-Object { $_.t })) {
    if ($prevB -and $e.note -ne $prevB) { $patchDays[(ParseIso $e.t).ToString("yyyy-MM-dd")] = 1 }
    $prevB = $e.note
  }
  $Pl = [ordered]@{}
  foreach ($s in $Sess) {
    if (-not $Pl.Contains($s.who)) { $Pl[$s.who] = @{ hours=0.0; visits=0; longest=0.0; night=0.0; dawn=0.0; weekend=0.0; midnights=0; sunrise=0; days=@{}; returned=0; first=0; coop=0.0; party=0; crash=0; patch=0; lastB=$null } }
    $p = $Pl[$s.who]
    $len = ($s.b - $s.a).TotalHours
    $p.hours += $len; $p.visits++; if ($len -gt $p.longest) { $p.longest = $len }
    if ($p.lastB -and ($s.a - $p.lastB).TotalDays -ge 14) { $p.returned = 1 }
    if (-not $p.lastB -or $s.b -gt $p.lastB) { $p.lastB = $s.b }
    if ($s.a.Date -ne $s.b.Date) { $p.midnights++ }
    if ($s.b -ge $s.a.Date.AddDays(1).AddHours(6)) { $p.sunrise = 1 }
    $c = $s.a; $guard = 0
    while ($c -lt $s.b -and $guard++ -lt 20000) {
      $nx = $c.Date.AddHours($c.Hour + 1); $e = if ($nx -lt $s.b) { $nx } else { $s.b }
      $h = $c.Hour; $part = ($e - $c).TotalHours
      if ($h -ge 23 -or $h -lt 4) { $p.night += $part }
      if ($h -ge 5 -and $h -lt 9) { $p.dawn += $part }
      if ($c.DayOfWeek -eq 'Saturday' -or $c.DayOfWeek -eq 'Sunday') { $p.weekend += $part }
      $p.days[$c.ToString("yyyy-MM-dd")] = 1
      $c = $e
    }
    foreach ($t in $crashes) { if ($s.a -le $t -and $s.b -ge $t.AddSeconds(-1)) { $p.crash = 1 } }
    # time spent alongside others, and the biggest party seen
    $ov = @(); foreach ($q in $Sess) { if ($q.who -ne $s.who -and $q.a -lt $s.b -and $q.b -gt $s.a) { $ov += ,$q } }
    if ($ov.Count) {
      $iv = @($ov | ForEach-Object { [pscustomobject]@{ a=$(if ($_.a -gt $s.a) { $_.a } else { $s.a }); b=$(if ($_.b -lt $s.b) { $_.b } else { $s.b }) } } | Sort-Object a)
      $ca = $iv[0].a; $cb = $iv[0].b; $tot = 0.0
      foreach ($x in $iv) { if ($x.a -le $cb) { if ($x.b -gt $cb) { $cb = $x.b } } else { $tot += ($cb - $ca).TotalHours; $ca = $x.a; $cb = $x.b } }
      $tot += ($cb - $ca).TotalHours; $p.coop += $tot
      foreach ($pt in (@($s.a) + @($iv | ForEach-Object { $_.a }))) {
        $here = @{ $s.who = 1 }; foreach ($q in $ov) { if ($q.a -le $pt -and $q.b -gt $pt) { $here[$q.who] = 1 } }
        if ($here.Count -gt $p.party) { $p.party = $here.Count }
      }
    } elseif ($p.party -lt 1) { $p.party = 1 }
  }
  if ($Sess.Count) { $Pl[$Sess[0].who].first = 1 }
  # attach characters (by login -> character name), and list characters nobody claimed
  $byName = @{}; foreach ($c in $characters) { if ($c.name) { $byName[[string]$c.name] = $c } }
  $claimed = @{}
  foreach ($w in @($Pl.Keys)) {
    $cn = if ($charOf -and $charOf[$w]) { [string]$charOf[$w] } else { $w }
    if ($byName.ContainsKey($cn)) { $Pl[$w].char = $byName[$cn]; $claimed[$cn] = 1 }
  }
  foreach ($cn in $byName.Keys) { if (-not $claimed.ContainsKey($cn) -and -not $Pl.Contains($cn)) { $Pl[$cn] = @{ char=$byName[$cn]; days=@{} } } }
  $out = @()
  foreach ($w in $Pl.Keys) {
    $p = $Pl[$w]; $st = [ordered]@{}
    foreach ($k in "hours","night","dawn","weekend","coop","longest") { $st[$k] = [Math]::Round([double]$p[$k], 2) }
    foreach ($k in "visits","midnights","sunrise","returned","first","party","crash") { $st[$k] = [int]$p[$k] }
    $dates = @($p.days.Keys | Sort-Object)
    $st.days = $dates.Count
    $best = 0; $run = 0; $prev = $null
    foreach ($d in $dates) { $dt = [datetime]$d; if ($prev -and ($dt - $prev).TotalDays -eq 1) { $run++ } else { $run = 1 }; if ($run -gt $best) { $best = $run }; $prev = $dt }
    $st.streak = $best
    $st.patch = [int](@($dates | Where-Object { $patchDays.ContainsKey($_) }).Count -gt 0)
    $ch = $p.char
    $tot = 0; $minL = 99
    foreach ($sk in "Attack","Magic","Ranged","Mining","Woodcutting","Fishing","Cooking","Farming","Artisan","Construction","Runecrafting","Agility") {
      $l = if ($ch -and $ch.skills) { Level ([double]$ch.skills.$sk) } else { 1 }
      $st["lvl.$sk"] = $l; $tot += $l; if ($l -lt $minL) { $minL = $l }
    }
    $st.total = $tot; $st.minLevel = $minL
    foreach ($k in "recipes","buildings","spells","foes","landmarks","shrines","burrows","quests","journal","mounts") { $st[$k] = if ($ch) { [int]$ch.$k } else { 0 } }
    $out += [ordered]@{ name=$w; char=$(if ($ch) { [string]$ch.name } else { $null }); stats=$st }
  }
  return ,$out
}

# Adds unlock timestamps to each player's .earned, carrying over earlier unlocks from $prev.
function Award-Trophies($players, $prev, [string]$stamp) {
  if (-not (Test-Path $TrophyFile)) { return }
  $defs = @((Get-Content $TrophyFile -Raw | ConvertFrom-Json).trophies)
  foreach ($pl in $players) {
    $earned = [ordered]@{}
    $old = $prev[$pl.name]
    if ($old -is [System.Collections.IDictionary]) { foreach ($k in $old.Keys) { $earned[$k] = $old[$k] } }
    elseif ($old) { foreach ($q in $old.PSObject.Properties) { $earned[$q.Name] = $q.Value } }
    foreach ($d in $defs) {
      if ($d.stat -eq "allTrophies" -or $earned.Contains($d.id)) { continue }
      $v = $pl.stats[[string]$d.stat]
      if ($null -ne $v -and [double]$v -ge [double]$d.min) { $earned[$d.id] = $stamp }
    }
    foreach ($d in @($defs | Where-Object { $_.stat -eq "allTrophies" })) {
      $others = @($defs | Where-Object { $_.stat -ne "allTrophies" })
      if (-not $earned.Contains($d.id) -and @($others | Where-Object { $earned.Contains($_.id) }).Count -eq $others.Count) { $earned[$d.id] = $stamp }
    }
    $pl.earned = $earned
  }
}

# ================= offline sample (page preview) =================
if ($Offline) {
  $now = (Get-Date).ToUniversalTime()
  $names = @("Soop","Grillmaster","Chugz","Big Rig")
  $rnd = New-Object Random 406
  $sessions = @(); $events = @()
  $events += @{ t=(Iso $now.AddDays(-13)); kind="start"; note="247068" }
  for ($d = 13; $d -ge 0; $d--) {
    foreach ($n in $names) {
      if ($rnd.NextDouble() -lt 0.45) { continue }
      $startHr = @(19,20,21,22,13,9,23)[$rnd.Next(7)]
      $s = $now.Date.AddDays(-$d).AddHours($startHr + 6).AddMinutes($rnd.Next(60))
      if ($s -gt $now) { continue }
      $e = $s.AddMinutes(30 + $rnd.Next(240))
      $sessions += @{ who=$n; start=(Iso $s); end=$(if ($e -gt $now) { $null } else { Iso $e }) }
    }
  }
  $sessions += @{ who="Soop"; start=(Iso $now.AddMinutes(-95)); end=$null }
  $sessions += @{ who="Chugz"; start=(Iso $now.AddMinutes(-40)); end=$null }
  $events += @{ t=(Iso $now.AddDays(-6).AddHours(-3)); kind="crash"; note="" }
  $events += @{ t=(Iso $now.AddDays(-6).AddHours(-3).AddMinutes(1)); kind="start"; note="247068" }
  $events += @{ t=(Iso $now.AddDays(-2)); kind="stop"; note="" }
  $events += @{ t=(Iso $now.AddDays(-2).AddMinutes(4)); kind="start"; note="251190" }
  $samples = @()
  for ($i = 1008; $i -ge 0; $i--) {
    $t = $now.AddMinutes(-10 * $i)
    $up = if ($i -gt 860 -and $i -lt 866) { 0 } else { 1 }
    $samples += @{ t=(UnixMs $t); up=$up; ram=$(if ($up) { [int](2100 + 900 * [Math]::Abs([Math]::Sin($i / 40.0)) + $rnd.Next(150)) } else { 0 }); n=$(if ($up) { @($sessions | Where-Object { $_.start -le (Iso $t) -and (-not $_.end -or $_.end -ge (Iso $t)) }).Count } else { 0 }) }
  }
  $bk = @(); for ($i = 0; $i -lt 12; $i++) { $bk += @{ t=(Iso $now.AddHours(-9 * $i)); kb=(1800 + 40 * (12 - $i)) } }
  $data = [ordered]@{
    updated  = (UnixMs $now)
    demo     = $true
    server   = [ordered]@{ name=$Config.ServerName; world=$Config.World; maxPlayers=$Config.MaxPlayers; online=$true; startedAt=(Iso $now.AddDays(-2).AddMinutes(4)); ramMB=2840; build="251190" }
    online   = @("Soop","Chugz")
    sessions = $sessions
    events   = $events
    saves    = [ordered]@{ count=1290; last=(Iso $now.AddMinutes(-3)); worldKB=2214 }
    samples  = $samples
    backups  = [ordered]@{ count=12; keep=48; totalMB=23.1; list=$bk }
    characters = @($names | ForEach-Object { $sk = [ordered]@{}; foreach ($s in @("Attack","Magic","Ranged","Mining","Woodcutting","Fishing","Cooking","Farming","Artisan","Construction","Runecrafting","Agility")) { $sk[$s] = [int64]($rnd.Next(0, 60000) * $rnd.NextDouble()) }; [ordered]@{ name=$_; hardcore=$false; playSec=$rnd.Next(20000, 120000); skills=$sk; recipes=$rnd.Next(10, 140); buildings=$rnd.Next(5, 60); spells=$rnd.Next(0, 12); foes=$rnd.Next(3, 40); shrines=$rnd.Next(0, 6); burrows=$rnd.Next(0, 5); landmarks=$rnd.Next(2, 30); journal=$rnd.Next(40, 200); quests=$rnd.Next(1, 9); mounts=$rnd.Next(0, 2) } })
    levelups = @(@{ t=(Iso $now.AddDays(-3)); who="Soop"; skill="Mining"; level=40 }, @{ t=(Iso $now.AddDays(-1)); who="Chugz"; skill="Woodcutting"; level=50 }, @{ t=(Iso $now.AddHours(-5)); who="Grillmaster"; skill="Cooking"; level=30 })
    bosses   = @()
    graves   = @()
  }
  $tp = Get-PlayerStats $data.sessions $data.characters $data.events $null
  Award-Trophies $tp @{} (Iso $now)
  foreach ($pl in $tp) { foreach ($k in @($pl.earned.Keys)) { $pl.earned[$k] = Iso $now.AddMinutes(-$rnd.Next(10, 20000)) } }
  $data.trophies = @($tp)
  $out = Join-Path $Root "data.sample.json"
  $data | ConvertTo-Json -Depth 8 -Compress | Set-Content $out -Encoding utf8
  Write-Host "OFFLINE: wrote sample data to $out  (open index.html?demo to preview)"
  exit 0
}

# ================= state =================
function Load-State {
  if ((Test-Path $StateFile) -and -not $Rebuild) {
    $s = Get-Content $StateFile -Raw | ConvertFrom-Json
    return @{
      events  = AsList $s.events
      logs    = ToHash $s.logs
      saves   = ToHash $s.saves
      ids     = ToHash $s.ids
      levels  = ToHash $s.levels
      chars   = ToHash $s.chars
      charOf  = ToHash $s.charOf
      trophies = ToHash $s.trophies
      samples = AsList $s.samples
      unknown = AsList $s.unknown
    }
  }
  $old = if (Test-Path $StateFile) { Get-Content $StateFile -Raw | ConvertFrom-Json } else { $null }
  return @{ events=(AsList $null); logs=@{}; saves=@{}; ids=(ToHash $old.ids); levels=(ToHash $old.levels); chars=(ToHash $old.chars); charOf=(ToHash $old.charOf); trophies=(ToHash $old.trophies); samples=(AsList $old.samples); unknown=(AsList $null) }
}
# Xbox/PSN logins carry a "#1234" suffix that the join line omits ("soopa#5106" vs "soopa"),
# and account IDs vary in letter case between lines. Normalise both.
function Clean-Name([string]$n) { return ($n -replace '#\d+$', '').Trim() }
$state = Load-State
if ([int]$state.v -lt 2) {   # one-time repair of history saved before the fix above
  foreach ($e in $state.events) { if ($e.who) { $e.who = Clean-Name $e.who } }
  $fixed = @{}; foreach ($k in @($state.ids.Keys)) { $fixed[$k.ToUpper()] = Clean-Name $state.ids[$k] }; $state.ids = $fixed
  $fixed = @{}; foreach ($k in @($state.charOf.Keys)) { $fixed[(Clean-Name $k)] = $state.charOf[$k] }; $state.charOf = $fixed
  $state.logs = @{}   # re-read rotated logs still on disk (events are de-duplicated)
}
$state.v = 2
# Repair leaves recorded before login names could contain spaces ("Prof. Merlyn" was cut to
# "Prof.", so his leaves never closed his sessions). Safe to run every time.
$joinNames = @($state.events | Where-Object { $_.kind -eq "join" } | ForEach-Object { $_.who } | Select-Object -Unique)
foreach ($e in $state.events) {
  if ($e.kind -ne "leave" -or -not $e.who -or $joinNames -contains $e.who) { continue }
  $full = @($joinNames | Where-Object { $_.StartsWith($e.who + " ") })
  if ($full.Count -eq 1) { $e.who = $full[0] }
}
foreach ($k in @($state.ids.Keys)) { $full = @($joinNames | Where-Object { $_.StartsWith($state.ids[$k] + " ") }); if ($full.Count -eq 1 -and $joinNames -notcontains $state.ids[$k]) { $state.ids[$k] = $full[0] } }
$keys =New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($e in $state.events) { [void]$keys.Add(("{0}|{1}|{2}|{3}" -f $e.t, $e.kind, $e.who, $e.note)) }
$unknownSeen = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($u in $state.unknown) { [void]$unknownSeen.Add([string]$u) }

function Add-Event([string]$t, [string]$kind, [string]$who, [string]$note) {
  $k = "{0}|{1}|{2}|{3}" -f $t, $kind, $who, $note
  if ($keys.Add($k)) { [void]$state.events.Add([ordered]@{ t=$t; kind=$kind; who=$who; note=$note }) }
}

# ================= log parsing =================
# UE line:  [2026.10.04-01.08.03:946][  0]LogNet: Join succeeded: Soop     (timestamps are UTC)
$rxLine  = [regex]'^\[(\d{4})\.(\d\d)\.(\d\d)-(\d\d)\.(\d\d)\.(\d\d):(\d{3})\]\[\s*(\d+)\]([\w]+):\s?(.*)$'
$rxLogin = [regex]'Login request:.*?[?&]Name=([^?&]+?)(?=\?|&|\s+userId:|$).*?userId:\s*(\S+)'
$rxJoin  = [regex]'^Join succeeded:\s*(.+?)\s*$'
$rxClose = [regex]'(?:UNetConnection::Close|UChannel::CleanUp|Connection closed|CleanUp).*?UniqueId:\s*([^,\s]+)'
$rxLeft  = [regex]'(?i)\bplayer\s+(?:name\s*[:=]\s*)?["'']?(.+?)["'']?\s+(?:has\s+)?(?:left|disconnected|logged out)\b'
$rxBuild = [regex]'^Build:\s*\S*?CL-(\d+)'
$rxChar  = [regex]'Account\[XP:([0-9A-Fa-f]+)\] Character Name\[(.+?)\] Guid'
# Deaths. The log has no "X died" line, but a death respawn is a TeleportTo() of the player's
# pawn that, in the same frame, spawns a BP_PlayerGravestone_C and/or drops the held gear.
# Pawns are named by the "PlayerChar entered world" line just before they are possessed.
$rxEnter = [regex]'^PlayerChar entered world \[.*Character Name\[(.+?)\] Guid'
$rxPoss  = [regex]'^Character \[(BP_PlayerCharacter_C_\d+)\] possessed by controller'
$rxTp    = [regex]'TeleportTo\(\) : \[(BP_PlayerCharacter_C_\d+)\] Teleporting to'
$rxHit   = [regex]'PredictPointDamage\(\) : \[[^\]]+\] (BP_PlayerCharacter_C_\d+) will receive ([\d.]+) damage at [\d.]+ from (\S+?)\.?$'
$rxGrave = [regex]'teleport spot \[X=([-\d.]+) Y=([-\d.]+) Z=([-\d.]+)\] for \[BP_PlayerGravestone_C\]'
$FoeNames = @{ "RangedGoblin_Poison"="Poison Goblin Archer"; "RangedGoblin"="Goblin Archer"; "SentryGoblin"="Goblin Sentry"; "Trap_Fireball_Agility"="Fireball Trap" }
function Foe-Name([string]$actor) {
  $n = $actor -replace '^BP_(AI_)?', '' -replace '(_Character)?_C(_\w+)?$', ''
  if ($FoeNames.ContainsKey($n)) { return $FoeNames[$n] }
  return (($n -replace '_', ' ') -creplace '(?<=[a-z])(?=[A-Z])', ' ').Trim()
}
# Lines worth a human look when tuning (logged once to unparsed.log)
$rxMaybe = [regex]'(?i)(PostLogin|Logout|joined|left the|disconnect|kicked|banned|died|killed|defeated|gravestone)'
$rxNoise = [regex]'(?i)(LogRedpointEOS|LogEOS|LogJournal|SESSION|Telemetry|LogPluginManager|LogConfig|LogStreaming|LogInit)'

function Read-Lines([string]$path) {
  # The live log is held open by the server: open with full sharing.
  $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite,Delete')
  try {
    $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
    $text = $sr.ReadToEnd()
  } finally { $fs.Close() }
  return $text -split "`r?`n"
}

function Parse-Log([string]$path) {
  $r = @{ first=$null; last=$null; build=""; saves=0; clean=$false; fatal=$false; world=$false; items=(New-Object System.Collections.ArrayList) }
  $pawn = @{}; $entering = $null; $lastHit = @{}; $tp = $null
  foreach ($line in (Read-Lines $path)) {
    if ($line.StartsWith("LogInit: Build:")) {   # boot header lines carry no timestamp
      $b = $rxBuild.Match($line.Substring(9)); if ($b.Success) { $r.build = $b.Groups[1].Value }; continue
    }
    if ($line.Length -lt 30 -or $line[0] -ne '[') { continue }
    $m = $rxLine.Match($line)
    if (-not $m.Success) { continue }
    $g = $m.Groups
    $t = "{0}-{1}-{2}T{3}:{4}:{5}.{6}Z" -f $g[1].Value,$g[2].Value,$g[3].Value,$g[4].Value,$g[5].Value,$g[6].Value,$g[7].Value
    if (-not $r.first) { $r.first = $t }
    $r.last = $t
    $frame = $g[8].Value; $cat = $g[9].Value; $msg = $g[10].Value

    # ---- deaths: close out a pending respawn once its frame has passed ----
    if ($tp) {
      if ($frame -ne $tp.frame) {
        if ($tp.dead -and $tp.who) { [void]$r.items.Add(@{ t=$tp.t; kind="death"; who=$tp.who; note=$tp.note }) }
        $tp = $null
      } elseif ($msg.Contains("BP_PlayerGravestone_C")) {
        $x = $rxGrave.Match($msg); if ($x.Success) { $tp.dead = $true; $tp.note += "|{0:F0},{1:F0}" -f [double]$x.Groups[1].Value, [double]$x.Groups[2].Value }
        continue
      } elseif ($msg.Contains("CurrentHoldable:") -and $msg.EndsWith("-> nullptr.")) { $tp.dead = $true; continue }
    }
    if ($cat -eq "LogDominionPlayerControllerBase" -and $msg.StartsWith("PlayerChar entered world")) {
      $x = $rxEnter.Match($msg); if ($x.Success) { $entering = $x.Groups[1].Value }
    }
    if ($cat -eq "LogDominionPlayerCharacter") {
      $x = $rxPoss.Match($msg); if ($x.Success -and $entering) { $pawn[$x.Groups[1].Value] = $entering; $entering = $null; continue }
      $x = $rxTp.Match($msg)
      if ($x.Success) {
        $id = $x.Groups[1].Value; $by = ""; $h = $lastHit[$id]
        if ($h -and ([datetime]$t - [datetime]$h.t).TotalSeconds -le 60) {
          $by = if ($h.from -like "BP_PlayerCharacter_C_*") { if ($h.from -eq $id -or -not $pawn[$h.from]) { "" } else { "@" + $pawn[$h.from] } } else { Foe-Name $h.from }
        }
        $lastHit.Remove($id)
        $tp = @{ t=$t; frame=$frame; who=$pawn[$id]; dead=$false; note=$by }
        continue
      }
    }
    if ($cat -eq "EvadeAttack" -and $msg.Contains("will receive")) {
      $x = $rxHit.Match($msg); if ($x.Success -and [double]$x.Groups[2].Value -gt 0) { $lastHit[$x.Groups[1].Value] = @{ t=$t; from=$x.Groups[3].Value } }
      continue
    }

    if ($cat -eq "LogPersistence" -and $msg.Contains("Save completed SUCCESSFULLY")) { $r.saves++; continue }
    if ($cat -eq "LogCore" -and $msg.Contains("Engine exit requested")) { $r.clean = $true; continue }
    if ($msg.Contains("Critical error") -or $msg.Contains("Fatal error")) { $r.fatal = $true; continue }
    if ($cat -eq "LogInit") { $b = $rxBuild.Match($msg); if ($b.Success) { $r.build = $b.Groups[1].Value }; continue }
    if ($cat -eq "LogWorld" -and $msg.StartsWith("Bringing World /Game/Maps/World/")) { $r.world = $true; continue }
    if ($msg.Contains("Setting player info to Account[")) {
      $x = $rxChar.Match($msg)
      if ($x.Success) { $login = $state.ids[("RedpointEOS:" + $x.Groups[1].Value).ToUpper()]; if ($login) { $state.charOf[$login] = $x.Groups[2].Value } }
      continue
    }

    if ($cat -eq "LogNet") {
      $x = $rxLogin.Match($msg)
      if ($x.Success) {
        $name = Clean-Name ([uri]::UnescapeDataString($x.Groups[1].Value))
        $state.ids[$x.Groups[2].Value.ToUpper()] = $name
        continue
      }
      $x = $rxJoin.Match($msg)
      if ($x.Success) { [void]$r.items.Add(@{ t=$t; kind="join"; who=$x.Groups[1].Value }); continue }
      $x = $rxClose.Match($msg)
      if ($x.Success) {
        $id = $x.Groups[1].Value.ToUpper()
        if ($state.ids.ContainsKey($id)) { [void]$r.items.Add(@{ t=$t; kind="leave"; who=$state.ids[$id] }) }
        continue
      }
    }
    $x = $rxLeft.Match($msg)
    if ($x.Success -and $cat -ne "LogPluginManager") { [void]$r.items.Add(@{ t=$t; kind="leave"; who=$x.Groups[1].Value }); continue }

    if ($rxMaybe.IsMatch($msg) -and -not $rxNoise.IsMatch($cat + " " + $msg)) {
      $k = "$cat`: $msg"
      if ($k.Length -gt 300) { $k = $k.Substring(0, 300) }
      if ($state.unknown.Count -lt 400 -and $unknownSeen.Add($k)) {
        [void]$state.unknown.Add($k)
        Add-Content $Unparsed ("[{0}] {1}" -f $t, $k)
      }
    }
  }
  return $r
}

# ================= test-parse mode =================
if ($TestLog) {
  $p = Parse-Log $TestLog
  Write-Host ("Run {0} -> {1}  build={2} saves={3} cleanExit={4} fatal={5}" -f $p.first, $p.last, $p.build, $p.saves, $p.clean, $p.fatal)
  $p.items | ForEach-Object { Write-Host ("  {0}  {1,-5}  {2}" -f $_.t, $_.kind, $_.who) }
  exit 0
}

# ---- process ----
$proc = Get-Process -Name $ProcName -ErrorAction SilentlyContinue | Select-Object -First 1
$serverUp = [bool]$proc

# ---- logs: finished (rotated) logs once each, the live log every run ----
$logFiles = @()
if (Test-Path $LogDir) { $logFiles = @(Get-ChildItem -LiteralPath $LogDir -Filter "RSDragonwilds*.log" | Sort-Object LastWriteTimeUtc) }
$build = ""
foreach ($f in $logFiles) {
  $isLive = $f.Name -eq "RSDragonwilds.log"
  $sig = "{0}|{1}" -f $f.Name, $f.Length
  if (-not $isLive -and $state.logs.ContainsKey($sig)) { continue }
  $p = Parse-Log $f.FullName
  if (-not $p.first) { continue }
  if (-not $p.world) { if (-not $isLive) { $state.logs[$sig] = $true }; continue }   # aborted launch (e.g. a 2nd copy that quit)
  $runKey = $p.first
  Add-Event $p.first "start" "" $p.build
  foreach ($i in $p.items) { Add-Event $i.t $i.kind $i.who ([string]$i.note) }
  if ($p.saves -gt 0) { $state.saves[$runKey] = @{ n=$p.saves; last=$p.last } }
  if ($p.build) { $build = $p.build }
  # A run is over if its log was rotated, or it's the live log and the server isn't running.
  if (-not $isLive -or -not $serverUp) {
    $endKind = if ($p.clean -and -not $p.fatal) { "stop" } else { "crash" }
    Add-Event $p.last $endKind "" ""
  }
  if (-not $isLive) { $state.logs[$sig] = $true }
}

# ---- sessions from the event stream ----
$evs = @($state.events | Sort-Object { $_.t }, { @{start=0; join=1; leave=2; stop=3; crash=3}[$_.kind] })
$open = @{}; $sessions = New-Object System.Collections.ArrayList
function Close-All([string]$t) {
  foreach ($w in @($open.Keys)) { [void]$sessions.Add([ordered]@{ who=$w; start=$open[$w]; end=$t }) }
  $open.Clear()
}
$lastT = $null
foreach ($e in $evs) {
  switch ($e.kind) {
    "start" { Close-All $(if ($lastT) { $lastT } else { $e.t }) }   # previous run ended without a marker
    "join"  { if (-not $open.ContainsKey($e.who)) { $open[$e.who] = $e.t } }
    "leave" { if ($open.ContainsKey($e.who)) { [void]$sessions.Add([ordered]@{ who=$e.who; start=$open[$e.who]; end=$e.t }); $open.Remove($e.who) } }
    { $_ -in "stop","crash" } { Close-All $e.t }
  }
  $lastT = $e.t
}
$online = @()
if ($serverUp) {
  foreach ($w in $open.Keys) { [void]$sessions.Add([ordered]@{ who=$w; start=$open[$w]; end=$null }); $online += $w }
} else { Close-All $(if ($lastT) { $lastT } else { Iso (Get-Date) }) }

# ---- world save ----
$saveInfo = [ordered]@{ count=0; last=$null; worldKB=0 }
foreach ($v in $state.saves.Values) {
  $saveInfo.count += [int]$v.n
  if (-not $saveInfo.last -or [string]$v.last -gt $saveInfo.last) { $saveInfo.last = [string]$v.last }
}
$sav = $null
if (Test-Path $SaveDir) { $sav = Get-ChildItem -LiteralPath $SaveDir -Filter "*.sav" -ErrorAction SilentlyContinue | Where-Object { $_.Extension -eq ".sav" } | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1 }

# Skill PersistenceIDs (base64url GUIDs) -> names. From the game's asset registry, as
# catalogued by the community save editors (e.g. OogaBoogaCode/RSDWSaveEditor).
$SkillIds = @{
  "4pefO9k1lUqfA6mvHNi1SA"="Attack"; "0hreSMRVXUihq9qjDO2CFA"="Magic"; "heq7u88Q2UuLXFqLGTVwQw"="Ranged"
  "jqX0Gh6QI0GFFPCDFK_CJQ"="Mining"; "4zYUGF5u_0KbMLkWJmmBbQ"="Woodcutting"; "vwY5IkQJJDwb2PKEfoc8MQ"="Fishing"
  "Tn7t6DQyX0-Q0cM5K7B90A"="Cooking"; "PyUi-0LU_riFY46AnnFiWg"="Farming"; "Wf3i7Ha-B06DH719j1vtBw"="Artisan"
  "waK-8EyQFQ2xEjCGYmuTRQ"="Construction"; "NOqC-z-2ckqi0El22qMFlw"="Runecrafting"; "pJggvotwOkuoc98igUn7xA"="Agility"
}
function Cnt($x) { if ($null -eq $x) { 0 } else { @($x).Count } }

# Every character that has played this world is stored inside the world .sav as a JSON
# string (an Unreal FString: int32 length, then the text) beginning {"Version":..,"meta_data":..}.
function Read-Characters([byte[]]$bytes, [string]$txt) {
  $out = @()
  foreach ($m in [regex]::Matches($txt, '\{\s*"Version":\s*\d+,\s*"meta_data"')) {
    try {
      $len = [BitConverter]::ToInt32($bytes, $m.Index - 4)
      if ($len -le 1 -or $m.Index + $len - 1 -gt $bytes.Length) { continue }
      $o = [Text.Encoding]::UTF8.GetString($bytes, $m.Index, $len - 1) | ConvertFrom-Json
      $gp = $o.GameProgress; $pr = $gp.Progress
      $skills = [ordered]@{}
      foreach ($s in @($gp.Skills.Skills)) { $n = $SkillIds[[string]$s.Id]; if ($n) { $skills[$n] = [int64]$s.Xp } }
      $out += [ordered]@{
        name      = [string]$o.meta_data.char_name
        guid      = [string]$o.meta_data.char_guid
        saveCount = [int]$o.SaveCount
        hardcore  = [bool]$o.Hardcore.IsHardcore
        playSec   = [int][double]$gp.Character.Playtime_wall
        skills    = $skills
        recipes   = Cnt $pr.RecipesUnlocked
        buildings = Cnt $pr.BuildingsUnlocked
        spells    = Cnt $pr.SpellsUnlocked
        foes      = Cnt $pr.KilledOnceAIs
        shrines   = Cnt $pr.ShrinesUnlocked
        burrows   = Cnt $pr.KebbitBurrowsFound
        landmarks = Cnt $gp.RevealedLandmarks.RevealedLandmarkNames
        journal   = Cnt $gp.Journal.UnlockedEntries
        quests    = Cnt $gp.QuestProgress.Quests
        mounts    = Cnt $gp.Character.Mount.MountsUnlockedList
      }
    } catch { Write-Host "character parse skipped at $($m.Index): $($_.Exception.Message)" }
  }
  return ,$out
}

$characters = @()
function ToMap($x) { if ($x -is [System.Collections.IDictionary]) { return $x }; return ToHash $x }
function Read-Shared([string]$path) {
  $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite,Delete')
  try { $b = New-Object byte[] $fs.Length; [void]$fs.Read($b, 0, $b.Length) } finally { $fs.Close() }
  return ,$b
}
if ($sav) {
  $saveInfo.worldKB = [int]($sav.Length / 1KB)
  $saveInfo.last = Iso $sav.LastWriteTimeUtc
  # Characters live on each player's own PC; the server only holds one while that player is
  # online (autosaves every ~5 min include it, the save after they leave drops it). So read the
  # current save AND the game's previous one (.sav.backup), and remember the newest snapshot of
  # every character (highest SaveCount) in state.json.
  $txt = $null
  foreach ($path in @($sav.FullName, ($sav.FullName + ".backup"))) {
    if (-not (Test-Path -LiteralPath $path)) { continue }
    try {
      $bytes = Read-Shared $path
      $t8 = [Text.Encoding]::GetEncoding(28591).GetString($bytes)
      if (-not $txt) { $txt = $t8 }
      foreach ($c in (Read-Characters $bytes $t8)) {
        if (-not $c.guid) { continue }
        $old = $state.chars[$c.guid]
        if (-not $old -or [int]$c.saveCount -gt [int]$old.saveCount) { $c.seen = Iso (Get-Date); $state.chars[$c.guid] = $c }
      }
    } catch { Write-Host "save read skipped ($path): $($_.Exception.Message)" }
  }
  $characters = @($state.chars.Values)

  # Level-up milestones (every 10 levels, and 99) become chronicle events. A character seen
  # for the first time is only recorded, so joining with an old character doesn't spam.
  $nowIso = Iso (Get-Date)
  foreach ($c in $characters) {
    if (-not $c.name) { continue }
    $prev = $state.levels[$c.name]
    $cur = @{}
    $skm = ToMap $c.skills
    foreach ($k in @($skm.Keys)) { $cur[$k] = Level $skm[$k] }
    if ($prev) {
      foreach ($k in $cur.Keys) {
        $was = [int]$prev.$k
        if (-not $was) { $was = 1 }
        foreach ($ms in @(10,20,30,40,50,60,70,80,90,99)) {
          if ($was -lt $ms -and $cur[$k] -ge $ms) { Add-Event $nowIso "level" $c.name ("{0}|{1}" -f $k, $ms) }
        }
      }
    }
    $state.levels[$c.name] = $cur
  }

  # Save-file probe: dump the save's readable strings that weren't in the fresh-world
  # baseline, so not-yet-decoded data (bosses, gravestones) can be spotted and wired in.
  if ($txt) { try {
    $strs = @([regex]::Matches($txt, '[\x20-\x7e]{4,}') | ForEach-Object { $_.Value } | Select-Object -Unique)
    if (-not (Test-Path $SaveBase)) { $strs | Set-Content $SaveBase -Encoding utf8 }
    $base = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($s in (Get-Content $SaveBase)) { [void]$base.Add($s) }
    @($strs | Where-Object { -not $base.Contains($_) }) | Set-Content $SaveProbe -Encoding utf8
  } catch { Write-Host "save probe skipped: $($_.Exception.Message)" } }
}

# ---- trophies ----
$trophyPlayers = Get-PlayerStats $sessions $characters $state.events $state.charOf
Award-Trophies $trophyPlayers $state.trophies (Iso (Get-Date))
foreach ($pl in $trophyPlayers) { if ($pl.earned) { $state.trophies[$pl.name] = $pl.earned } }

# ---- process sample (7-day history) ----
$nowUtc = (Get-Date).ToUniversalTime()
$ramMB = if ($proc) { [int]($proc.WorkingSet64 / 1MB) } else { 0 }
[void]$state.samples.Add([ordered]@{ t=(UnixMs $nowUtc); up=[int]$serverUp; ram=$ramMB; n=$online.Count })
$cut = UnixMs $nowUtc.AddDays(-$KeepSamplesDays)
$state.samples = AsList @($state.samples | Where-Object { [int64]$_.t -ge $cut })

# ---- backup vault ----
$bk = [ordered]@{ count=0; keep=48; totalMB=0; list=@() }
if (Test-Path $Backups) {
  $dirs = @(Get-ChildItem -LiteralPath $Backups -Directory -Filter "Saves_*" | Sort-Object Name -Descending)
  $total = 0; $list = @()
  foreach ($d in $dirs) {
    $sz = (Get-ChildItem -LiteralPath $d.FullName -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    if (-not $sz) { $sz = 0 }
    $total += $sz
    $ts = $d.CreationTimeUtc
    $pm = [regex]::Match($d.Name, 'Saves_(\d{4}-\d\d-\d\d)_(\d\d)-(\d\d)-(\d\d)')
    if ($pm.Success) { $ts = ([datetime]("{0} {1}:{2}:{3}" -f $pm.Groups[1].Value,$pm.Groups[2].Value,$pm.Groups[3].Value,$pm.Groups[4].Value)).ToUniversalTime() }
    $list += [ordered]@{ t=(Iso $ts); kb=[int]($sz / 1KB) }
  }
  $bk.count = $dirs.Count; $bk.totalMB = [Math]::Round($total / 1MB, 1); $bk.list = @($list | Select-Object -First 48)
}

# ---- persist state ----
[ordered]@{
  v=2
  events=@($state.events); logs=$state.logs; saves=$state.saves; ids=$state.ids; levels=$state.levels; chars=$state.chars; charOf=$state.charOf; trophies=$state.trophies
  samples=@($state.samples); unknown=@($state.unknown)
} | ConvertTo-Json -Depth 8 -Compress | Set-Content $StateFile -Encoding utf8

$startedAt = $null
if ($proc) { try { $startedAt = Iso $proc.StartTime } catch { } }

# ---- data.json ----
if (-not $build) { $lastStart = @($evs | Where-Object { $_.kind -eq "start" -and $_.note }) | Select-Object -Last 1; if ($lastStart) { $build = $lastStart.note } }
$data = [ordered]@{
  updated  = (UnixMs $nowUtc)
  server   = [ordered]@{
    name=$Config.ServerName; world=$Config.World; maxPlayers=$Config.MaxPlayers; online=$serverUp
    startedAt=$startedAt; ramMB=$ramMB; build=$build
  }
  online   = @($online)
  sessions = @($sessions | Sort-Object { $_.start })
  events   = @($evs | Where-Object { $_.kind -in "start","stop","crash" } | ForEach-Object { [ordered]@{ t=$_.t; kind=$_.kind; note=$_.note } })
  saves    = $saveInfo
  samples  = @($state.samples)
  backups  = $bk
  characters = @($characters)
  trophies = @($trophyPlayers)
  levelups = @($state.events | Where-Object { $_.kind -eq "level" } | ForEach-Object { $p = ([string]$_.note).Split("|"); [ordered]@{ t=$_.t; who=$_.who; skill=$p[0]; level=[int]$p[1] } })
  bosses   = @()
  graves   = @($state.events | Where-Object { $_.kind -eq "death" } | ForEach-Object { $by = ([string]$_.note).Split("|")[0]; [ordered]@{ t=$_.t; who=$_.who; by=($by -replace '^@', ''); cause=$(if ($by.StartsWith("@")) { "Slain by " + $by.Substring(1) } elseif ($by) { "Slain by " + $(if ($by -match '^[AEIOU]') { "an " } else { "a " }) + $by } else { "" }) } })
}
$data | ConvertTo-Json -Depth 8 -Compress | Set-Content $DataFile -Encoding utf8
Write-Host ("Wrote {0}  (server: {1}, online: {2}, sessions: {3}, events: {4}, backups: {5})" -f `
  $DataFile, $(if ($serverUp) { "UP" } else { "down" }), $online.Count, $sessions.Count, $state.events.Count, $bk.count)

# ---- publish ----
# Runs every 5 min (to catch every autosave) but pushes at most every ~10 min, which keeps
# GitHub Pages under its ~10 builds/hour soft limit.
$pushFlag = Join-Path $Here "last-push.txt"
$due = -not (Test-Path $pushFlag) -or ((Get-Date) - (Get-Item $pushFlag).LastWriteTime).TotalMinutes -ge 9
if (($Config.Push -eq $true) -and -not $NoPush -and $due) {
  Set-Content $pushFlag (Get-Date -Format s)
  Push-Location $Root
  try {
    git add data.json | Out-Null
    git commit -m ("data {0}" -f (Get-Date -Format s)) --quiet
    git push --quiet
    Write-Host "Pushed to GitHub."
  } catch { Write-Host "git push skipped/failed: $($_.Exception.Message)" }
  finally { Pop-Location }
}
