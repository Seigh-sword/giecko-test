param(
  [string]$Password = "giecko",
  [string]$DurationMin = "180",
  [string]$ExtraPkgs = "",
  [string]$Stack = "ide",
  [string]$AutosaveMin = "15",
  [string]$User = "giecko",
  [string]$Mask = "false",
  [string]$Distro = "runner",
  [string]$PersistHome = "false"
)

$ErrorActionPreference = "Continue"
if ($Password -eq "__BLANK__") { $Password = "" }
if ($User -notmatch '^[A-Za-z0-9_-]{1,16}$') { $User = "giecko" }
if ($Mask -in @("true", "1", "yes")) { $Mask = "1" } else { $Mask = "0" }
if ($PersistHome -in @("true", "1", "yes")) { $PersistHome = "1" } else { $PersistHome = "0" }
if ($PersistHome -eq "1") { Write-Host "  persistent home is linux/macos only, skipping on windows" }
switch ($Stack) { "terminal" {} "vscode" {} "ide" {} "desktop" {} default { Write-Host "  unknown stack '$Stack', using ide"; $Stack = "ide" } }
switch ($Distro) { "runner" {} default { Write-Host "no docker distros on Windows, using runner shell"; $Distro = "runner" } }
[int]$DurationI = 0
if (-not [int]::TryParse($DurationMin, [ref]$DurationI) -or $DurationI -lt 0) { $DurationI = 180 }
[int]$AutosaveI = 0
if (-not [int]::TryParse($AutosaveMin, [ref]$AutosaveI) -or $AutosaveI -lt 0) { $AutosaveI = 0 }

$TermPort = 7681
$CodePort = 8080
$DeskPort = 6080
$VncPort = 5900
$RunId = if ($env:GITHUB_RUN_ID) { $env:GITHUB_RUN_ID } else { "local" }
$RepoSlug = $env:GITHUB_REPOSITORY
$BootStart = Get-Date
$Heartbeats = 0
$UrlTerm = ""
$UrlCode = ""
$UrlDesk = ""
$CodeOk = $false
$CodeWarned = $false
$DeskOk = $false
$Named = $false
$VncAuth = "not run"
$Region = "unknown"
$EgressIp = "?"
$DistroEff = "runner"
$RunDir = Join-Path $PWD ".giecko"
$BinDir = Join-Path $RunDir "bin"
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
$WorkDir = Join-Path $(if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }) "giecko-work"
$WorkBranch = "giecko-work/run-$RunId"

$NeedTtyd = $true
$NeedCode = $true
$CodeRequired = $false
if ($Stack -eq "vscode") { $NeedTtyd = $false; $CodeRequired = $true }
if ($Stack -eq "terminal") { $NeedCode = $false }
if ($Stack -eq "desktop") { $NeedCode = $false }

function Fail([string]$Why) {
  Write-Host " $Why" -ForegroundColor Red
  try { Publish-Report "failed" $Why | Out-Null } catch {}
  exit 1
}

function Port-Up([int]$Port) {
  $c = New-Object Net.Sockets.TcpClient
  try {
    $t = $c.ConnectAsync("127.0.0.1", $Port).Wait(1200)
    if ($t -and $c.Connected) { return $true }
    return $false
  } catch { return $false } finally { $c.Dispose() }
}

function Wait-Port([int]$Port, [int]$Tries, [int]$SleepSec) {
  for ($i = 0; $i -lt $Tries; $i++) {
    if (Port-Up $Port) { return $true }
    Start-Sleep -Seconds $SleepSec
  }
  return $false
}

function Http-Up([int]$Port, [string]$UserPass) {
  try {
    $h = @{ Uri = "http://127.0.0.1:$Port/"; TimeoutSec = 5; UseBasicParsing = $true }
    if ($UserPass) { $h.Headers = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($UserPass)) } }
    $r = Invoke-WebRequest @h -SkipHttpErrorCheck
    if ($null -ne $r -and $r.StatusCode -gt 0) { return $true }
    return $false
  } catch { return $false }
}

function Start-Procx([string]$File, [string[]]$ProcArgs, [string]$Name) {
  $stdout = Join-Path $RunDir "$Name.log"
  $stderr = Join-Path $RunDir "$Name.err.log"
  $p = Start-Process -FilePath $File -ArgumentList $ProcArgs -WorkingDirectory $WorkDir -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -WindowStyle Hidden
  return $p
}

function Tunnel-Url([string]$Log) {
  if (Test-Path $Log) {
    $m = Select-String -Path $Log -Pattern 'https://[A-Za-z0-9.-]+\.trycloudflare\.com' | Select-Object -First 1
    if ($m) { return $m.Matches[0].Value }
  }
  return ""
}

function Start-Tunnel([int]$Port, [string]$Name) {
  $p = Start-Procx (Join-Path $BinDir "cloudflared.exe") @("tunnel", "--url", "http://127.0.0.1:$Port", "--no-autoupdate") $Name
  Set-Content -Path (Join-Path $RunDir "$Name.pid") -Value $p.Id
  return $p
}

function Wait-Tunnel([string]$Name, $Proc) {
  for ($i = 0; $i -lt 60; $i++) {
    $u = Tunnel-Url (Join-Path $RunDir "$Name.log")
    if ($u) { return $u }
    if ($Proc.HasExited) { return "" }
    Start-Sleep -Seconds 2
  }
  return ""
}

function Pub-Url([string]$U) {
  if (-not $U) { return "" }
  if ($Mask -eq "1") { return "https://****.trycloudflare.com" }
  return $U
}

function Sha256-Of([string]$Path) {
  if ($Path -and (Test-Path $Path)) {
    try { return (Get-FileHash -Algorithm SHA256 $Path).Hash.ToLower() } catch {}
  }
  return "n/a"
}

function Fetch-Bin([string]$Url, [string]$Dest) {
  try {
    Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -TimeoutSec 300
    return $true
  } catch { return $false }
}

function Publish-Report([string]$Status, [string]$Note) {
  if ($env:GITHUB_ACTIONS -ne "true") { return "" }
  if (-not $env:GITHUB_TOKEN) { Write-Host "  no GITHUB_TOKEN, skipping report publish"; return "" }
  if (-not $RepoSlug) { Write-Host "  no GITHUB_REPOSITORY, skipping report publish"; return "" }
  $rdir = Join-Path $env:RUNNER_TEMP ("giecko-report-" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
  $authUrl = "https://x-access-token:$($env:GITHUB_TOKEN)@github.com/$RepoSlug.git"
  git clone -q --depth 1 --branch giecko-reports $authUrl $rdir 2>$null
  if ($LASTEXITCODE -ne 0) {
    git clone -q --depth 1 $authUrl $rdir 2>$null
    if ($LASTEXITCODE -ne 0) { return "" }
    Push-Location $rdir
    git checkout -q --orphan giecko-reports
    git rm -q -rf . 2>$null
    Pop-Location
  }
  New-Item -ItemType Directory -Force -Path (Join-Path $rdir "reports") | Out-Null
  $bootNow = [int]((Get-Date) - $BootStart).TotalSeconds
  $body = @()
  $body += "#  Giecko report -- run ``$RunId``"
  $body += ""
  $body += "- status: **$Status** $(if ($Note) { "($Note)" })"
  $body += "- time_utc: $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss'))"
  $body += "- os: windows (powershell), stack: $Stack, distro: $Distro (effective: $DistroEff)"
  $body += "- user: $User, auth: $(if ($Password) { 'on' } else { 'OFF (open)' }), mask: $Mask, duration_min: $DurationI, autosave_min: $AutosaveI"
  $body += "- region: $Region, egress_ip: $EgressIp"
  $body += "- boot_seconds: $bootNow, heartbeats: $Heartbeats"
  $body += "- url_terminal: $(if ($UrlTerm) { Pub-Url $UrlTerm } else { 'NO' })"
  $body += "- url_code: $(if ($UrlCode) { Pub-Url $UrlCode } else { 'NO' })"
  $body += "- url_desk: $(if ($UrlDesk) { Pub-Url $UrlDesk } else { 'NO' })"
  $body += "- work_branch: $WorkBranch"
  $body += "- binaries (sha256): cloudflared=$(Sha256-Of (Join-Path $BinDir 'cloudflared.exe')) ttyd=$(if ($NeedTtyd) { Sha256-Of (Join-Path $BinDir 'ttyd.exe') } else { 'n/a' }) code-server=n/a"
  $body += "- vnc_auth: $VncAuth"
  foreach ($name in @("ttyd", "term-tunnel", "code-server", "code-tunnel", "novnc", "desk-tunnel", "named-tunnel")) {
    $lp = Join-Path $RunDir "$name.log"
    if (Test-Path $lp) {
      $tail = (Get-Content $lp -Tail 12 -ErrorAction SilentlyContinue) -join "`n"
      if ($tail) {
        if ($Password) { $tail = $tail -replace [regex]::Escape($Password), "REDACTED" }
        if ($Mask -eq "1") { $tail = $tail -replace 'https://[A-Za-z0-9.-]+\.trycloudflare\.com', 'https://****.trycloudflare.com' }
        $body += ""
        $body += "## $name (tail, redacted)"
        $body += '```'
        $body += $tail
        $body += '```'
      }
    }
  }
  Set-Content -Path (Join-Path $rdir "reports/run-$RunId.md") -Value ($body -join "`n")
  Push-Location $rdir
  git add "reports/run-$RunId.md"
  git -c user.email="giecko@local" -c user.name="giecko" commit -qm "report $RunId: $Status"
  git push -q -u origin giecko-reports 2>$null
  $rc = $LASTEXITCODE
  if ($rc -ne 0) {
    git pull -q --rebase origin giecko-reports 2>$null
    git push -q origin giecko-reports 2>$null
    $rc = $LASTEXITCODE
  }
  Pop-Location
  Remove-Item -Recurse -Force $rdir -ErrorAction SilentlyContinue
  if ($rc -eq 0) { Write-Host " report published (status=$Status)"; Write-Host "::notice::giecko report [$Status]" }
  else { Write-Host "::warning::giecko report publish failed ($Status)"; Write-Host "  report publish failed (non-fatal)" }
  return ""
}

Write-Host " Giecko booting (powershell edition)..." -ForegroundColor Green
Write-Host "   os/stack  : windows / $Stack"
Write-Host "   distro    : $Distro (runner only on windows)"
Write-Host "   user      : $User"
if ($Password) { Write-Host "   auth      : enabled " } else { Write-Host "   auth      : DISABLED   (public!)" }
Write-Host "   mask      : $(if ($Mask -eq '1') { 'on (hostnames hidden)' } else { 'off' })"
Write-Host "   duration  : $DurationI min"
Write-Host "   autosave  : $(if ($AutosaveI -gt 0) { "every $AutosaveI min" } else { 'off' })"
Write-Host "   extras    : $(if ($ExtraPkgs) { $ExtraPkgs } else { 'none' })"
Write-Host "   run_id    : $RunId"
if ($Password) { Write-Host "::add-mask::$Password" }

try {
  $geo = Invoke-RestMethod -Uri 'http://ip-api.com/json/?fields=status,countryCode,regionName' -TimeoutSec 8
  if ($geo.status -eq "success") { $Region = "$($geo.countryCode)$(if ($geo.regionName) { '/' + $geo.regionName })" }
} catch {}
try { $EgressIp = (Invoke-WebRequest -Uri 'https://api.ipify.org' -UseBasicParsing -TimeoutSec 5).Content } catch {}
Write-Host "   region    : $Region -- if that's far from you, that's the typing lag. Physics!"
Write-Host ""

if ($ExtraPkgs) {
  if (Get-Command choco -ErrorAction SilentlyContinue) {
    Write-Host " installing extra packages via chocolatey..."
    $pkgs = $ExtraPkgs -split '\s+' | Where-Object { $_ }
    foreach ($pk in $pkgs) {
      choco install $pk -y --no-progress 2>&1 | Out-Null
      if ($LASTEXITCODE -ne 0) { Write-Host "  choco install $pk failed" }
    }
  } else {
    Write-Host "  no choco on this runner, extra packages skipped"
  }
}

Write-Host " downloading cloudflared (windows)..."
if (-not (Fetch-Bin "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe" (Join-Path $BinDir "cloudflared.exe"))) { Fail "cloudflared download failed" }

$TtydBin = ""
if ($NeedTtyd) {
  $ttydCmd = Get-Command ttyd -ErrorAction SilentlyContinue
  if ($ttydCmd) { $TtydBin = $ttydCmd.Source } else {
    Write-Host " downloading ttyd (windows)..."
    if (-not (Fetch-Bin "https://github.com/tsl0922/ttyd/releases/latest/download/ttyd.win32.exe" (Join-Path $BinDir "ttyd.exe"))) { Fail "ttyd download failed" }
    $TtydBin = Join-Path $BinDir "ttyd.exe"
  }
}

$CodeBin = ""
if ($NeedCode) {
  Write-Host " resolving code-server..."
  try {
    $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/coder/code-server/releases/latest' -TimeoutSec 20
    $asset = $rel.assets | Where-Object { $_.name -like "*windows*" } | Select-Object -First 1
    if ($asset) {
      Write-Host " downloading code-server..."
      if (Fetch-Bin $asset.browser_download_url (Join-Path $RunDir "code-server.zip")) {
        $codeDir = Join-Path $RunDir "code"
        New-Item -ItemType Directory -Force -Path $codeDir | Out-Null
        Expand-Archive -Path (Join-Path $RunDir "code-server.zip") -DestinationPath $codeDir -Force
        $found = Get-ChildItem -Path $codeDir -Recurse -Include "code-server.cmd", "code-server.exe" | Select-Object -First 1
        if ($found) { $CodeBin = $found.FullName }
      }
    }
  } catch {}
  if (-not $CodeBin) {
    if ($CodeRequired) { Fail "code-server has no windows build but stack=vscode needs it" }
    Write-Host "  code-server unavailable on windows, continuing without vscode"
  }
}

if ($env:GITHUB_ACTIONS -eq "true" -and $env:GITHUB_TOKEN -and $RepoSlug) {
  if (Test-Path $WorkDir) { Remove-Item -Recurse -Force $WorkDir }
  $authUrl = "https://x-access-token:$($env:GITHUB_TOKEN)@github.com/$RepoSlug.git"
  git clone -q --depth 1 $authUrl $WorkDir 2>"$(Join-Path $RunDir 'work-clone.log')"
  if ($LASTEXITCODE -eq 0) {
    Push-Location $WorkDir
    git checkout -q -b $WorkBranch
    git push -q -f -u origin $WorkBranch 2>>"$(Join-Path $RunDir 'work-clone.log')"
    $rc = $LASTEXITCODE
    Pop-Location
    if ($rc -ne 0) { Get-Content (Join-Path $RunDir 'work-clone.log') -Tail 5; Fail "work branch setup failed" }
    Write-Host " work branch ready"
  } else {
    Get-Content (Join-Path $RunDir 'work-clone.log') -Tail 5
    Fail "work branch clone failed"
  }
} else {
  New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
}

if ($env:GIECKO_RESTORE -and $env:GITHUB_ACTIONS -eq "true" -and $RepoSlug) {
  Write-Host " restoring files from run $($env:GIECKO_RESTORE)..."
  $rdir = Join-Path $env:RUNNER_TEMP "giecko-restore"
  if (Test-Path $rdir) { Remove-Item -Recurse -Force $rdir }
  $rauth = "https://x-access-token:$($env:GITHUB_TOKEN)@github.com/$RepoSlug.git"
  git clone -q --depth 1 --branch "giecko-work/run-$($env:GIECKO_RESTORE)" $rauth $rdir 2>"$(Join-Path $RunDir 'restore.log')"
  if ($LASTEXITCODE -eq 0) {
    Get-ChildItem -Path $rdir -Force | Where-Object { $_.Name -ne ".git" } | Copy-Item -Destination $WorkDir -Recurse -Force
    Write-Host " restored files from run $($env:GIECKO_RESTORE)"
  } else {
    Write-Host "  restore failed (no saved branch for that run?), continuing fresh"
  }
  if (Test-Path $rdir) { Remove-Item -Recurse -Force $rdir }
}

$TtydProc = $null
if ($NeedTtyd) {
  $shellBin = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell" }
  $ttydArgs = @("-p", "$TermPort", "--writable")
  if ($Password) { $ttydArgs += @("-c", "${User}:${Password}") }
  $ttydArgs += @("-t", "fontSize=15", "-t", "fontFamily=JetBrains Mono, Consolas, monospace", "-t", 'theme={"background":"#0B0F14","foreground":"#E6EDF3","cursor":"#FFB454","selection":"#1E3A5F"}', "-t", "titleFixed=Giecko Terminal")
  $ttydArgs += @($shellBin, "-NoLogo")
  Write-Host "  starting ttyd on :$TermPort (cmd: $shellBin)..."
  $TtydProc = Start-Procx $TtydBin $ttydArgs "ttyd"
  $curlAuth = if ($Password) { "${User}:${Password}" } else { "" }
  $up = $false
  for ($i = 0; $i -lt 20; $i++) { if (Http-Up $TermPort $curlAuth) { $up = $true; break }; Start-Sleep -Seconds 1 }
  if (-not $up) { Get-Content (Join-Path $RunDir "ttyd.log") -ErrorAction SilentlyContinue; Fail "ttyd failed to start" }
  Write-Host " ttyd is up"
}

$CodeProc = $null
if ($CodeBin) {
  Write-Host " starting code-server on :$CodePort..."
  $codeArgs = @("--bind-addr", "127.0.0.1:$CodePort", "--disable-telemetry", $WorkDir)
  if ($Password) {
    $env:PASSWORD = $Password
    $CodeProc = Start-Procx $CodeBin ($codeArgs + @("--auth", "password")) "code-server"
  } else {
    $CodeProc = Start-Procx $CodeBin ($codeArgs + @("--auth", "none")) "code-server"
  }
  $up = $false
  for ($i = 0; $i -lt 45; $i++) { if (Http-Up $CodePort "") { $up = $true; break }; Start-Sleep -Seconds 2 }
  if ($up) { $CodeOk = $true; Write-Host " code-server is up" }
  elseif ($CodeRequired) { Get-Content (Join-Path $RunDir "code-server.log") -Tail 10 -ErrorAction SilentlyContinue; Fail "code-server failed but stack=vscode needs it" }
  else { Write-Host "  code-server didn't start, continuing terminal-only" }
}

$DeskProcs = @()
if ($Stack -eq "desktop") {
  $VncPw = if ($Password) { $Password.Substring(0, [Math]::Min(8, $Password.Length)) } else { "" }
  Write-Host "  windows desktop: installing TightVNC..."
  $tvnArgs = "SET_ALLOWLOOPBACK=1 VALUE_OF_ALLOWLOOPBACK=1"
  if ($VncPw) { $tvnArgs += " SET_USEVNCAUTHENTICATION=1 VALUE_OF_USEVNCAUTHENTICATION=1 SET_PASSWORD=1 VALUE_OF_PASSWORD=$VncPw" }
  choco install tightvnc -y --installArguments "$tvnArgs" 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { Fail "tightvnc install failed" }
  reg add "HKLM\SOFTWARE\TightVNC\Server" /v AllowLoopback /t REG_DWORD /d 1 /f 2>&1 | Out-Null
  reg add "HKLM\SOFTWARE\WOW6432Node\TightVNC\Server" /v AllowLoopback /t REG_DWORD /d 1 /f 2>&1 | Out-Null
  net stop tvnserver 2>&1 | Out-Null
  net start tvnserver 2>&1 | Out-Null
  Start-Process explorer.exe -WindowStyle Hidden
  if (-not (Wait-Port $VncPort 45 2)) { Fail "tightvnc never came up on port $VncPort" }
  $pyBin = if (Get-Command python -ErrorAction SilentlyContinue) { "python" } else { "python3" }
  & $pyBin -m pip install --user --quiet websockify 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { Fail "websockify install failed" }
  $novncDir = Join-Path $RunDir "novnc-1.4.0"
  if (-not (Test-Path $novncDir)) {
    Write-Host "  fetching noVNC (web client)..."
    if (-not (Fetch-Bin "https://github.com/novnc/noVNC/archive/refs/tags/v1.4.0.tar.gz" (Join-Path $RunDir "novnc.tgz"))) { Fail "noVNC download failed" }
    tar -xzf (Join-Path $RunDir "novnc.tgz") -C $RunDir
  }
  if ($VncPw) {
    $selfcheck = Join-Path $RunDir "vnc_selfcheck.py"
    Set-Content -Path $selfcheck -Value @'
import socket, sys, os, hashlib, subprocess
port = int(sys.argv[1])
pw2 = sys.argv[2]
uname = sys.argv[3]
pw30 = sys.argv[4]
import sys

IP = [58,50,42,34,26,18,10,2,60,52,44,36,28,20,12,4,62,54,46,38,30,22,14,6,64,56,48,40,32,24,16,8,57,49,41,33,25,17,9,1,59,51,43,35,27,19,11,3,61,53,45,37,29,21,13,5,63,55,47,39,31,23,15,7]
FP = [40,8,48,16,56,24,64,32,39,7,47,15,55,23,63,31,38,6,46,14,54,22,62,30,37,5,45,13,53,21,61,29,36,4,44,12,52,20,60,28,35,3,43,11,51,19,59,27,34,2,42,10,50,18,58,26,33,1,41,9,49,17,57,25]
E = [32,1,2,3,4,5,4,5,6,7,8,9,8,9,10,11,12,13,12,13,14,15,16,17,16,17,18,19,20,21,20,21,22,23,24,25,24,25,26,27,28,29,28,29,30,31,32,1]
PC1 = [57,49,41,33,25,17,9,1,58,50,42,34,26,18,10,2,59,51,43,35,27,19,11,3,60,52,44,36,63,55,47,39,31,23,15,7,62,54,46,38,30,22,14,6,61,53,45,37,29,21,13,5,28,20,12,4]
P = [16,7,20,21,29,12,28,17,1,15,23,26,5,18,31,10,2,8,24,14,32,27,3,9,19,13,30,6,22,11,4,25]
PC2 = [14,17,11,24,1,5,3,28,15,6,21,10,23,19,12,4,26,8,16,7,27,20,13,2,41,52,31,37,47,55,30,40,51,45,33,48,44,49,39,56,34,53,46,42,50,36,29,32]
SHIFTS = [1,1,2,2,2,2,2,2,1,2,2,2,2,2,2,1]
S = [
[14,4,13,1,2,15,11,8,3,10,6,12,5,9,0,7,0,15,7,4,14,2,13,1,10,6,12,11,9,5,3,8,4,1,14,8,13,6,2,11,15,12,9,7,3,10,5,0,15,12,8,2,4,9,1,7,5,11,3,14,10,0,6,13],
[15,1,8,14,6,11,3,4,9,7,2,13,12,0,5,10,3,13,4,7,15,2,8,14,12,0,1,10,6,9,11,5,0,14,7,11,10,4,13,1,5,8,12,6,9,3,2,15,13,8,10,1,3,15,4,2,11,6,7,12,0,5,14,9],
[10,0,9,14,6,3,15,5,1,13,12,7,11,4,2,8,13,7,0,9,3,4,6,10,2,8,5,14,12,11,15,1,13,6,4,9,8,15,3,0,11,1,2,12,5,10,14,7,1,10,13,0,6,9,8,7,4,15,14,3,11,5,2,12],
[7,13,14,3,0,6,9,10,1,2,8,5,11,12,4,15,13,8,11,5,6,15,0,3,4,7,2,12,1,10,14,9,10,6,9,0,12,11,7,13,15,1,3,14,5,2,8,4,3,15,0,6,10,1,13,8,9,4,5,11,12,7,2,14],
[2,12,4,1,7,10,11,6,8,5,3,15,13,0,14,9,14,11,2,12,4,7,13,1,5,0,15,10,3,9,8,6,4,2,1,11,10,13,7,8,15,9,12,5,6,3,0,14,11,8,12,7,1,14,2,13,6,15,0,9,10,4,5,3],
[12,1,10,15,9,2,6,8,0,13,3,4,14,7,5,11,10,15,4,2,7,12,9,5,6,1,13,14,0,11,3,8,9,14,15,5,2,8,12,3,7,0,4,10,1,13,11,6,4,3,2,12,9,5,15,10,11,14,1,7,6,0,8,13],
[4,11,2,14,15,0,8,13,3,12,9,7,5,10,6,1,13,0,11,7,4,9,1,10,14,3,5,12,2,15,8,6,1,4,11,13,12,3,7,14,10,15,6,8,0,5,9,2,6,11,13,8,1,4,10,7,9,5,0,15,14,2,3,12],
[13,2,8,4,6,15,11,1,10,9,3,14,5,0,12,7,1,15,13,8,10,3,7,4,12,5,6,11,0,14,9,2,7,11,4,1,9,12,14,2,0,6,10,13,15,3,5,8,2,1,14,7,4,10,8,13,15,12,9,0,3,5,6,11],
]

def bits(data):
    out = []
    for b in data:
        out.extend([(b >> (7 - i)) & 1 for i in range(8)])
    return out

def permute(bt, table):
    return [bt[t - 1] for t in table]

def lrot(bt, n):
    return bt[n:] + bt[:n]

def xor(a, b):
    return [x ^ y for x, y in zip(a, b)]

def subkeys(key):
    k = permute(bits(key), PC1)
    left, right = k[:28], k[28:]
    out = []
    for s in SHIFTS:
        left = lrot(left, s)
        right = lrot(right, s)
        out.append(permute(left + right, PC2))
    return out

def f(right, sub):
    x = permute(right, E)
    x = xor(x, sub)
    res = []
    for i in range(8):
        chunk = x[i * 6:(i + 1) * 6]
        row = (chunk[0] << 1) | chunk[5]
        col = (chunk[1] << 3) | (chunk[2] << 2) | (chunk[3] << 1) | chunk[4]
        v = S[i][row * 16 + col]
        res.extend([(v >> (3 - j)) & 1 for j in range(4)])
    return permute(res, P)

def block(blockbits, keys):
    b = permute(blockbits, IP)
    left, right = b[:32], b[32:]
    for i in range(16):
        prev = left
        left = right
        right = xor(prev, f(right, keys[i]))
    return permute(right + left, FP)

def vnc_key(pw):
    d = pw.encode("utf8").ljust(8, b"\x00")[:8]
    return bytes(int("{:08b}".format(x)[::-1], 2) for x in d)

def des_ecb(key, data):
    keys = subkeys(key)
    assert len(data) % 8 == 0
    out = bytearray()
    for i in range(0, len(data), 8):
        bb = bits(data[i:i + 8])
        res = block(bb, keys)
        for j in range(8):
            v = 0
            for bit in res[j * 8:(j + 1) * 8]:
                v = (v << 1) | bit
            out.append(v)
    return bytes(out)

class Conn:
    def __init__(self):
        self.s = socket.create_connection(("127.0.0.1", port), timeout=15)
        self.b = b""
    def recvn(self, n):
        while len(self.b) < n:
            d = self.s.recv(n - len(self.b))
            if not d:
                raise SystemExit("eof at %d of %d bytes" % (len(self.b), n))
            self.b += d
        out, self.b = self.b[:n], self.b[n:]
        return out
    def hello(self):
        ver = self.recvn(12)
        self.s.sendall(b"RFB 003.008\n")
        n = self.recvn(1)[0]
        if n == 0:
            rl = int.from_bytes(self.recvn(4), "big")
            raise SystemExit("server refused: %s" % self.recvn(rl).decode("utf8", "replace"))
        return ver, list(self.recvn(n))

def reason(c):
    try:
        rl = int.from_bytes(c.recvn(4), "big")
        if rl:
            return c.recvn(rl).decode("utf8", "replace")
    except Exception:
        pass
    return ""

c = Conn()
ver, types = c.hello()
print("server=%s types=%s" % (ver.decode("latin1").strip(), types))
results = {}
if 2 in types and pw2:
    try:
        c.s.sendall(bytes([2]))
        ch = c.recvn(16)
        c.s.sendall(des_ecb(vnc_key(pw2), ch))
        res = int.from_bytes(c.recvn(4), "big")
        if res != 0:
            print("type2 rejected: %s" % reason(c).strip())
        results[2] = res
    except SystemExit as e:
        results[2] = str(e)
if 30 in types and uname and pw30:
    try:
        c2 = Conn()
        v2, t2 = c2.hello()
        c2.s.sendall(bytes([30]))
        g = int.from_bytes(c2.recvn(2), "big")
        klen = int.from_bytes(c2.recvn(2), "big")
        prime = int.from_bytes(c2.recvn(klen), "big")
        spub = int.from_bytes(c2.recvn(klen), "big")
        e = int.from_bytes(os.urandom(klen), "big")
        cpub = pow(g, e, prime).to_bytes(klen, "big")
        shared = pow(spub, e, prime).to_bytes(klen, "big")
        pad = "".join(chr(65 + b % 26) for b in os.urandom(64))
        pu = (uname[:63] + "\0" + pad)[:64]
        pp = (pw30[:63] + "\0" + pad)[:64]
        creds = (pu + pp).encode("utf8")
        key = hashlib.md5(shared).digest()
        r = subprocess.run(["openssl", "enc", "-aes-128-ecb", "-K", key.hex(), "-nopad"], input=creds, capture_output=True)
        if r.returncode != 0 or len(r.stdout) != 128:
            raise SystemExit("openssl aes failed")
        c2.s.sendall(r.stdout)
        c2.s.sendall(cpub)
        res = int.from_bytes(c2.recvn(4), "big")
        if res != 0:
            print("type30 rejected: %s" % reason(c2).strip())
        results[30] = res
    except SystemExit as e:
        results[30] = str(e)
print("results=%s" % results)
need = 30 if 30 in types else 2
if results.get(need) == 0:
    print("authenticated (type %d)" % need)
else:
    raise SystemExit("auth failed for type %d: %s" % (need, results.get(need, "not tested")))
'@
    Write-Host "  vnc auth self-check..."
    $out = & $pyBin $selfcheck "$VncPort" "$VncPw" "$User" "" 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -and $out -match "authenticated") { $VncAuth = "ok"; Write-Host "  vnc auth self-check: ok" }
    else { $VncAuth = "failed"; Write-Host "  vnc auth self-check: FAILED"; Write-Host $out }
  } else {
    $VncAuth = "skipped (no password)"
  }
  $wsProc = Start-Procx $pyBin @("-c", "from websockify.websocketproxy import websockify_init; websockify_init()", "--web", $novncDir, "$DeskPort", "localhost:$VncPort") "novnc"
  $DeskProcs += $wsProc
  $up = $false
  for ($i = 0; $i -lt 30; $i++) { if (Http-Up $DeskPort "") { $up = $true; break }; Start-Sleep -Seconds 1 }
  if (-not $up) { Get-Content (Join-Path $RunDir "novnc.log") -ErrorAction SilentlyContinue; Fail "noVNC failed to start" }
  $DeskOk = $true
  Write-Host " desktop is up"
}

$TunnelProcs = @()
if ($env:CF_TUNNEL_TOKEN) {
  $Named = $true
  Write-Host "  starting named cloudflare tunnel (hostnames come from your Cloudflare dashboard)..."
  $np = Start-Procx (Join-Path $BinDir "cloudflared.exe") @("tunnel", "run", "--token", $env:CF_TUNNEL_TOKEN, "--no-autoupdate") "named-tunnel"
  $TunnelProcs += $np
  $up = $false
  for ($i = 0; $i -lt 45; $i++) {
    $nl = Join-Path $RunDir "named-tunnel.log"
    if ((Test-Path $nl) -and (Select-String -Path $nl -Pattern "Registered tunnel connection" -Quiet)) { $up = $true; break }
    if ($np.HasExited) { break }
    Start-Sleep -Seconds 2
  }
  if ($up) {
    if ($NeedTtyd) { $UrlTerm = "named-tunnel" }
    if ($CodeOk) { $UrlCode = "named-tunnel" }
    if ($DeskOk) { $UrlDesk = "named-tunnel" }
    Write-Host " named tunnel is up"
  } else {
    Get-Content (Join-Path $RunDir "named-tunnel.log") -Tail 10 -ErrorAction SilentlyContinue
    Fail "named tunnel failed to connect (check the token and your Cloudflare dashboard)"
  }
} else {
  if ($NeedTtyd) {
    Write-Host "  opening terminal tunnel..."
    $tp = Start-Tunnel $TermPort "term-tunnel"
    $TunnelProcs += $tp
    $UrlTerm = Wait-Tunnel "term-tunnel" $tp
    if (-not $UrlTerm) { Get-Content (Join-Path $RunDir "term-tunnel.log") -ErrorAction SilentlyContinue; Fail "terminal tunnel failed" }
  }
  if ($CodeOk) {
    Write-Host "  opening vscode tunnel..."
    $cp = Start-Tunnel $CodePort "code-tunnel"
    $TunnelProcs += $cp
    $UrlCode = Wait-Tunnel "code-tunnel" $cp
    if (-not $UrlCode) {
      if ($CodeRequired) { Get-Content (Join-Path $RunDir "code-tunnel.log") -ErrorAction SilentlyContinue; Fail "vscode tunnel failed but stack=vscode needs it" }
      Write-Host "  vscode tunnel failed, continuing terminal-only"
      $CodeOk = $false
    }
  }
}

if ($DeskOk -and -not $Named) {
  Write-Host "  opening desktop tunnel..."
  $dp = Start-Tunnel $DeskPort "desk-tunnel"
  $TunnelProcs += $dp
  $UrlDesk = Wait-Tunnel "desk-tunnel" $dp
  if (-not $UrlDesk) { Get-Content (Join-Path $RunDir "desk-tunnel.log") -ErrorAction SilentlyContinue; Fail "desktop tunnel failed" }
  $UrlDesk = "$UrlDesk/vnc.html?autoconnect=true&resize=scale"
}

$envContent = @"
GIECKO_URL_TERM='$UrlTerm'
GIECKO_URL_CODE='$UrlCode'
GIECKO_URL_DESK='$UrlDesk'
GIECKO_USER='$User'
GIECKO_RUN_ID='$RunId'
GIECKO_REGION='$Region'
GIECKO_STACK='$Stack'
GIECKO_DISTRO='$DistroEff'
GIECKO_WORK_BRANCH='$WorkBranch'
GIECKO_END_EPOCH='$EndEpoch'
GIECKO_AUTOSAVE_MIN='$AutosaveI'
GIECKO_BOOT_SECS='$BootSecs'
GIECKO_NAMED='$Named'
GIECKO_PERSIST='$PersistHome'
"@
$BootSecs = [int]((Get-Date) - $BootStart).TotalSeconds
$EndEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + $DurationI * 60 - $BootSecs
if ($env:GIECKO_CONFIG_DIR) {
  New-Item -ItemType Directory -Force -Path $env:GIECKO_CONFIG_DIR | Out-Null
  Set-Content -Path (Join-Path $env:GIECKO_CONFIG_DIR "giecko.env") -Value $envContent
} else {
  Set-Content -Path (Join-Path $env:USERPROFILE ".giecko.env") -Value $envContent
}
$DispTerm = Pub-Url $UrlTerm
$DispCode = Pub-Url $UrlCode
$DispDesk = Pub-Url $UrlDesk
if ($Named) { $DispTerm = "your Cloudflare hostname"; $DispCode = "your Cloudflare hostname"; $DispDesk = "your Cloudflare hostname" }
$LoginLine = if ($Password) { "user $User + your workflow password" } else { "none -- OPEN SESSION, anyone with the link gets in" }

Write-Host ""
Write-Host "============================================================"
Write-Host "   GIECKO IS LIVE! (booted in $BootSecs s, powershell edition)" -ForegroundColor Green
Write-Host "============================================================"
if ($UrlTerm) { Write-Host "    terminal: $DispTerm" }
if ($UrlCode) { Write-Host "   vscode:    $DispCode" }
if ($UrlDesk) { Write-Host "   desktop:   $DispDesk" }
if ($UrlDesk -and $Password) { Write-Host "   desktop login: type the FIRST 8 characters of your password" }
Write-Host "   login: $LoginLine"
Write-Host "   runner region: $Region -- typing lag is your distance to here"
Write-Host "   shell: $DistroEff on windows / stack: $Stack"
Write-Host "   files: branch '$WorkBranch'"
Write-Host "   alive ~$DurationI min / backup: run 'giecko save' (autosave: $(if ($AutosaveI -gt 0) { "every $AutosaveI m" } else { 'off' }))"
Write-Host "   QR codes: skipped on windows (no qrencode); copy the URLs instead"
Write-Host "============================================================"
Write-Host " code feels laggy in raw terminal? Use the vscode URL -- the editor types instantly."
Write-Host ""

Write-Host "::notice::giecko-live term=$(if ($DispTerm) { $DispTerm } else { 'none' }) code=$(if ($DispCode) { $DispCode } else { 'none' }) desk=$(if ($DispDesk) { $DispDesk } else { 'none' }) boot=${BootSecs}s region=$Region stack=$Stack distro=$DistroEff auth=$(if ($Password) { 'on' } else { 'OFF' }) run=$RunId work=$WorkBranch"

if ($env:GITHUB_STEP_SUMMARY) {
  $summary = @()
  $summary += "##  Giecko is live!"
  $summary += ""
  $summary += "| | |"
  $summary += "|---|---|"
  if ($Named) {
    if ($NeedTtyd) { $summary += "| **Terminal** | your Cloudflare hostname (named tunnel) |" }
    if ($CodeOk) { $summary += "| **VS Code** | your Cloudflare hostname (named tunnel) |" }
    if ($DeskOk) { $summary += "| **Desktop** | your Cloudflare hostname (named tunnel) |" }
  } else {
    if ($UrlTerm) { if ($Mask -eq "1") { $summary += "| **Terminal** | ``$DispTerm`` (masked)" } else { $summary += "| **Terminal** | [$UrlTerm]($UrlTerm) |" } }
    if ($UrlCode) { if ($Mask -eq "1") { $summary += "| **VS Code** | ``$DispCode`` (masked)" } else { $summary += "| **VS Code** | [$UrlCode]($UrlCode) |" } }
    if ($UrlDesk) { if ($Mask -eq "1") { $summary += "| **Desktop** | ``$DispDesk`` (masked)" } else { $summary += "| **Desktop** | [open desktop]($UrlDesk) |" } }
  }
  $summary += "| **Login** | $LoginLine |"
  $summary += "| **Region** | ``$Region`` |"
  $summary += "| **Stack** | ``$Stack`` on ``$DistroEff`` (windows) |"
  $summary += "| **Expires in** | ~$DurationI min |"
  $summary += ""
  $summary += " Save work with ``giecko save``"
  $summary += " Files live on branch ``$WorkBranch``"
  Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value ($summary -join "`n")
}

if ($env:GITHUB_OUTPUT) {
  Add-Content -Path $env:GITHUB_OUTPUT -Value "url=$UrlTerm"
  if ($UrlCode) { Add-Content -Path $env:GITHUB_OUTPUT -Value "url_code=$UrlCode" }
  if ($UrlDesk) { Add-Content -Path $env:GITHUB_OUTPUT -Value "url_desk=$UrlDesk" }
}

try { Publish-Report "live" "booted in $BootSecs s (powershell)" | Out-Null } catch {}

$gieckoCli = if (Test-Path (Join-Path $PSScriptRoot "giecko")) { Join-Path $PSScriptRoot "giecko" } else { "" }
$bashBin = Get-Command bash -ErrorAction SilentlyContinue
$LastSave = Get-Date

$End = (Get-Date).AddMinutes($DurationI)
while ((Get-Date) -lt $End) {
  if ($NeedTtyd -and $TtydProc -and $TtydProc.HasExited) { Get-Content (Join-Path $RunDir "ttyd.log") -Tail 20 -ErrorAction SilentlyContinue; Fail "ttyd died mid-run" }
  if ($Named) {
    $np2 = $TunnelProcs | Select-Object -First 1
    if ($np2 -and $np2.HasExited) { Get-Content (Join-Path $RunDir "named-tunnel.log") -Tail 20 -ErrorAction SilentlyContinue; Fail "named tunnel died mid-run" }
  } elseif ($NeedTtyd -and $TunnelProcs.Count -gt 0) {
    $tp2 = $TunnelProcs[0]
    if ($tp2 -and $tp2.HasExited) { Get-Content (Join-Path $RunDir "term-tunnel.log") -Tail 20 -ErrorAction SilentlyContinue; Fail "terminal tunnel died mid-run" }
  }
  if ($CodeOk -and $CodeProc -and $CodeProc.HasExited) {
    if ($CodeRequired) { Fail "vscode side died mid-run (stack=vscode)" }
    $CodeOk = $false
    if (-not $CodeWarned) { Write-Host "  vscode side died mid-run, terminal continues"; $CodeWarned = $true }
  }
  if ($DeskOk) {
    foreach ($dp2 in $DeskProcs) { if ($dp2 -and $dp2.HasExited) { Get-Content (Join-Path $RunDir "novnc.log") -Tail 20 -ErrorAction SilentlyContinue; Fail "noVNC died mid-run" } }
  }
  if ($AutosaveI -gt 0 -and $gieckoCli -and $bashBin -and ((Get-Date) - $LastSave).TotalMinutes -ge $AutosaveI) {
    Push-Location $WorkDir
    & bash $gieckoCli save --quiet 2>$null
    Pop-Location
    $LastSave = Get-Date
    Write-Host " autosave done"
  }
  $Heartbeats++
  $RemMin = [int](($End - (Get-Date)).TotalMinutes)
  $disp = if ($DispTerm) { $DispTerm } else { $DispCode }
  Write-Host " alive -- ~$RemMin m left -- $disp -- $((Get-Date).ToUniversalTime().ToString('HH:mm:ss')) UTC"
  Start-Sleep -Seconds 60
}

if ($DurationI -eq 0) {
  Write-Host " quick check done (tunnels verified, shutting down)."
} else {
  Write-Host " time's up ($DurationI min). Final backup..."
}
if ($gieckoCli -and $bashBin) {
  Push-Location $WorkDir
  & bash $gieckoCli save --quiet 2>$null
  Pop-Location
}
try { Publish-Report "completed" "$Heartbeats heartbeats (powershell)" | Out-Null } catch {}
Write-Host "Bye!"

