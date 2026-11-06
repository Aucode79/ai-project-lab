param([switch]$LinearSearchSample)

$ErrorActionPreference = 'Stop'
$labRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
if ($LinearSearchSample) { $env:AGENT_LAB_SAMPLE = 'linear_search' } else { Remove-Item Env:AGENT_LAB_SAMPLE -ErrorAction SilentlyContinue }
$labPython = if ($env:AGENT_LAB_PYTHON) { $env:AGENT_LAB_PYTHON } else { 'D:/smolagents/.venv/Scripts/python.exe' }
if (-not (Test-Path -LiteralPath $labPython)) { throw '请设置 AGENT_LAB_PYTHON，指向已安装 openai 的 Python 环境。' }
$env:PYTHONIOENCODING = 'utf-8'
if (-not (Get-NetTCPConnection -State Listen -LocalPort 7332 -ErrorAction SilentlyContinue)) {
    Start-Process -FilePath $labPython -ArgumentList @('tools/lesson/lab_service.py') -WorkingDirectory $labRoot -WindowStyle Hidden
}
& (Join-Path $labRoot 'tools/godot/Godot_v4.7.2-stable_win64_console.exe') --path (Join-Path $labRoot 'game') scenes/lessons/agent_lab.tscn --resolution 1920x1080 --max-fps 30
