<#
  Kai Discord presence helper  -  scripts/discord-presence/discord-rpc.ps1

  Started (hidden) by main.lua next to it. Keeps ONE connection to the Discord
  desktop app open and shows whatever main.lua writes to the state file.
  Quits by itself when Kai closes. Runs on the PowerShell that ships with
  Windows 10/11 - nothing to install.

  Log:       %TEMP%\kai-discord-presence.log
  Self-test: run test-discord.bat (same folder) with Discord open.
#>
param(
    [string]$StateFile = (Join-Path $env:TEMP 'kai-discord-presence.json'),
    [int]$ParentPid = 0,
    [switch]$SelfTest,
    [string]$ClientId = ''
)

$ErrorActionPreference = 'Stop'

$script:Utf8            = New-Object System.Text.UTF8Encoding($false)
$script:LogFile         = Join-Path $env:TEMP 'kai-discord-presence.log'
$script:DefaultClientId = '1361448446862692492'
$script:Pipe            = $null
$script:HdrBuf          = New-Object byte[] 8
$script:HdrTask         = $null
$script:Level           = 0
$script:LastTitle       = $null
$script:LastHadTimes    = $false
$script:ActivityPid     = $PID
if ($ParentPid -gt 0) { $script:ActivityPid = $ParentPid }

# ----------------------------------------------------------------- logging
function Write-Log([string]$Message) {
    $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message
    try { [System.IO.File]::AppendAllText($script:LogFile, $line + [Environment]::NewLine, $script:Utf8) } catch { }
    if ($SelfTest) { Write-Host $line }
}

try {
    if ((Test-Path $script:LogFile) -and ((Get-Item $script:LogFile).Length -gt 262144)) {
        Remove-Item $script:LogFile -Force
    }
} catch { }

# --------------------------------------------------------------- small utils
function Get-UnixTime {
    $epoch = New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc)
    return [int64]((Get-Date).ToUniversalTime() - $epoch).TotalSeconds
}

function Test-ProcessAlive([int]$ProcessId) {
    try {
        $p = [System.Diagnostics.Process]::GetProcessById($ProcessId)
        return (-not $p.HasExited)
    } catch {
        return $false
    }
}

# Discord wants 2..128 characters for details/state/button labels.
function Limit-Text([string]$Text, [int]$Max) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $Text = $Text.Trim()
    if ($Text.Length -gt $Max) {
        $Text = $Text.Substring(0, $Max - 1)
        if ([char]::IsHighSurrogate($Text[$Text.Length - 1])) { $Text = $Text.Substring(0, $Text.Length - 1) }
        $Text = $Text + [string][char]0x2026
    }
    if ($Text.Length -lt 2) { $Text = $Text + [string][char]0x00A0 }
    return $Text
}

function Read-State([string]$Path) {
    try {
        $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $sr = New-Object System.IO.StreamReader($fs, $script:Utf8)
            $text = $sr.ReadToEnd()
        } finally {
            $fs.Dispose()
        }
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        return ($text | ConvertFrom-Json)
    } catch {
        return $null   # missing, half-written or locked - try again next tick
    }
}

# ------------------------------------------------------- Discord IPC framing
# Frame = int32 opcode (LE) + int32 length (LE) + UTF-8 JSON.
# Opcodes: 0 handshake, 1 frame, 2 close, 3 ping, 4 pong.
function Write-Frame([int]$Op, [string]$Json) {
    $payload = $script:Utf8.GetBytes($Json)
    $frame = New-Object byte[] ($payload.Length + 8)
    [BitConverter]::GetBytes([int]$Op).CopyTo($frame, 0)
    [BitConverter]::GetBytes([int]$payload.Length).CopyTo($frame, 4)
    $payload.CopyTo($frame, 8)
    $script:Pipe.Write($frame, 0, $frame.Length)
    $script:Pipe.Flush()
}

function Read-Exact([int]$Count, [int]$TimeoutMs) {
    $buf = New-Object byte[] $Count
    $got = 0
    while ($got -lt $Count) {
        $task = $script:Pipe.ReadAsync($buf, $got, $Count - $got)
        if (-not $task.Wait($TimeoutMs)) { throw 'timed out reading from Discord' }
        if ($task.Result -le 0) { throw 'Discord closed the pipe' }
        $got += $task.Result
    }
    return , $buf
}

# One persistent read is kept pending between calls, so a timeout never loses
# or splits a frame. Returns $null when nothing arrived within TimeoutMs.
function Receive-Frame([int]$TimeoutMs) {
    if ($null -eq $script:HdrTask) {
        $script:HdrTask = $script:Pipe.ReadAsync($script:HdrBuf, 0, 8)
    }
    if (-not $script:HdrTask.Wait($TimeoutMs)) { return $null }
    $n = $script:HdrTask.Result
    $script:HdrTask = $null
    if ($n -le 0) { throw 'Discord closed the pipe' }
    while ($n -lt 8) {
        $more = $script:Pipe.ReadAsync($script:HdrBuf, $n, 8 - $n)
        if (-not $more.Wait(5000)) { throw 'timed out reading a frame header' }
        if ($more.Result -le 0) { throw 'Discord closed the pipe' }
        $n += $more.Result
    }
    $op  = [BitConverter]::ToInt32($script:HdrBuf, 0)
    $len = [BitConverter]::ToInt32($script:HdrBuf, 4)
    if ($len -lt 0 -or $len -gt 1048576) { throw "bad frame length $len" }
    $body = ''
    if ($len -gt 0) {
        $bytes = Read-Exact $len 5000
        $body = $script:Utf8.GetString($bytes)
    }
    return [pscustomobject]@{ Op = $op; Body = $body }
}

# Answer pings, notice closes. Call regularly while idle.
function Receive-Pending {
    while ($true) {
        $f = Receive-Frame 0
        if ($null -eq $f) { return }
        if ($f.Op -eq 3) { Write-Frame 4 $f.Body }
        elseif ($f.Op -eq 2) { throw "Discord closed the connection - $($f.Body)" }
    }
}

# ------------------------------------------------------------- connecting
function Get-DiscordPipeNames {
    $names = @()
    try {
        foreach ($file in [System.IO.Directory]::GetFiles('\\.\pipe\')) {
            $leaf = [System.IO.Path]::GetFileName($file)
            if ($leaf -like 'discord-ipc-*') { $names += $leaf }
        }
    } catch {
        $names = @(0..9 | ForEach-Object { "discord-ipc-$_" })   # could not list pipes - just try them
    }
    return $names
}

function Close-Pipe {
    if ($null -ne $script:Pipe) { try { $script:Pipe.Dispose() } catch { } }
    $script:Pipe    = $null
    $script:HdrTask = $null
}

function Open-Discord([string]$Id) {
    Close-Pipe
    $names = @(Get-DiscordPipeNames)
    if ($names.Count -eq 0) { throw 'Discord does not seem to be running (no discord-ipc pipe found)' }

    foreach ($name in $names) {
        $p = New-Object System.IO.Pipes.NamedPipeClientStream('.', $name, [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::Asynchronous)
        try {
            $p.Connect(500)
            $script:Pipe = $p
            break
        } catch {
            $p.Dispose()
            Write-Log "pipe $name not usable - $($_.Exception.Message)"
        }
    }
    if ($null -eq $script:Pipe) { throw 'could not open any discord-ipc pipe' }

    try {
        Write-Frame 0 (ConvertTo-Json -InputObject ([ordered]@{ v = 1; client_id = $Id }) -Compress)
        $f = Receive-Frame 5000
        if ($null -eq $f) { throw 'no answer to the handshake' }
        if ($f.Op -ne 1 -or $f.Body -notmatch '"READY"') { throw "handshake refused (op $($f.Op)) $($f.Body)" }
    } catch {
        Close-Pipe
        throw
    }
}

# ------------------------------------------------------------ the presence
function New-Activity($St, [int]$Level) {
    # Level 0 = everything. 1 = no buttons. 2 = also no status_display_type.
    # 3 = also no images. Used to find what Discord accepts if it rejects a field.
    $act = [ordered]@{ 'type' = 3 }   # 3 = Watching

    $details = Limit-Text ([string]$St.title) 128
    $state   = Limit-Text ([string]$St.state) 128
    if ($details) { $act['details'] = $details }
    if ($state)   { $act['state']   = $state }

    if ($Level -lt 2 -and $null -ne $St.status_display_type) {
        $act['status_display_type'] = [int]$St.status_display_type   # 2 = show the details line (title)
    }

    if ($St.start -and $St.'end') {
        $act['timestamps'] = [ordered]@{ 'start' = [int64]$St.start; 'end' = [int64]$St.'end' }
    }

    if ($Level -lt 3 -and $St.large_image) {
        $assets = [ordered]@{ 'large_image' = [string]$St.large_image }
        if ($details) { $assets['large_text'] = $details }
        $act['assets'] = $assets
    }

    if ($Level -lt 1 -and $St.buttons) {
        $buttons = @()
        foreach ($b in @($St.buttons)) {
            $label = Limit-Text ([string]$b.label) 32
            if ($label -and $b.url) {
                $buttons += [ordered]@{ 'label' = $label; 'url' = [string]$b.url }
            }
        }
        if ($buttons.Count -gt 0) { $act['buttons'] = $buttons }
    }
    return $act
}

function Invoke-SetActivity($Activity) {
    $nonce = [guid]::NewGuid().ToString()
    $cmd = [ordered]@{
        'cmd'   = 'SET_ACTIVITY'
        'args'  = [ordered]@{ 'pid' = $script:ActivityPid; 'activity' = $Activity }
        'nonce' = $nonce
    }
    Write-Frame 1 (ConvertTo-Json -InputObject $cmd -Depth 10 -Compress)

    $deadline = (Get-Date).AddSeconds(8)
    while ((Get-Date) -lt $deadline) {
        $f = Receive-Frame 2000
        if ($null -eq $f) { continue }
        if ($f.Op -eq 3) { Write-Frame 4 $f.Body; continue }
        if ($f.Op -eq 2) { throw "Discord closed the connection - $($f.Body)" }
        if ($f.Op -ne 1) { continue }

        $resp = $null
        try { $resp = $f.Body | ConvertFrom-Json } catch { continue }
        if ($resp.nonce -ne $nonce) { continue }   # some other event

        if ($resp.evt -eq 'ERROR') {
            return [pscustomobject]@{ Ok = $false; Message = ('{0} {1}' -f $resp.data.code, $resp.data.message) }
        }
        return [pscustomobject]@{ Ok = $true; Message = '' }
    }
    throw 'no reply to SET_ACTIVITY'
}

function Set-Presence($St) {
    if (-not $St.active) {
        $r = Invoke-SetActivity $null
        $script:LastHadTimes = $false
        if (-not $r.Ok) { Write-Log "clearing the presence was rejected - $($r.Message)" }
        else { Write-Log 'presence cleared' }
        return
    }

    # New title -> start from the full version again.
    if ($St.title -ne $script:LastTitle) { $script:Level = 0; $script:LastTitle = $St.title }

    # Going from "playing" (time bar) to "paused" (no time bar): Discord can keep
    # showing the old timer if the new presence simply omits it, so wipe first.
    $hasTimes = [bool]($St.start -and $St.'end')
    if ($script:LastHadTimes -and -not $hasTimes) {
        $null = Invoke-SetActivity $null
        Start-Sleep -Milliseconds 500
        Write-Log 'cleared the old presence so the timer is dropped'
    }

    for ($lvl = $script:Level; $lvl -le 3; $lvl++) {
        $act = New-Activity $St $lvl
        $r = Invoke-SetActivity $act
        if ($r.Ok) {
            if ($lvl -gt $script:Level) { Write-Log "Discord only accepted the presence at fallback level $lvl" }
            $script:Level = $lvl
            Write-Log "presence set - $($act['details']) | $($act['state']) (level $lvl)"
            return
        }
        Write-Log "SET_ACTIVITY rejected at level $lvl - $($r.Message)"
    }
    Write-Log 'Discord rejected every version of the presence'
}

# ===================================================================== self-test
if ($SelfTest) {
    $id = $script:DefaultClientId
    if ($ClientId) { $id = $ClientId }
    Write-Host ''
    Write-Host 'Kai Discord presence - self-test (Discord must be open)' -ForegroundColor Cyan
    try {
        Open-Discord $id
        Write-Host 'Connected to Discord.' -ForegroundColor Green
        $now = Get-UnixTime
        $test = [pscustomobject]@{
            active = $true; title = 'Kai Test Movie'; state = 'Movie (2024)'
            start = $now; 'end' = ($now + 7200); status_display_type = 2
            buttons = @([pscustomobject]@{ label = 'View on IMDb'; url = 'https://www.imdb.com/' })
        }
        Set-Presence $test
        Write-Host ''
        Write-Host 'Presence sent. For 30 seconds check your Discord status:' -ForegroundColor Green
        Write-Host '  - member list / DMs should read: Watching Kai Test Movie'
        Write-Host '  - your profile card shows the details, a time bar and the button'
        for ($i = 0; $i -lt 30; $i++) { Start-Sleep -Seconds 1; Receive-Pending }
        Set-Presence ([pscustomobject]@{ active = $false })
        Write-Host 'Done - presence cleared.' -ForegroundColor Green
    } catch {
        Write-Host "FAILED - $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Details are in $script:LogFile"
    } finally {
        Close-Pipe
    }
    exit 0
}

# ======================================================================== service
# Only one helper at a time.
$mutex = New-Object System.Threading.Mutex($false, 'Local\KaiDiscordPresenceHelper')
$owned = $false
try {
    $owned = $mutex.WaitOne(3000)
} catch {
    if ($_.Exception -is [System.Threading.AbandonedMutexException] -or
        $_.Exception.InnerException -is [System.Threading.AbandonedMutexException]) {
        $owned = $true
    } else {
        throw
    }
}
if (-not $owned) {
    Write-Log 'another helper is already running - exiting'
    exit 0
}

Write-Log "helper started (pid $PID, parent $ParentPid, state file $StateFile)"

$lastSeq       = $null
$current       = $null
$needSend      = $false
$lastSendAt    = [datetime]::MinValue
$nextConnectAt = [datetime]::MinValue
$connectedId   = $null

try {
    while ($true) {
        if ($ParentPid -gt 0 -and -not (Test-ProcessAlive $ParentPid)) {
            Write-Log 'Kai has closed - shutting down'
            break
        }

        # 1. anything new from main.lua?
        $st = Read-State $StateFile
        if ($null -ne $st -and $st.seq -ne $lastSeq) {
            $lastSeq  = $st.seq
            $current  = $st
            $needSend = $true
        }

        # 2. Discord application changed in the settings -> reconnect
        if ($null -ne $script:Pipe -and $null -ne $current -and $connectedId -and $current.client_id -and ([string]$current.client_id -ne $connectedId)) {
            Close-Pipe
        }

        # 3. connect (only while there is something to show)
        if ($null -eq $script:Pipe -and $null -ne $current -and $current.active -and (Get-Date) -ge $nextConnectAt) {
            $id = $script:DefaultClientId
            if ($current.client_id) { $id = [string]$current.client_id }
            try {
                Open-Discord $id
                $connectedId = $id
                $needSend    = $true
                Write-Log 'connected to Discord'
            } catch {
                Write-Log "could not connect - $($_.Exception.Message)"
                Close-Pipe
                $nextConnectAt = (Get-Date).AddSeconds(5)
            }
        }

        # 4. push the presence (at most one update per 3 s; re-sent every 45 s
        #    so it also comes back after Discord was restarted)
        if ($null -ne $script:Pipe) {
            try {
                Receive-Pending
                $age = ((Get-Date) - $lastSendAt).TotalSeconds
                if ($null -ne $current -and $current.active -and $age -ge 45) { $needSend = $true }
                if ($needSend -and $null -ne $current -and $age -ge 3) {
                    Set-Presence $current
                    $needSend   = $false
                    $lastSendAt = Get-Date
                }
            } catch {
                Write-Log "connection lost - $($_.Exception.Message)"
                Close-Pipe
                $nextConnectAt = (Get-Date).AddSeconds(2)
                $needSend      = $true
            }
        }

        Start-Sleep -Milliseconds 500
    }
} finally {
    if ($null -ne $script:Pipe) {
        try { $null = Invoke-SetActivity $null } catch { }
    }
    Close-Pipe
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
    Write-Log 'helper stopped'
}
