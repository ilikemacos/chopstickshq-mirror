# chopsticksAI Windows installer — analog of:
#   curl -fsSL https://chopstickshq.com/chopsticks-ai/install-chopsticks-ai.sh | bash
#
# Run:
#   irm https://chopstickshq.com/chopsticks-ai/install-chopsticks-ai.ps1 | iex

$ErrorActionPreference = "Stop"
$Base = "https://chopstickshq.com/chopsticks-ai"
$CliBase = "$Base/cli"
$Dest = Join-Path $env:LOCALAPPDATA "chopsticks-ai\cli"
$Bin = Join-Path $env:USERPROFILE "bin"
$Web = "https://chopstickshq.com/chopsticks-ai/web/"

Write-Host "chopsticksAI Installer (Windows)"
if ($PSVersionTable.PSVersion.Major -lt 5) {
  throw "PowerShell 5+ is required."
}

New-Item -ItemType Directory -Force -Path $Dest | Out-Null
New-Item -ItemType Directory -Force -Path $Bin | Out-Null

$files = @("csai.py", "csai_tui.py", "csai_client.py", "csai_update.py", "csai.cmd")
foreach ($name in $files) {
  $url = "$CliBase/$name"
  $out = Join-Path $Dest $name
  Write-Host "Downloading $name..."
  Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing
}

$launcher = Join-Path $Bin "csai.cmd"
@(
  "@echo off"
  "call `"$Dest\csai.cmd`" %*"
) | Set-Content -Encoding ASCII $launcher

$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if (-not $userPath) { $userPath = "" }
$parts = $userPath -split ";" | Where-Object { $_ -ne "" }
if ($parts -notcontains $Bin) {
  [Environment]::SetEnvironmentVariable("Path", ($userPath.TrimEnd(";") + ";" + $Bin), "User")
  $env:Path = $Bin + ";" + $env:Path
  Write-Host "Added $Bin to your user PATH."
}

$programs = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"
New-Item -ItemType Directory -Force -Path $programs | Out-Null
$w = New-Object -ComObject WScript.Shell

$webLnk = $w.CreateShortcut((Join-Path $programs "cs.AI-3.lnk"))
$edge = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
if (-not (Test-Path $edge)) { $edge = "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe" }
if (Test-Path $edge) {
  $webLnk.TargetPath = $edge
  $webLnk.Arguments = "--app=$Web"
} else {
  $webLnk.TargetPath = "https://chopstickshq.com/chopsticks-ai/web/"
}
$webLnk.Description = "cs.AI-3 web app"
$webLnk.Save()

$cliLnk = $w.CreateShortcut((Join-Path $programs "cs.AI CLI.lnk"))
$cliLnk.TargetPath = "cmd.exe"
$cliLnk.Arguments = "/k `"$launcher`""
$cliLnk.WorkingDirectory = $Dest
$cliLnk.Description = "cs.AI terminal CLI"
$cliLnk.Save()

Write-Host ""
Write-Host "Installed cs.AI CLI to $Dest"
Write-Host "Start Menu: cs.AI-3 (web app) and cs.AI CLI"
Write-Host "Needs Python 3.9+ (https://www.python.org/downloads/  — tick Add python.exe to PATH)"
Write-Host "Open a new terminal, then:  csai --plain"
Write-Host "Full-screen TUI (optional):  pip install windows-curses   then   csai"
