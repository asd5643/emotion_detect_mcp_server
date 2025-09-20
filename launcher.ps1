# =================== Lemonade Launcher (PS 5.1 compatible) ===================
# Start/Stop & One-Click All:
# - Docker Desktop + MySQL container (mysql80, restart unless-stopped)
# - Lemonade Server via conda (env "agent_test"): lemonade-server-dev serve
# - Python App via conda (env "agent_test"): python <your_app>.py
# Notes:
# - No unapproved verbs; no use of $args; PS 5.1 compatible
# - Custom NoFocusCueButton removes blue focus rectangles on buttons
# ============================================================================

$ErrorActionPreference = "Stop"

# ------------ CONFIG ------------
$MiniforgeRoot = Join-Path $env:USERPROFILE "miniforge3"
$CondaBat      = Join-Path $MiniforgeRoot "condabin\conda.bat"

# 都使用 agent_test
$EnvLemon   = "agent_test"
$EnvAgent   = "agent_test"

# Python 入口（空字串則停用按鈕）
$PythonAppPath = "$PSScriptRoot\python-agent\python_agent.py"  # TODO: change or leave empty

# Emotion MCP server 入口（空字串則停用按鈕）
$EmotionServerPath = Join-Path $PSScriptRoot "servers\emotion_detection_mcp.py"

$ContainerName = "mysql80"
$DataDir       = Join-Path $env:USERPROFILE "mysql-data"
$RootCredFile  = Join-Path $PSScriptRoot "mysql-credentials.txt"

# Track spawned windows (script-scope)
$script:LemonadeProc    = $null
$script:PythonProc      = $null
$script:EmotionProc     = $null
$script:DelayTimer      = $null   # <= for delayed Python start
$script:LemonDelayTimer = $null   # <= for delayed Lemonade start

# --------------------------------

# ------------ Helpers ------------
function Write-Log {
  param([string]$Message)
  $timestamp = (Get-Date).ToString("HH:mm:ss")
  $script:LogBox.AppendText("[$timestamp] $Message`r`n")
  $script:LogBox.ScrollToCaret()

}

function Test-DockerReady {
  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Log "Docker CLI not found. Please install Docker Desktop."
    return $false
  }

  if (-not (Get-Process -Name "Docker Desktop" -ErrorAction SilentlyContinue)) {
    $dockerExe = Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe"
    if (Test-Path $dockerExe) {
      Write-Log "Starting Docker Desktop..."
      Start-Process $dockerExe | Out-Null
    }
  }

  Write-Log "Waiting for Docker daemon..."
  $ready = $false
  $old = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    for ($i=0; $i -lt 60 -and -not $ready; $i++) {
      $p = Start-Process -FilePath "cmd.exe" -ArgumentList "/c","docker info >NUL 2>&1" -PassThru -WindowStyle Hidden -Wait
      if ($p.ExitCode -eq 0) { $ready = $true; break }
      Start-Sleep -Seconds 3
    }
  } finally {
    $ErrorActionPreference = $old
  }

  if (-not $ready) {
    Write-Log "Docker daemon not ready. Please open Docker Desktop and retry."
    return $false
  }
  Write-Log "Docker is ready."
  return $true
}

function Get-FirstFreePort {
  param([int]$Start = 3306)
  $p = $Start
  while ((netstat -ano | Select-String "LISTENING\s+.*:$p\s")) { $p++ }
  return $p
}

function Start-MySQLContainer {
  if (-not (Test-DockerReady)) { return $false }

  $hostPort = $null
  $rootPwd  = $null
  if (Test-Path $RootCredFile) {
    foreach ($line in Get-Content $RootCredFile -Encoding ASCII) {
      if ($line -like "HOST_PORT=*") { $hostPort = $line.Split("=")[1].Trim() }
      if ($line -like "ROOT_PASSWORD=*") { $rootPwd = $line.Split("=")[1].Trim() }
    }
  }
  if (-not $hostPort) { $hostPort = Get-FirstFreePort -Start 3306 }
  if (-not $rootPwd)  { $rootPwd  = "Root" + (Get-Random) }

  Write-Log "Starting container '$ContainerName' (if exists)..."
  docker start $ContainerName *> $null
  if ($LASTEXITCODE -ne 0) {
    New-Item -ItemType Directory -Force $DataDir | Out-Null
    Write-Log "Creating container '$ContainerName' on port $hostPort with persistent data..."
    $dockerArgs = @(
      "run","-d","--name",$ContainerName,
      "--restart","unless-stopped",
      "-p","$($hostPort):3306",
      "-v",("$DataDir" + ":/var/lib/mysql"),
      "-e","MYSQL_ROOT_PASSWORD=$rootPwd",
      "-e","MYSQL_DATABASE=mcp-test",
      "-e","MYSQL_USER=mcp",
      "-e","MYSQL_PASSWORD=123456",
      "mysql:8.4"
    )
    docker @dockerArgs
    if ($LASTEXITCODE -ne 0) {
      Write-Log "Failed to run mysql:8.4 container."
      return $false
    }
    "ROOT_PASSWORD=$rootPwd`r`nHOST_PORT=$hostPort" | Set-Content -Path $RootCredFile -Encoding ASCII
    Write-Log "Saved credentials to: $RootCredFile"
    if ($script:lblCredPath) { $script:lblCredPath.Text = "Credentials file: $RootCredFile" }
  }

  Write-Log "Waiting for MySQL to accept connections on $hostPort..."
  $deadline = (Get-Date).AddMinutes(2)
  $ready = $false
  while (-not $ready -and (Get-Date) -lt $deadline) {
    $t = Test-NetConnection -ComputerName 127.0.0.1 -Port $hostPort
    if ($t.TcpTestSucceeded) { $ready = $true; break }
    Start-Sleep -Seconds 2
  }
  if (-not $ready) {
    Write-Log "MySQL not ready on port $hostPort."
    return $false
  }

  Write-Log "MySQL running. Port=$hostPort  (user=mcp / pass=123456)"

  # 同步 agent.json 的 --port
  try {
    $updateScript = Join-Path $PSScriptRoot "scripts\update-agent-json.ps1"
    if (Test-Path $updateScript) {
      & powershell -NoProfile -ExecutionPolicy Bypass -File $updateScript `
        -AgentJsonPath (Join-Path $PSScriptRoot "agent.json") `
        -ContainerName $ContainerName `
        -StatePath $RootCredFile
      Write-Log "agent.json port sync done."
    } else {
      Write-Log "update-agent-json.ps1 not found; skipped port sync."
    }
  } catch {
    Write-Log "agent.json port sync failed: $($_.Exception.Message)"
  }

  return $true
}

function Stop-MySQLContainer {
  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Log "Docker CLI not found."
    return
  }
  Write-Log "Stopping container '$ContainerName'..."
  docker stop $ContainerName *> $null
  if ($LASTEXITCODE -eq 0) { Write-Log "MySQL container stopped." }
  else { Write-Log "No running container named '$ContainerName'." }
}

function Test-DockerStopped {
  $cli = $false; $svc = $false; $proc = $false; $wsl = $false
  try { docker info *> $null; $cli = ($LASTEXITCODE -eq 0) } catch {}
  try { $s = Get-Service com.docker.service -ErrorAction SilentlyContinue; if ($s -and $s.Status -eq 'Running') { $svc = $true } } catch {}
  try { $p = Get-Process "Docker Desktop","com.docker.backend","com.docker.build","dockerd","DockerCli","vpnkit" -ErrorAction SilentlyContinue; if ($p) { $proc = $true } } catch {}
  try {
    $w = wsl -l -v 2>$null
    $wsl = [bool]( ($w | Select-String 'docker-desktop\s+\d+\s+Running') -or ($w | Select-String 'docker-desktop-data\s+\d+\s+Running') )
  } catch {}
  $stopped = -not ($cli -or $svc -or $proc -or $wsl)
  if ($stopped) { Write-Log "=> Docker daemon appears STOPPED." } else { Write-Log "=> Docker daemon appears RUNNING." }
  return $stopped
}

function Stop-DockerDesktop {
  Write-Log "Stopping Docker Desktop (force)..."
  $isAdmin = $false
  try {
    $wp = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $isAdmin = $wp.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch {}

  try { $ids = docker ps -q 2>$null; if ($ids) { $ids | ForEach-Object { docker stop $_ *> $null } } } catch {}
  if ($isAdmin) {
    try { & sc.exe stop com.docker.service | Out-Null } catch {}
    $deadline = (Get-Date).AddSeconds(20)
    do {
      $s = Get-Service com.docker.service -ErrorAction SilentlyContinue
      if (-not $s -or $s.Status -ne 'Running') { break }
      Start-Sleep -Milliseconds 800
    } while ((Get-Date) -lt $deadline)
  } else {
    Write-Log "Not elevated: skipping Windows service stop (run launcher as Administrator for full quit)."
  }

  foreach ($name in @('com.docker.build','com.docker.backend','Docker Desktop','dockerd','DockerCli','vpnkit')) {
    try { Get-Process -Name $name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}
  }
  foreach ($d in @('docker-desktop','docker-desktop-data')) {
    try { wsl.exe -t $d 2>$null } catch {}
  }

  if (Test-DockerStopped) { Write-Log "Docker Desktop has been stopped." }
  else { Write-Log "Docker still appears to be running. Try running this launcher as Administrator or quit from the Docker tray menu." }
}

function Start-EmotionServer {
  if (-not $EmotionServerPath -or -not (Test-Path $EmotionServerPath)) {
    Write-Log "Emotion MCP path not set or not found: $EmotionServerPath"
    return
  }
  if (-not (Test-Path $CondaBat)) {
    Write-Log "conda.bat not found at $CondaBat"
    return
  }
  if ($script:EmotionProc -and -not $script:EmotionProc.HasExited) {
    Write-Log "Emotion MCP window already running (PID $($script:EmotionProc.Id))."
    return
  }

  $tmpCmd = Join-Path $env:TEMP "launch-emotion-mcp.cmd"
  $cmdText = @"
@echo off
title Emotion MCP
chcp 65001 >NUL
call "$CondaBat" activate $EnvAgent
set PYTHONUNBUFFERED=1
set PYTHONIOENCODING=utf-8
set FORCE_COLOR=1
echo [Emotion MCP] Using interpreter:
where python
python -V
echo.
echo [Emotion MCP] Running: "$EmotionServerPath"
echo ------------------------------------------------------------
python "$EmotionServerPath"
echo ------------------------------------------------------------
echo [Emotion MCP] Process exited with code %ERRORLEVEL%
"@
  Set-Content -Path $tmpCmd -Value $cmdText -Encoding ASCII

  Write-Log "Starting Emotion MCP via $tmpCmd ..."
  $script:EmotionProc = Start-Process -FilePath "cmd.exe" -ArgumentList "/k","`"$tmpCmd`"" -PassThru
  Write-Log "Emotion MCP window PID: $($script:EmotionProc.Id)"
}

function Stop-EmotionServer {
  Write-Log "Stopping Emotion MCP window..."
  if ($script:EmotionProc -and -not $script:EmotionProc.HasExited) {
    try {
      Start-Process -FilePath "taskkill.exe" -ArgumentList "/PID",$script:EmotionProc.Id,"/T","/F" -WindowStyle Hidden -Wait
    } catch {}
    $script:EmotionProc = $null
    Start-Sleep -Milliseconds 200
  }
  try {
    Start-Process -FilePath "taskkill.exe" -ArgumentList '/FI','WINDOWTITLE eq "Emotion MCP"','/T','/F' -WindowStyle Hidden -Wait
  } catch {}
  try {
    Get-Process -Name "cmd" -ErrorAction SilentlyContinue | ForEach-Object {
      try { if ($_.MainWindowTitle -like "*Emotion MCP*") { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } } catch {}
    }
  } catch {}
  Write-Log "Emotion MCP stop requested."
}

function Start-LemonadeServer {
  if (-not (Test-Path $CondaBat)) {
    Write-Log "conda.bat not found at $CondaBat"
    return
  }
  if ($script:LemonadeProc -and -not $script:LemonadeProc.HasExited) {
    Write-Log "Lemonade Server window already running (PID $($script:LemonadeProc.Id))."
    return
  }

  # 用暫存 .cmd（在 agent_test 啟動 lemonade）
  $tmpCmd = Join-Path $env:TEMP "launch-lemonade.cmd"
  $cmdText = @"
@echo off
title Lemonade Server
call "$CondaBat" activate $EnvLemon
set PYTHONUNBUFFERED=1
set PYTHONIOENCODING=utf-8
set FORCE_COLOR=1
lemonade-server-dev serve
"@
  Set-Content -Path $tmpCmd -Value $cmdText -Encoding ASCII

  Write-Log "Starting Lemonade Server via $tmpCmd (env=$EnvLemon)..."
  $script:LemonadeProc = Start-Process -FilePath "cmd.exe" -ArgumentList "/k","`"$tmpCmd`"" -PassThru
  Write-Log "Lemonade Server window PID: $($script:LemonadeProc.Id)"
}

function Start-LemonadeServer-AfterDelay {
  param([int]$Seconds = 5)

  if ($script:LemonadeProc -and -not $script:LemonadeProc.HasExited) {
    Write-Log "Lemonade Server already running (PID $($script:LemonadeProc.Id)). Skip delayed start."
    return
  }
  if ($script:LemonDelayTimer) {
    try { $script:LemonDelayTimer.Stop() } catch {}
    $script:LemonDelayTimer = $null
  }

  Write-Log ("Waiting {0}s before starting Lemonade Server..." -f $Seconds)

  $timer = New-Object System.Windows.Forms.Timer
  $timer.Interval = [Math]::Max(1, $Seconds) * 1000
  $timer.Add_Tick({
    try {
      $script:LemonDelayTimer.Stop()
      $script:LemonDelayTimer = $null
      Write-Log "Delay done. Starting Lemonade Server now."
      Start-LemonadeServer
    } catch {
      Write-Log ("Lemonade delayed start failed: " + $_.Exception.Message)
    }
  })
  $script:LemonDelayTimer = $timer
  $script:LemonDelayTimer.Start()
}

function Stop-LemonadeServer {
  Write-Log "Stopping Lemonade Server..."
  if ($script:LemonadeProc -and -not $script:LemonadeProc.HasExited) {
    try { Start-Process -FilePath "taskkill.exe" -ArgumentList "/PID",$script:LemonadeProc.Id,"/T","/F" -WindowStyle Hidden -Wait } catch {}
    $script:LemonadeProc = $null
    Start-Sleep -Milliseconds 300
  }
  try {
    Start-Process -FilePath "taskkill.exe" -ArgumentList '/FI','WINDOWTITLE eq "Lemonade Server"','/T','/F' -WindowStyle Hidden -Wait
  } catch {}
  try {
    $procs = Get-CimInstance Win32_Process -Filter "Name='python.exe'" |
             Where-Object { $_.CommandLine -match 'lemonade-server-dev' }
    foreach ($p in $procs) {
      try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
    }
  } catch {}
  Write-Log "Lemonade Server stop requested."
}

function Start-PythonApp-AfterDelay {
  param([int]$Seconds = 10)
  if (-not $PythonAppPath -or -not (Test-Path $PythonAppPath)) {
    Write-Log "Python app path not set or not found: $PythonAppPath"
    return
  }
  if ($script:PythonProc -and -not $script:PythonProc.HasExited) {
    Write-Log "Python App already running (PID $($script:PythonProc.Id)). Skip delayed start."
    return
  }
  if ($script:DelayTimer) {  # 避免重複排程
    try { $script:DelayTimer.Stop() } catch {}
    $script:DelayTimer = $null
  }

  Write-Log ("Waiting {0}s before starting Python App..." -f $Seconds)

  $timer = New-Object System.Windows.Forms.Timer
  $timer.Interval = [Math]::Max(1, $Seconds) * 1000
  $timer.Add_Tick({
    try {
      $script:DelayTimer.Stop()
      $script:DelayTimer = $null
      Write-Log "Delay done. Starting Python App now."
      Start-PythonApp
    } catch {
      Write-Log ("Delayed start failed: " + $_.Exception.Message)
    }
  })
  $script:DelayTimer = $timer
  $script:DelayTimer.Start()
}

function Stop-PythonApp {
  Write-Log "Stopping Python App window..."
  if ($script:PythonProc -and -not $script:PythonProc.HasExited) {
    try {
      Start-Process -FilePath "taskkill.exe" -ArgumentList "/PID",$script:PythonProc.Id,"/T","/F" -WindowStyle Hidden -Wait
    } catch {}
    $script:PythonProc = $null
    Start-Sleep -Milliseconds 200
  }
  try {
    Start-Process -FilePath "taskkill.exe" -ArgumentList '/FI','WINDOWTITLE eq "Python App"','/T','/F' -WindowStyle Hidden -Wait
  } catch {}
  try {
    Get-Process -Name "cmd" -ErrorAction SilentlyContinue | ForEach-Object {
      try { if ($_.MainWindowTitle -like "*Python App*") { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } } catch {}
    }
  } catch {}
  Write-Log "Python App stop requested."
}

# ----- One-Click All -----
function Start-All {
  Write-Log "=== ONE-CLICK START ==="
  $okDb = Start-MySQLContainer
  if ($okDb) {
    # 先開 Emotion MCP（你要的順序）
    Start-EmotionServer

    # 再開 Lemonade Server
    Start-LemonadeServer-AfterDelay -Seconds 5

    # 最後（可選）延遲開 Python App
    if ($PythonAppPath -and (Test-Path $PythonAppPath)) {
      Start-PythonApp-AfterDelay -Seconds 10
    } else {
      Write-Log "Python App path missing; skip delayed start."
    }
  } else {
    Write-Log "Skip Emotion/Lemonade/Python start due to DB failure."
  }
  Write-Log "=== START INITIATED (Python will start after delay if configured) ==="
}

function Stop-All {
  Write-Log "=== ONE-CLICK STOP ==="
  Stop-PythonApp
  Stop-LemonadeServer
  Stop-EmotionServer
  Stop-MySQLContainer
  Write-Log "=== STOP DONE ===  (Docker Desktop still running; use 'Quit Docker Desktop' if needed)"
}

function Start-PythonApp {
  if (-not $PythonAppPath -or -not (Test-Path $PythonAppPath)) {
    Write-Log "Python app path not set or not found: $PythonAppPath"
    return
  }
  #if (-not (Test-Path $CondaBat)) {
  #  Write-Log "conda.bat not found at $CondaBat"
  #  return
  #}
  if ($script:PythonProc -and -not $script:PythonProc.HasExited) {
    Write-Log "Python App GUI already running (PID $($script:PythonProc.Id))."
    return
  }

  $guiClient = Join-Path $PSScriptRoot "gui_client.py"

  if (-not (Test-Path $guiClient)) {
      Write-Host "GUI client not found: $guiClient"
      return
  }

  if (-not (Test-Path $PythonAppPath)) {
      Write-Host "Python App not found: $PythonAppPath"
      return
  }

  Write-Log "Starting GUI Client for Python App ..."
  $pythonExe = "python"

  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo.FileName = $pythonExe
  $proc.StartInfo.Arguments = "`"$guiClient`" `"$PythonAppPath`""  # ← 一定要帶上 Python App 路徑
  $proc.StartInfo.UseShellExecute = $false
  $proc.StartInfo.RedirectStandardOutput = $true
  $proc.StartInfo.RedirectStandardError = $true
  $proc.StartInfo.CreateNoWindow = $true

  $proc.Start() | Out-Null
  Write-Log "Python App GUI PID: $($proc.Id)"

  # 等待 GUI Client 輸出第一行訊息
  while (-not $proc.HasExited) {
      $line = $proc.StandardOutput.ReadLine()
      if ($line) {
          Write-Host "收到訊息: $line"
          
          # 收到訊息後立即結束 launcher
          if (-not $proc.HasExited) { Stop-All; $form.Close() }
          Write-Host "Launcher 結束"
          break
      }
  }
}

# --------------------------------

# ------------ WinForms UI (no focus rectangles on buttons) ------------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing `
  -Language CSharp `
  -TypeDefinition @"
using System;
using System.Windows.Forms;

public class NoFocusCueButton : Button
{
    public NoFocusCueButton() : base()
    {
        this.TabStop = false;
    }

    protected override bool ShowFocusCues { get { return false; } }

    public bool IsFocusCuesHidden { get { return true; } }
}
"@

[System.Windows.Forms.Application]::EnableVisualStyles()

$form               = New-Object System.Windows.Forms.Form
$form.Text          = "Lemonade Launcher"
$form.StartPosition = "CenterScreen"
$form.Size          = New-Object System.Drawing.Size(920, 500)
$form.MaximizeBox   = $false
$form.KeyPreview    = $true

# Row 0: One-Click buttons
$btnAllStart              = New-Object NoFocusCueButton
$btnAllStart.Text         = "One-Click START"
$btnAllStart.Size         = New-Object System.Drawing.Size(410, 36)
$btnAllStart.Location     = New-Object System.Drawing.Point(20, 20)
$btnAllStop               = New-Object NoFocusCueButton
$btnAllStop.Text          = "One-Click STOP"
$btnAllStop.Size          = New-Object System.Drawing.Size(410, 36)
$btnAllStop.Location      = New-Object System.Drawing.Point(440, 20)

# Row 1: Start buttons
$btnDockerStart           = New-Object NoFocusCueButton
$btnDockerStart.Text      = "Start Docker + MySQL"
$btnDockerStart.Size      = New-Object System.Drawing.Size(200, 36)
$btnDockerStart.Location  = New-Object System.Drawing.Point(20, 70)

$btnEmotionStart          = New-Object NoFocusCueButton
$btnEmotionStart.Text     = "Start Emotion MCP"
$btnEmotionStart.Size     = New-Object System.Drawing.Size(200, 36)
$btnEmotionStart.Location = New-Object System.Drawing.Point(230, 70)

$btnLemonStart            = New-Object NoFocusCueButton
$btnLemonStart.Text       = "Start Lemonade Server"
$btnLemonStart.Size       = New-Object System.Drawing.Size(200, 36)
$btnLemonStart.Location   = New-Object System.Drawing.Point(440, 70)

$btnPyStart               = New-Object NoFocusCueButton
$btnPyStart.Text          = "Start Python App"
$btnPyStart.Size          = New-Object System.Drawing.Size(200, 36)
$btnPyStart.Location      = New-Object System.Drawing.Point(650, 70)
if (-not $EmotionServerPath -or -not (Test-Path $EmotionServerPath)) { $btnEmotionStart.Enabled = $false }
if (-not $PythonAppPath -or -not (Test-Path $PythonAppPath)) { $btnPyStart.Enabled = $false }

# Row 2: Stop buttons
$btnDockerStop            = New-Object NoFocusCueButton
$btnDockerStop.Text       = "Stop MySQL Container"
$btnDockerStop.Size       = New-Object System.Drawing.Size(200, 34)
$btnDockerStop.Location   = New-Object System.Drawing.Point(20, 112)

$btnEmotionStop           = New-Object NoFocusCueButton
$btnEmotionStop.Text      = "Stop Emotion MCP"
$btnEmotionStop.Size      = New-Object System.Drawing.Size(200, 34)
$btnEmotionStop.Location  = New-Object System.Drawing.Point(230, 112)

$btnLemonStop             = New-Object NoFocusCueButton
$btnLemonStop.Text        = "Stop Lemonade Server"
$btnLemonStop.Size        = New-Object System.Drawing.Size(200, 34)
$btnLemonStop.Location    = New-Object System.Drawing.Point(440, 112)

$btnPyStop                = New-Object NoFocusCueButton
$btnPyStop.Text           = "Stop Python App"
$btnPyStop.Size           = New-Object System.Drawing.Size(200, 34)
$btnPyStop.Location       = New-Object System.Drawing.Point(650, 112)

# Row 3: Docker quit + credentials path
$btnDockerQuit            = New-Object NoFocusCueButton
$btnDockerQuit.Text       = "Quit Docker Desktop"
$btnDockerQuit.Size       = New-Object System.Drawing.Size(200, 30)
$btnDockerQuit.Location   = New-Object System.Drawing.Point(20, 152)

$lblCredPath              = New-Object System.Windows.Forms.Label
$script:lblCredPath       = $lblCredPath
$lblCredPath.Text         = "Credentials file: $RootCredFile"
$lblCredPath.AutoSize     = $true
$lblCredPath.Location     = New-Object System.Drawing.Point(230, 156)

# Log area
$LogBox                   = New-Object System.Windows.Forms.TextBox
$script:LogBox            = $LogBox
$LogBox.Multiline         = $true
$LogBox.ScrollBars        = "Vertical"
$LogBox.ReadOnly          = $true
$LogBox.WordWrap          = $true
$LogBox.Font              = New-Object System.Drawing.Font("Consolas", 9)
$LogBox.Location          = New-Object System.Drawing.Point(20, 190)
$LogBox.Size              = New-Object System.Drawing.Size(860, 220)

$btnClose                 = New-Object NoFocusCueButton
$btnClose.Text            = "Exit"
$btnClose.Size            = New-Object System.Drawing.Size(100, 30)
$btnClose.Location        = New-Object System.Drawing.Point(780, 420)

# 移走初始焦點
$form.Add_Shown({ $form.ActiveControl = $null })

# Events
$btnAllStart.Add_Click({
  try { $btnAllStart.Enabled = $false; Write-Log "=== One-Click START ==="; Start-All }
  finally { $btnAllStart.Enabled = $true }
})
$btnAllStop.Add_Click({
  try { $btnAllStop.Enabled = $false; Write-Log "=== One-Click STOP ==="; Stop-All }
  finally { $btnAllStop.Enabled = $true }
})

$btnDockerStart.Add_Click({
  try { $btnDockerStart.Enabled = $false; Write-Log "=== Docker + MySQL (Start) ==="; if (Start-MySQLContainer) { Write-Log "Docker + MySQL ready." } else { Write-Log "Docker/MySQL start failed." } }
  finally { $btnDockerStart.Enabled = $true }
})
$btnEmotionStart.Add_Click({
  try { $btnEmotionStart.Enabled = $false; Write-Log "=== Emotion MCP (Start) ==="; Start-EmotionServer }
  finally { $btnEmotionStart.Enabled = $true }
})
$btnLemonStart.Add_Click({
  try { $btnLemonStart.Enabled = $false; Write-Log "=== Lemonade Server (Start) ==="; Start-LemonadeServer }
  finally { $btnLemonStart.Enabled = $true }
})
$btnPyStart.Add_Click({
  try { $btnPyStart.Enabled = $false; Write-Log "=== Python App (Start) ==="; Start-PythonApp }
  finally { $btnPyStart.Enabled = $true }
})

$btnDockerStop.Add_Click({
  try { $btnDockerStop.Enabled = $false; Write-Log "=== MySQL Container (Stop) ==="; Stop-MySQLContainer }
  finally { $btnDockerStop.Enabled = $true }
})
$btnEmotionStop.Add_Click({
  try { $btnEmotionStop.Enabled = $false; Write-Log "=== Emotion MCP (Stop) ==="; Stop-EmotionServer }
  finally { $btnEmotionStop.Enabled = $true }
})
$btnLemonStop.Add_Click({
  try { $btnLemonStop.Enabled = $false; Write-Log "=== Lemonade Server (Stop) ==="; Stop-LemonadeServer }
  finally { $btnLemonStop.Enabled = $true }
})
$btnPyStop.Add_Click({
  try { $btnPyStop.Enabled = $false; Write-Log "=== Python App (Stop) ==="; Stop-PythonApp }
  finally { $btnPyStop.Enabled = $true }
})

$btnDockerQuit.Add_Click({
  try { $btnDockerQuit.Enabled = $false; Write-Log "=== Docker Desktop (Quit) ==="; Stop-DockerDesktop }
  finally { $btnDockerQuit.Enabled = $true }
})

$btnClose.Add_Click({ $form.Close() })

$form.Controls.AddRange(@(
  $btnAllStart, $btnAllStop,
  $btnDockerStart, $btnEmotionStart, $btnLemonStart, $btnPyStart,
  $btnDockerStop, $btnEmotionStop, $btnLemonStop, $btnPyStop,
  $btnDockerQuit, $lblCredPath, $LogBox, $btnClose
))

[void]$form.ShowDialog()

