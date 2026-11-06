$ErrorActionPreference = 'Stop'
$lessonRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$lessonPython = 'D:/smolagents/.venv/Scripts/python.exe'
$lessonGodot = Join-Path $lessonRoot 'tools/godot/Godot_v4.7.2-stable_win64_console.exe'
if (-not (Test-Path -LiteralPath $lessonPython)) { throw 'The configured smolagents Python runtime is missing.' }
$env:PYTHONIOENCODING = 'utf-8'
$lessonService = Get-NetTCPConnection -State Listen -LocalPort 7322 -ErrorAction SilentlyContinue
if (-not $lessonService) {
    Start-Process -FilePath $lessonPython -ArgumentList @('tools/lesson/run_agent.py', '--serve') -WorkingDirectory $lessonRoot -WindowStyle Hidden
}
# The scene is intentionally visible: it is the student's interactive sandbox.
& $lessonGodot --path (Join-Path $lessonRoot 'game') scenes/lessons/agent_transport.tscn --resolution 1920x1080
