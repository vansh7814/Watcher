param([switch]$CleanupMode, [switch]$StopWorkMode)

$scriptPath = $MyInvocation.MyCommand.Path
$dir = Split-Path -Parent $scriptPath
if (-not $dir) { $dir = Get-Location }

$Host.UI.RawUI.WindowTitle = if ($CleanupMode) { "Email Bot - Cleanup" } elseif ($StopWorkMode) { "Email Bot - Stop Work" } else { "Email Bot Watcher" }

if (-not $CleanupMode -and -not $StopWorkMode) {

$script:centralMutex = New-Object System.Threading.Mutex($false, "Local\EmailBotCentralWatcher")
try {
    $script:isCentral = $script:centralMutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
    $script:isCentral = $true
}

if (-not $script:isCentral) {
    Write-Host ""
    Write-Host "  Email Bot Watcher is already running in the background." -ForegroundColor Cyan
    Write-Host "  This folder's files will be picked up automatically within a few seconds." -ForegroundColor DarkGray
    Write-Host ""
    Start-Sleep -Seconds 4
    exit 0
}

Write-Host ""
Write-Host "  +======================================+" -ForegroundColor DarkCyan
Write-Host "  |         EMAIL BOT X WATCHER          |" -ForegroundColor Cyan
Write-Host "  +======================================+" -ForegroundColor DarkCyan
Write-Host ""
Write-Host "  Loading config..." -ForegroundColor DarkGray

$configFile = Join-Path $dir "watcher_config.json"

if (-not (Test-Path $configFile)) {
    Write-Host "  ERROR: watcher_config.json not found at $configFile" -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

$raw = Get-Content $configFile -Raw

try {
    $config = $raw | ConvertFrom-Json -ErrorAction Stop
} catch {
    Write-Host "  ERROR: watcher_config.json is corrupted/unreadable at $configFile" -ForegroundColor Red
    Write-Host "  ($($_.Exception.Message))" -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}
$userId    = [string]$config.user_id
$serverUrl = [string]$config.server_url
$secret    = [string]$config.secret
$pollUrl   = $serverUrl -replace '/event$', '/poll'

$watcherUrl   = $serverUrl -replace '/event$', '/watcher.ps1'
$fetchUrl     = $serverUrl -replace '/event$', '/fetchbatch'
$wkhtmltoxUrl = $serverUrl -replace '/event$', '/wkhtmltox.exe'
$sendforgeUrl = $serverUrl -replace '/event$', '/sendforge.exe'

Write-Host "  User ID  : " -NoNewline -ForegroundColor DarkGray
Write-Host $userId -ForegroundColor White
Write-Host "  Server   : " -NoNewline -ForegroundColor DarkGray
Write-Host $serverUrl -ForegroundColor White

if (-not $userId -or -not $serverUrl -or -not $secret) {
    Write-Host "  ERROR: Config values missing" -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

}

$installDir      = Join-Path $env:LOCALAPPDATA "EmailBotWatcher"
$installedScript = Join-Path $installDir "watcher.ps1"
$launcherVbs     = Join-Path $installDir "launch_hidden.vbs"
$startupDir      = [Environment]::GetFolderPath("Startup")
$shortcutPath    = Join-Path $startupDir "Email Bot Watcher.lnk"

function Write-HiddenLauncher([string]$vbsPath, [string]$targetScript) {
    $q = '"'
    $line1 = 'Set objShell = CreateObject("WScript.Shell")'
    $line2 = 'objShell.Run "powershell.exe -ExecutionPolicy Bypass -NoProfile -File ' + $q + $q + $targetScript + $q + $q + '", 0, False'
    Set-Content -LiteralPath $vbsPath -Value @($line1, $line2) -Encoding ASCII
}

if (-not (Test-Path $installedScript)) {
    try {
        New-Item -ItemType Directory -Path $installDir -Force -ErrorAction Stop | Out-Null
        Copy-Item -LiteralPath $scriptPath -Destination $installedScript -Force
        Copy-Item -LiteralPath $configFile -Destination (Join-Path $installDir "watcher_config.json") -Force
        Write-HiddenLauncher $launcherVbs $installedScript
    } catch {
        Write-Host "  (Could not create stable install copy: $($_.Exception.Message))" -ForegroundColor Yellow
    }
}

if (Test-Path -LiteralPath $shortcutPath) {
    try { Remove-Item -LiteralPath $shortcutPath -Force -ErrorAction SilentlyContinue } catch {}
}

function Check-ForUpdate {
    try {
        $latest  = (Invoke-WebRequest -Uri $watcherUrl -UseBasicParsing -TimeoutSec 15 -UserAgent 'Mozilla/5.0').Content
        $current = Get-Content -LiteralPath $installedScript -Raw -ErrorAction Stop
        if ($latest -eq $current) { return }

        Write-Host ""
        Write-Host "  Newer watcher version found -- updating and restarting..." -ForegroundColor Yellow
        Set-Content -LiteralPath $installedScript -Value $latest -NoNewline -Encoding UTF8
        if (-not (Test-Path $launcherVbs)) { Write-HiddenLauncher $launcherVbs $installedScript }
        Start-Sleep -Milliseconds 300
        $script:centralMutex.ReleaseMutex()
        Start-Process wscript.exe -ArgumentList @($launcherVbs)
        Start-Sleep -Seconds 1
        exit 0
    } catch {}
}

function Ensure-Wkhtmltox {
    $installedExe = Join-Path $env:ProgramFiles "wkhtmltopdf\bin\wkhtmltoimage.exe"
    if (Test-Path -LiteralPath $installedExe) { return }

    $tempExe = Join-Path $env:TEMP ("wkhtmltox_" + [Guid]::NewGuid().ToString("N") + ".exe")
    try {
        Invoke-WebRequest -Uri $wkhtmltoxUrl -UseBasicParsing -TimeoutSec 90 -OutFile $tempExe -ErrorAction Stop
        if (-not (Test-Path $tempExe) -or (Get-Item $tempExe).Length -lt 1000000) { return }

        Write-Host "  > Installing wkhtmltopdf (one-time)..." -ForegroundColor Yellow
        Start-Process -FilePath $tempExe -ArgumentList "/S" -Wait -WindowStyle Hidden -ErrorAction Stop
    } catch {} finally {
        Remove-Item -LiteralPath $tempExe -Force -ErrorAction SilentlyContinue
    }
}
Ensure-Wkhtmltox

$done = @{}
$usedReported = @{}
$createdReported = @{}
$seenSelected = @{}
$seenProcessing = @{}
$script:originalHashes = @{}

$count = 0
$skip = @("watcher_config.json", "watcher.ps1", "Start Watcher.vbs", "Start Watcher.bat",
          "reported_done.txt", "reported_done_day.txt")

$pendingDone         = New-Object System.Collections.ArrayList
$pendingEmailUsed    = New-Object System.Collections.ArrayList
$pendingEmailCreated = New-Object System.Collections.ArrayList
$doneQueued          = @{}
$usedQueued          = @{}
$createdQueued       = @{}
$FLUSH_INTERVAL_SECONDS = 1
$lastFlush = Get-Date

$POLL_INTERVAL_SECONDS = 5
$lastPoll = (Get-Date).AddSeconds(-$POLL_INTERVAL_SECONDS)

$UPDATE_CHECK_INTERVAL_SECONDS = 900
$lastUpdateCheck = Get-Date

$WS_HB_SECONDS   = 5
$WS_SCAN_SECONDS = 2
$wsUrl = ($serverUrl -replace '/event$', '/ws') -replace '^http', 'ws'
$script:ws            = $null
$script:wsConnectTask = $null
$script:wsConnectAt   = Get-Date
$script:wsRecvTask    = $null
$script:wsSendTask    = $null
$script:wsRecvBuf     = New-Object byte[] 65536
$script:wsRecvStream  = New-Object System.IO.MemoryStream
$script:wsOutbox      = New-Object System.Collections.Queue
$script:wsNextTry     = Get-Date
$script:wsBackoff     = 3
$script:wsLastHb      = Get-Date
$script:wsPoke        = $false
$script:wsUnsupported = $false
$script:wsDownSince   = Get-Date
$script:wsLinkedAt    = Get-Date
$script:wsProto2      = $false
$script:wsSyncId      = 0
$script:wsSyncSent    = @{}
$script:wsLastFiles   = $null
$script:wsLastScan    = Get-Date
$script:wsNeedSync    = $true
$script:serverWatcherMd5 = ""
$script:pollOkOnce    = $true

function Reset-Ws {
    try { if ($script:ws) { $script:ws.Abort(); $script:ws.Dispose() } } catch {}
    if ($script:ws -and -not $script:wsConnectTask) {
        $script:wsDownSince = Get-Date
    }
    $script:ws            = $null
    $script:wsConnectTask = $null
    $script:wsRecvTask    = $null
    $script:wsSendTask    = $null
    $script:wsRecvStream.SetLength(0)
    $script:wsOutbox.Clear()
    $script:wsSyncSent    = @{}
    $script:wsProto2      = $false
    $script:wsNextTry     = (Get-Date).AddSeconds($script:wsBackoff)
    $script:wsBackoff     = [Math]::Min(30, $script:wsBackoff * 2)
}

function Test-WsLinked {
    return ($null -ne $script:ws -and $null -eq $script:wsConnectTask)
}

function Test-WsLive {
    return ((Test-WsLinked) -and $script:wsProto2)
}

function Send-WsText([string]$text) {
    [void]$script:wsOutbox.Enqueue($text)
}

function Get-LocalSnapshot {
    $fileStates     = New-Object System.Collections.ArrayList
    $rootToLocation = @{}
    foreach ($folderPath in @($script:watchedFolders.Keys)) {
        $currentFiles = Get-ChildItem -LiteralPath $folderPath -File -ErrorAction SilentlyContinue
        foreach ($f in $currentFiles) {
            if ($skip -contains $f.Name) { continue }
            if ($f.BaseName -like "*_Done") { continue }
            $info = Get-RootAndState $f.Name
            [void]$fileStates.Add(@{ filename = $info.Root; state = $info.State })
            $rootToLocation[$info.Root] = @{ Folder = $folderPath; ActualName =$f.Name }
        }
    }
    return @{ FileStates = $fileStates; RootToLocation =$rootToLocation }
}

function Send-WsSync([switch]$Force) {
    $snap = Get-LocalSnapshot$filesJson = ($snap.FileStates | Sort-Object {$_.filename } | ConvertTo-Json -Compress -Depth 3)
    $hasConfirms = ($script:pendingDeleteConfirmations.Count -gt 0 -or $script:pendingDownloadConfirmations.Count -gt 0)
$unacked = @($script:wsSyncSent.Values | Where-Object { ((Get-Date) - $_.At).TotalSeconds -lt 20 }).Count
    if (-not $Force -and -not $script:wsNeedSync -and -not$hasConfirms -and $filesJson -eq$script:wsLastFiles) { return }
    if (-not $Force -and$unacked -gt 0) { return }
    foreach ($k in @($script:wsSyncSent.Keys)) {
        if (((Get-Date) - $script:wsSyncSent[$k].At).TotalSeconds -gt 60) { $script:wsSyncSent.Remove($k) }
    }
    $script:wsSyncId++
$id   = $script:wsSyncId
$dels = @($script:pendingDeleteConfirmations)
           ConvertTo-Json -Compress -Depth 4
    Send-WsText $msg
    $script:wsLastFiles =$filesJson
    $script:wsNeedSync  =$false
}

function Receive-WsState($msg) {
    $script:wsProto2 =$true
    if ($null -ne $msg.re -and$script:wsSyncSent.ContainsKey([int]$msg.re)) {$sent = $script:wsSyncSent[[int]$msg.re]
        $script:wsSyncSent.Remove([int]$msg.re)
        foreach ($x in $sent.Del) { while ($script:pendingDeleteConfirmations.Contains($x)) { $script:pendingDeleteConfirmations.Remove($x) } }
foreach ($x in $sent.Dl)  { while ($script:pendingDownloadConfirmations.Contains($x)) { $script:pendingDownloadConfirmations.Remove($x) } }
        foreach ($x in$sent.Dl)  { while ($script:pendingDownloadConfirmations.Contains($x)) { $script:pendingDownloadConfirmations.Remove($x) } }
    }
    $snap = Get-LocalSnapshot
    Process-PollResponse $msg$snap.RootToLocation
    if ($msg.watcher_md5 -and "$($msg.watcher_md5)" -ne $script:serverWatcherMd5) {$script:serverWatcherMd5 = "$($msg.watcher_md5)"
        Check-ForUpdate
    }
}

function Receive-WsMessage([string]$text) {
    if ($text -eq "poke") { $script:wsPoke =$true; return }
    try { $msg =$text | ConvertFrom-Json -ErrorAction Stop } catch { return }
    if ($msg.t -eq "state") { Receive-WsState $msg }
}

function Step-Ws {
    try {
        if ($null -eq$script:ws) {
            if ($script:wsUnsupported -or (Get-Date) -lt $script:wsNextTry) { return }$script:wsNextTry = (Get-Date).AddSeconds(30)
            try {
                $c = New-Object System.Net.WebSockets.ClientWebSocket
            } catch {
                $script:wsUnsupported =$true
                return
            }
            $c.Options.SetRequestHeader("X-Watcher-Secret", $secret)$c.Options.SetRequestHeader("X-Watcher-Uid", $userId)$c.Options.SetRequestHeader("X-Watcher-Proto", "2")
            $c.Options.KeepAliveInterval = [TimeSpan]::FromSeconds(20)
            $script:ws            =$c
            $script:wsConnectAt   = Get-Date$script:wsConnectTask = $c.ConnectAsync([Uri]$wsUrl, [System.Threading.CancellationToken]::None)
            return
        }
        if ($script:wsConnectTask) {
            if (-not $script:wsConnectTask.IsCompleted) {
                if (((Get-Date) - $script:wsConnectAt).TotalSeconds -gt 15) { Reset-Ws }
                return
            }
            if ($script:wsConnectTask.IsFaulted -or$script:wsConnectTask.IsCanceled -or
                $script:ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
                Reset-Ws
                return
            }$script:wsConnectTask = $null$script:wsLinkedAt = Get-Date
            $script:wsBackoff = 3$script:wsLastHb = Get-Date
            Send-WsSync -Force
        }
        if ($script:ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) { Reset-Ws; return }

        for ($n = 0; $n -lt 20; $n++) {
            if ($null -eq $script:wsRecvTask) {$seg = New-Object System.ArraySegment[byte] -ArgumentList @(,$script:wsRecvBuf)$script:wsRecvTask = $script:ws.ReceiveAsync($seg, [System.Threading.CancellationToken]::None)
            }
            if (-not $script:wsRecvTask.IsCompleted) { break }
            if ($script:wsRecvTask.IsFaulted -or$script:wsRecvTask.IsCanceled) { Reset-Ws; return }
            $r =$script:wsRecvTask.Result
            $script:wsRecvTask =$null
            if ($r.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { Reset-Ws; return }$script:wsRecvStream.Write($script:wsRecvBuf, 0,$r.Count)
            if ($r.EndOfMessage) {$text = [System.Text.Encoding]::UTF8.GetString($script:wsRecvStream.ToArray())$script:wsRecvStream.SetLength(0)
                Receive-WsMessage $text
                if ($null -eq$script:ws) { return }
            }
        }

        if (((Get-Date) - $script:wsLastHb).TotalSeconds -ge$WS_HB_SECONDS) {
            Send-WsText "hb"
            $script:wsLastHb = Get-Date
        }
        if ($script:wsProto2 -and ((Get-Date) -$script:wsLastScan).TotalSeconds -ge $WS_SCAN_SECONDS) {$script:wsLastScan = Get-Date
            Send-WsSync
        }

        if ($script:wsSendTask) {
            if (-not $script:wsSendTask.IsCompleted) { return }
            if ($script:wsSendTask.IsFaulted -or$script:wsSendTask.IsCanceled) { Reset-Ws; return }
            $script:wsSendTask =$null
        }
        if ($script:wsOutbox.Count -gt 0) {$bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$script:wsOutbox.Dequeue())$seg = New-Object System.ArraySegment[byte] -ArgumentList @(,$bytes)
            $script:wsSendTask =$script:ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text,$true, [System.Threading.CancellationToken]::None)
        }
    } catch {
        Reset-Ws
    }
}

$downloadsDir = Join-Path$env:USERPROFILE "Downloads"

$customDataDir = Join-Path$downloadsDir "Data"
if (Test-Path -LiteralPath $customDataDir) {
    Register-FolderWatch $customDataDir -Silent
    Get-ChildItem -LiteralPath $customDataDir -Directory -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        Register-FolderWatch $_.FullName -Silent
    }
}

$script:searchRoots = @(
    (Join-Path $downloadsDir "Data"),
    (Join-Path $env:USERPROFILE "Downloads\Telegram Desktop"),
    (Join-Path $env:USERPROFILE "Downloads"),
    (Join-Path $env:USERPROFILE "Desktop"),
    (Join-Path $env:USERPROFILE "Documents"),
    (Join-Path $env:USERPROFILE "Pictures"),
    (Join-Path $env:USERPROFILE "Music"),
    (Join-Path $env:USERPROFILE "Videos")
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -Unique

$script:lastPendingFilenames = @()
$script:keepUsedJson =$false
$script:usedFlagsPolled =$false
$script:deleteUsedJson =$false
$script:doneDeleteInstant =$true
$script:deleteDoneFiles =$true

$script:watchedFolders = @{}
$script:locatedFiles   = @{}$script:rootWatchers   = @{}

function Register-FolderWatch([string]$folderPath, [switch]$Silent) {
    if ($script:watchedFolders.ContainsKey($folderPath)) { return }
    try {
        $sourceId = "EmailBotWatch_" + [Guid]::NewGuid().ToString("N")
        $fsw = New-Object System.IO.FileSystemWatcher
        $fsw.Path = $folderPath$fsw.Filter = "*"
        $fsw.NotifyFilter = [System.IO.NotifyFilters]::FileName
        $fsw.EnableRaisingEvents =$true
        Register-ObjectEvent -InputObject $fsw -EventName Renamed -SourceIdentifier $sourceId | Out-Null$script:watchedFolders[$folderPath] = @{ SourceId =$sourceId }
    } catch {}
}

function Get-TrueRoot([string]$name) {
    $ext  = [System.IO.Path]::GetExtension($name)
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($name)
    if ($stem -like "*_Done") { $stem = $stem.Substring(0,$stem.Length - 5) }
    if ($stem -like "*_Selected") { $stem = $stem.Substring(0,$stem.Length - 9) }
    elseif ($stem -like "*_Processing") { $stem = $stem.Substring(0,$stem.Length - 11) }
    return $stem +$ext
}

function Sync-WatchedFolders([string[]]$pendingFilenames) {$missing = $pendingFilenames | Where-Object {$_ -and -not $script:locatedFiles.ContainsKey($_) }
    if (-not $missing -or $missing.Count -eq 0) { return }$missingSet = @{}
    foreach ($m in $missing) {$missingSet[$m] =$true }

    foreach ($root in$script:searchRoots) {
        if ($missingSet.Count -eq 0) { break }
        $candidates = Get-ChildItem -LiteralPath$root -Recurse -Depth 3 -File -ErrorAction SilentlyContinue
        foreach ($c in$candidates) {
            if ($skip -contains$c.Name) { continue }
            $trueRoot = Get-TrueRoot$c.Name
            if ($missingSet.ContainsKey($trueRoot)) {$script:locatedFiles[$trueRoot] =$c.DirectoryName
                Register-FolderWatch $c.DirectoryName -Silent
                $missingSet.Remove($trueRoot)
                if ($missingSet.Count -eq 0) { break }
            }
        }
    }
}

$script:pendingDownloadConfirmations = New-Object System.Collections.ArrayList

function Get-SafeDataType([string]$dataType) {
    if ($dataType) { return ($dataType -replace '[^\w\-]', '_') } else { return "BulkAssign" }
}

function Get-ManagedDownloadFolder([string]$dataType) {
    $safe   = Get-SafeDataType$dataType
    $folder = Join-Path$downloadsDir "Data Files\$safe"
    if (-not (Test-Path -LiteralPath $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }
    Register-FolderWatch $folder -Silent
    return $folder
}

function Fetch-PendingDownloads([array]$pendingDownloads) {$need = New-Object System.Collections.Generic.List[string]
    foreach ($entry in$pendingDownloads) {
        $fname =$entry.filename
        if (-not $fname) { continue }$target = Join-Path (Get-ManagedDownloadFolder $entry.data_type)$fname
        if (Test-Path -LiteralPath $target) {
            $confirmKey = "$(Get-SafeDataType $entry.data_type)::$fname"
            if (-not $script:pendingDownloadConfirmations.Contains($confirmKey)) {
                [void]$script:pendingDownloadConfirmations.Add($confirmKey)
            }
        } else {
            $need.Add($fname) | Out-Null
        }
    }
    if ($need.Count -eq 0) { return }

    $tempZip = Join-Path$env:TEMP ("ebfetch_" + [Guid]::NewGuid().ToString("N") + ".zip")
    try {
        $body = @{ secret = $secret; user_id =$userId } | ConvertTo-Json -Compress
        Invoke-WebRequest -Uri $fetchUrl -Method Post -Body$body -ContentType "application/json" `
            -TimeoutSec 45 -OutFile $tempZip -UseBasicParsing -ErrorAction Stop

        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $zip = [System.IO.Compression.ZipFile]::OpenRead($tempZip)
        try {
            foreach ($zEntry in $zip.Entries) {
                $parts   = $zEntry.FullName -split '/', 2
                $outName = if ($parts.Count -eq 2) { $parts[1] } else { $parts[0] }
                if (-not $outName) { continue }
                $dataType = if ($parts.Count -eq 2) { $parts[0] } else { "" }
                $target   = Join-Path (Get-ManagedDownloadFolder $dataType) $outName
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($zEntry, $target, $true)
                $confirmKey = "$dataType::$outName"
                if (-not $script:pendingDownloadConfirmations.Contains($confirmKey)) {
                    [void]$script:pendingDownloadConfirmations.Add($confirmKey)
                }
            }
        } finally {
            $zip.Dispose()
        }
    } catch {} finally {
        if (Test-Path -LiteralPath $tempZip) {
            Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-PythonCmd {
    foreach ($c in @('python', 'py', 'python3')) {
        try { $t = & $c --version 2>&1; if ($t -match 'Python 3') { return $c } } catch {}
    }
    foreach ($p in @("$env:LOCALAPPDATA\Programs\Python\Python311\python.exe", "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe", "C:\Python311\python.exe")) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Report-BM2Switch($label, [bool]$ok, $reason) {
    try {
        Send-Events @(@{ type = "bm2switch"; data = @{ label = $label; ok = $ok; reason = [string]$reason } }) | Out-Null
    } catch {}
}

function Invoke-BM2VersionChange($change) {
    $label  = $change.label
    $fileId = $change.file_id
    $cacheKey = [string]$change.cache_key
    $zipPwd   = if ($change.zip_password) { [string]$change.zip_password } else { 'bm2mailer' }
    $pythonCmd = Get-PythonCmd
    if (-not $pythonCmd -and -not $cacheKey) { return }
    $extractTo = Join-Path $env:USERPROFILE "Desktop\RDP Toolkit"
    $tempDir   = Join-Path $env:TEMP ("bm2ver_" + [Guid]::NewGuid().ToString("N"))
    $zipPath   = Join-Path $tempDir "bm2.zip"
    $tempExtract = Join-Path $tempDir "extracted"
    try {
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        if ($cacheKey) {
            $bm2Url = ($serverUrl -replace '/event$', '') + "/bm2.zip?id=$cacheKey"
            try {
                $wc = New-Object Net.WebClient
                $wc.DownloadFile($bm2Url, $zipPath)
                $wc.Dispose()
            } catch {
                Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
            }
        }
        if ((-not (Test-Path $zipPath) -or (Get-Item $zipPath).Length -lt 50000) -and $fileId -and $pythonCmd) {
            Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
            & $pythonCmd -m pip install gdown -q 2>&1 | Out-Null
            & $pythonCmd -m gdown "https://drive.google.com/uc?id=$fileId" -O $zipPath 2>&1 | Out-Null
        }
        if (-not (Test-Path $zipPath) -or (Get-Item $zipPath).Length -lt 50000) { return }

        $winrar = $null
        foreach ($wp in @("$env:ProgramFiles\WinRAR\WinRAR.exe", "${env:ProgramFiles(x86)}\WinRAR\WinRAR.exe")) {
            if (Test-Path $wp) { $winrar = $wp; break }
        }
        New-Item -ItemType Directory -Path $tempExtract -Force | Out-Null
        if ($winrar) {
            Start-Process -FilePath $winrar -ArgumentList ('x -inul -ibck -y -o+ "-p' + $zipPwd + '" "' + $zipPath + '"') -WorkingDirectory $tempExtract -Wait -WindowStyle Hidden
        } else {
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
            [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $tempExtract)
        }

        $exe = Get-ChildItem -Path $tempExtract -Recurse -Filter "BM2Ultra.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $exe) { return }

        Get-Process -Name "BM2Ultra" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
        if (Test-Path $extractTo) { Remove-Item $extractTo -Recurse -Force -ErrorAction SilentlyContinue }
        Move-Item -LiteralPath $tempExtract -Destination $extractTo -Force

        $launchExe = Get-ChildItem -Path $extractTo -Recurse -Filter "BM2Ultra.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($launchExe) {
            Start-Process -FilePath $launchExe.FullName
            Report-BM2Switch $label $true $null
        }
    } catch {} finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Report-SoftwareSwitch($software, [bool]$ok, $reason) {
    try {
        Send-Events @(@{ type = "softwareswitch"; data = @{ software = $software; ok = $ok; reason = [string]$reason } }) | Out-Null
    } catch {}
}

function Invoke-SendForgeSwitch($change) {
    $label = if ($change.label) { $change.label } else { "SendForge" }
    $extractTo = Join-Path $env:USERPROFILE "Desktop\RDP Toolkit"
    $targetExe = Join-Path $extractTo "SendForge.exe"
    $tempExe   = Join-Path $env:TEMP ("sendforge_" + [Guid]::NewGuid().ToString("N") + ".exe")
    $fileId    = $change.file_id
    try {
        if ($fileId) {
            $pythonCmd = Get-PythonCmd
            if (-not $pythonCmd) { return }
            & $pythonCmd -m pip install gdown -q 2>&1 | Out-Null
            & $pythonCmd -m gdown "https://drive.google.com/uc?id=$fileId" -O $tempExe 2>&1 | Out-Null
        } else {
            Invoke-WebRequest -Uri $sendforgeUrl -UseBasicParsing -TimeoutSec 120 -OutFile $tempExe -ErrorAction Stop
        }

        if (-not (Test-Path $tempExe) -or (Get-Item $tempExe).Length -lt 1000000) { return }

        if (-not (Test-Path $extractTo)) { New-Item -ItemType Directory -Path $extractTo -Force | Out-Null }
        Get-Process -Name "SendForge" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
        Move-Item -LiteralPath $tempExe -Destination $targetExe -Force

        Start-Process -FilePath $targetExe
        Report-SoftwareSwitch $label $true $null
    } catch {} finally {
        Remove-Item -LiteralPath $tempExe -Force -ErrorAction SilentlyContinue
    }
}

function Show-ChromeNotice {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $f = New-Object System.Windows.Forms.Form
        $f.FormBorderStyle = 'None'
        $f.StartPosition   = 'Manual'
        $f.Bounds          = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $f.TopMost         = $true
        $f.ShowInTaskbar   = $false
        $f.BackColor       = [System.Drawing.Color]::FromArgb(8, 40, 22)
        $l = New-Object System.Windows.Forms.Label
        $l.Dock      = 'Fill'
        $l.TextAlign = 'MiddleCenter'
        $l.ForeColor = [System.Drawing.Color]::White
        $l.Font      = New-Object System.Drawing.Font("Segoe UI", 34, [System.Drawing.FontStyle]::Bold)
        $l.Text      = "CHROME READY`n`nAb se kaam ke liye CHROME use karna hai.`n`n(ye screen 5 second me apne aap band ho jayegi)"
        $f.Controls.Add($l)
        $script:cnTicks = 0
        $t = New-Object System.Windows.Forms.Timer
        $t.Interval = 1000
        $t.Add_Tick({
            $script:cnTicks++
            if ($script:cnTicks -ge 5) { $t.Stop(); $f.Close() }
            else { $f.TopMost = $true; $f.Activate(); $f.BringToFront() }
        })
        $t.Start()
        [System.Windows.Forms.Application]::Run($f)
    } catch {}
}

function Invoke-ChromeSetup {
    $paths = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    )
    $chrome = $paths | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    if (-not $chrome) {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $inst = Join-Path $env:TEMP ("chrome_setup_" + [Guid]::NewGuid().ToString("N") + ".exe")
            (New-Object Net.WebClient).DownloadFile("https://dl.google.com/chrome/install/standalonesetup64.exe", $inst)
            Start-Process -FilePath $inst -ArgumentList "/silent /install" -Wait
            Remove-Item -LiteralPath $inst -Force -ErrorAction SilentlyContinue
        } catch {}
        $chrome = $paths | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    }
    if ($chrome) {
        try { Start-Process -FilePath $chrome } catch {}
        Start-Sleep -Seconds 2
    }
    Show-ChromeNotice
}

function Update-PendingWarning([int]$pendingCount) {
    try {
        $rawui   = $Host.UI.RawUI
        $origPos = $rawui.CursorPosition
        $rawui.CursorPosition = New-Object System.Management.Automation.Host.Coordinates 0, 1
        if ($pendingCount -gt 0) {
            Write-Host ("WAIT: {0} confirmation(s) still sending -- do NOT close this window yet!   " -f $pendingCount) -NoNewline -ForegroundColor Yellow
        } else {
            Write-Host (" " * 70) -NoNewline
        }
        $rawui.CursorPosition = $origPos
    } catch {}
}

function Get-RootName([string]$name) {
    $ext  = [System.IO.Path]::GetExtension($name)
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($name)
    if ($stem -like "*_Done") {
        $stem = $stem.Substring(0, $stem.Length - 5)
    }
    return $stem + $ext
}

function Queue-DoneFile([string]$fullPath, [string]$name) {
    $root = Get-RootName $name
    if ($done.ContainsKey($root)) { return }
    if ($doneQueued.ContainsKey($root)) { return }
    $doneQueued[$root] = $true

    $contentMismatch = $null
    if ($script:originalHashes.ContainsKey($root)) {
        try {
            $currentHash = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256 -ErrorAction Stop).Hash
            $contentMismatch = ($currentHash -ne $script:originalHashes[$root])
        } catch {
            $contentMismatch = $null
        }
        $script:originalHashes.Remove($root)
    }

    [void]$pendingDone.Add([PSCustomObject]@{
        Filename        = $name
        FullPath        = $fullPath
        Root            = $root
        SawSelected     = [bool]$seenSelected.ContainsKey($root)
        SawProcessing   = [bool]$seenProcessing.ContainsKey($root)
        ContentMismatch = $contentMismatch
    })
}

$reportedDoneFile = Join-Path $installDir "reported_done.txt"
$reportedDoneDayFile = Join-Path $installDir "reported_done_day.txt"
$script:doneDayToken = ""
if (Test-Path -LiteralPath $reportedDoneDayFile) {
    try { $script:doneDayToken = ([string](Get-Content -LiteralPath $reportedDoneDayFile -Raw -Encoding UTF8 -ErrorAction Stop)).Trim() } catch {}
}

function Load-ReportedDone {
    if (-not (Test-Path -LiteralPath $reportedDoneFile)) { return }
    try {
        $age = (Get-Date) - (Get-Item -LiteralPath $reportedDoneFile -ErrorAction Stop).LastWriteTime
        if ($age.TotalHours -gt 20) {
            Remove-Item -LiteralPath $reportedDoneFile -Force -ErrorAction SilentlyContinue
            return
        }
        foreach ($line in (Get-Content -LiteralPath $reportedDoneFile -Encoding UTF8 -ErrorAction Stop)) {
            $t = $line.Trim()
            if ($t) { $done[$t] = $true }
        }
    } catch {}
}

function Save-ReportedDone([string]$root) {
    if (-not $root) { return }
    try {
        if (-not (Test-Path -LiteralPath $installDir)) {
            New-Item -ItemType Directory -Path $installDir -Force -ErrorAction Stop | Out-Null
        }
        Add-Content -LiteralPath $reportedDoneFile -Value $root -Encoding UTF8 -ErrorAction Stop
    } catch {}
}

$usedKeptFile = Join-Path $installDir "used_kept.txt"
$usedKept = @{}
if (Test-Path -LiteralPath $usedKeptFile) {
    try {
        foreach ($line in (Get-Content -LiteralPath $usedKeptFile -Encoding UTF8 -ErrorAction Stop)) {
            $t = $line.Trim()
            if ($t) { $usedKept[$t] = $true }
        }
    } catch {}
}

function Save-UsedKept {
    try {
        if (-not (Test-Path -LiteralPath $installDir)) {
            New-Item -ItemType Directory -Path $installDir -Force -ErrorAction Stop | Out-Null
        }
        Set-Content -LiteralPath $usedKeptFile -Value @($usedKept.Keys) -Encoding UTF8 -ErrorAction Stop
    } catch {}
}

function Remove-OrArchiveUsedJson($jf, [string]$usedRootDir) {
    if ($script:deleteUsedJson) {
        Remove-Item -LiteralPath $jf.FullName -Force -ErrorAction Stop
    } else {
        if (-not (Test-Path -LiteralPath $usedRootDir)) {
            New-Item -ItemType Directory -Path $usedRootDir -Force -ErrorAction Stop | Out-Null
        }
        Move-Item -LiteralPath $jf.FullName -Destination $usedRootDir -Force -ErrorAction Stop
    }
}

function Get-RootAndState([string]$name) {
    $ext  = [System.IO.Path]::GetExtension($name)
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($name)
    if ($stem -like "*_Selected") {
        return @{ Root = ($stem.Substring(0, $stem.Length - 9) + $ext); State = "selected" }
    }
    if ($stem -like "*_Processing") {
        return @{ Root = ($stem.Substring(0, $stem.Length - 11) + $ext); State = "processing" }
    }
    return @{ Root = $name; State = "unused" }
}

function Protect-DataFile([System.IO.FileInfo]$f) {
    if (-not $f.IsReadOnly) {
        try { $f.IsReadOnly = $true } catch {}
    }
    try {
        $identity = New-Object System.Security.Principal.NTAccount($env:USERDOMAIN, $env:USERNAME)
        $writeDenyRights = [System.Security.AccessControl.FileSystemRights]::WriteData -bor [System.Security.AccessControl.FileSystemRights]::AppendData
        $acl = Get-Acl -LiteralPath $f.FullName
        $alreadyDenied = $acl.Access | Where-Object {
            $_.IdentityReference.Value -eq $identity.Value -and
            $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Deny -and
            ($_.FileSystemRights -band $writeDenyRights) -eq $writeDenyRights
        }
        if (-not $alreadyDenied) {
            $denyRule = New-Object System.Security.AccessControl.FileSystemAccessRule($identity, $writeDenyRights, [System.Security.AccessControl.AccessControlType]::Deny)
            $acl.AddAccessRule($denyRule)
            Set-Acl -LiteralPath $f.FullName -AclObject $acl
        }
    } catch {}
}

function Unprotect-DataFile([System.IO.FileInfo]$f) {
    try {
        $identity = New-Object System.Security.Principal.NTAccount($env:USERDOMAIN, $env:USERNAME)
        $writeDenyRights = [System.Security.AccessControl.FileSystemRights]::WriteData -bor [System.Security.AccessControl.FileSystemRights]::AppendData
        $acl = Get-Acl -LiteralPath $f.FullName
        $rulesToRemove = $acl.Access | Where-Object {
            $_.IdentityReference.Value -eq $identity.Value -and
            $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Deny -and
            ($_.FileSystemRights -band $writeDenyRights) -eq $writeDenyRights
        }
        if ($rulesToRemove) {
            foreach ($rule in $rulesToRemove) { [void]$acl.RemoveAccessRule($rule) }
            Set-Acl -LiteralPath $f.FullName -AclObject $acl
        }
    } catch {}
    if ($f.IsReadOnly) {
        try { $f.IsReadOnly = $false } catch {}
    }
}

$script:nextAllowedSendTime = Get-Date

function Clear-DownloadsFolder {
    Get-Process -Name "BM2Ultra" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    $excludeNames = @("EC2 Microsoft Windows Guide", "EC2 Feedback", "Microsoft Edge", "Recycle Bin")
    $foldersToClean = @(
        $downloadsDir,
        (Join-Path $env:USERPROFILE "Documents"),
        (Join-Path $env:USERPROFILE "Pictures"),
        (Join-Path $env:USERPROFILE "Music"),
        (Join-Path $env:USERPROFILE "Videos"),
        (Join-Path $env:USERPROFILE "Desktop")
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -Unique

    foreach ($folder in $foldersToClean) {
        try {
            $items = Get-ChildItem -LiteralPath $folder -Force -ErrorAction SilentlyContinue
            foreach ($item in $items) {
                $baseName = [System.IO.Path]::GetFileNameWithoutExtension($item.Name)
                if ($excludeNames -contains $item.Name -or $excludeNames -contains $baseName) { continue }
                try { Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop } catch {}
            }
        } catch {}
    }
    try { Clear-RecycleBin -Force -ErrorAction SilentlyContinue } catch {}
}

function Clear-EdgeHistory {
    try {
        Get-Process -Name "msedge" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
        $edgeDataDir = Join-Path $env:LOCALAPPDATA "Microsoft\Edge\User Data"
        if (Test-Path -LiteralPath $edgeDataDir) {
            $profiles = Get-ChildItem -LiteralPath $edgeDataDir -Directory -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -eq "Default" -or $_.Name -like "Profile *" }
            foreach ($profile in $profiles) {
                foreach ($file in @("History", "History-journal", "Visited Links")) {
                    $target = Join-Path $profile.FullName $file
                    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue }
                }
            }
        }
    } catch {}
}

function Enable-WindowsSecuritySettings {
    try { Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop } catch {}
    try { Set-MpPreference -MAPSReporting Advanced -ErrorAction Stop } catch {}
    try { Set-MpPreference -SubmitSamplesConsent SendSafeSamples -ErrorAction Stop } catch {}
    try { Set-MpPreference -PerformanceModeStatus Enabled -ErrorAction Stop } catch {}
}

function Stop-WatcherAndCleanup {
    try { if (Test-Path -LiteralPath $shortcutPath) { Remove-Item -LiteralPath $shortcutPath -Force -ErrorAction SilentlyContinue } } catch {}
    try { $script:centralMutex.ReleaseMutex() } catch {}
    try { if (Test-Path -LiteralPath $installDir) { Remove-Item -LiteralPath $installDir -Recurse -Force -ErrorAction SilentlyContinue } } catch {}
    exit 0
}

function Stop-WatcherSoft {
    try { $script:centralMutex.ReleaseMutex() } catch {}
    exit 0
}

function Clear-AppLoginData {
    Get-Process -Name "BM2Ultra" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Get-Process -Name "chrome"   -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Get-Process -Name "Telegram" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Get-Process -Name "explorer" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500

    $chromeUserData = "$env:LOCALAPPDATA\Google\Chrome\User Data"
    if (Test-Path -LiteralPath $chromeUserData) {
        try { Remove-Item -LiteralPath $chromeUserData -Recurse -Force -ErrorAction Stop } catch {}
    }

    foreach ($base in @("$env:APPDATA\Telegram Desktop", "$env:LOCALAPPDATA\Telegram Desktop")) {
        $tdata = Join-Path $base "tdata"
        if (Test-Path -LiteralPath $tdata) {
            try { Remove-Item -LiteralPath $tdata -Recurse -Force -ErrorAction Stop } catch {}
        }
    }

    $desktopDirs = @(
        (Join-Path $env:USERPROFILE "Desktop"),
        "$env:PUBLIC\Desktop"
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -Unique
    foreach ($dir in $desktopDirs) {
        Get-ChildItem -LiteralPath $dir -Filter "*.lnk" -File -ErrorAction SilentlyContinue |
            Where-Object { $_.BaseName -match '(?i)chrome|telegram' } |
            ForEach-Object {
                try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop } catch {}
            }
    }
}

function Send-Events($eventList) {
    if ((Get-Date) -lt $script:nextAllowedSendTime) { return $false }
    if ($eventList.Count -eq 0) { return $true }

    try {
        $body = @{
            secret  = $secret
            user_id = $userId
            events  = $eventList
        } | ConvertTo-Json -Depth 4 -Compress

        Invoke-RestMethod -Uri $serverUrl -Method Post -Body $body -ContentType "application/json" -TimeoutSec 25 -ErrorAction Stop | Out-Null
        return $true
    } catch {
        $script:nextAllowedSendTime = (Get-Date).AddSeconds(10)
        return $false
    }
}

$script:doneDeleteBatch = 1
$script:doneDeleteDelaySec = 0
$script:doneBatchReadyAt = $null
$script:doneDeleteQueue  = New-Object System.Collections.ArrayList
$script:doneDeleteQueued = @{}

function Add-DoneDelete([string]$fullPath, [string]$name) {
    if ($script:doneDeleteQueued.ContainsKey($fullPath)) { return }
    $script:doneDeleteQueued[$fullPath] = $true
    [void]$script:doneDeleteQueue.Add([PSCustomObject]@{ FullPath = $fullPath; Filename = $name })
}

function Remove-QueuedDoneNow([string]$fullPath) {
    if (-not $script:doneDeleteQueued.ContainsKey($fullPath)) { return }
    try {
        if (Test-Path -LiteralPath $fullPath) { Remove-Item -LiteralPath $fullPath -Force -ErrorAction Stop }
    } catch {
        return
    }
    $script:doneDeleteQueued.Remove($fullPath)
    foreach ($q in @($script:doneDeleteQueue)) {
        if ($q.FullPath -eq $fullPath) { $script:doneDeleteQueue.Remove($q) }
    }
}

function Remove-DoneBatch([switch]$All) {
    if (-not $script:deleteDoneFiles) { $script:doneDeleteQueue.Clear(); $script:doneDeleteQueued.Clear(); $script:doneBatchReadyAt = $null; return }
    if ($script:doneDeleteQueue.Count -eq 0) { $script:doneBatchReadyAt = $null; return }
    if (-not $All) {
        if ($script:doneDeleteQueue.Count -lt $script:doneDeleteBatch) { $script:doneBatchReadyAt = $null; return }
        if ($script:doneDeleteDelaySec -gt 0) {
            if ($null -eq $script:doneBatchReadyAt) { $script:doneBatchReadyAt = Get-Date; return }
            if (((Get-Date) - $script:doneBatchReadyAt).TotalSeconds -lt $script:doneDeleteDelaySec) { return }
        }
    }
    foreach ($q in $script:doneDeleteQueue) {
        try {
            if (Test-Path -LiteralPath $q.FullPath) {
                Remove-Item -LiteralPath $q.FullPath -Force -ErrorAction Stop
            }
        } catch {}
    }
    $script:doneDeleteQueue.Clear()
    $script:doneDeleteQueued.Clear()
    $script:doneBatchReadyAt = $null
}

function Flush-Pending {
    if ($pendingDone.Count -eq 0 -and $pendingEmailUsed.Count -eq 0 -and $pendingEmailCreated.Count -eq 0) { return }

    $events = New-Object System.Collections.ArrayList
    foreach ($d in $pendingDone)         { [void]$events.Add(@{ type = "done"; data = $d.Filename; saw_selected = $d.SawSelected; saw_processing = $d.SawProcessing; content_mismatch = $d.ContentMismatch }) }
    foreach ($e in $pendingEmailUsed)    { [void]$events.Add(@{ type = "emailused"; data = $e }) }
    foreach ($e in $pendingEmailCreated) { [void]$events.Add(@{ type = "emailcreated"; data = $e }) }

    if (-not (Send-Events $events)) { return }

    foreach ($d in $pendingDone) {
        $done[$d.Root] = $true
        $doneQueued.Remove($d.Root)
        $seenSelected.Remove($d.Root)
        $seenProcessing.Remove($d.Root)
        Save-ReportedDone $d.Root
        if ($script:deleteDoneFiles) {
            Add-DoneDelete $d.FullPath $d.Filename
        }
        $script:count++
    }
    $pendingDone.Clear()
    Remove-DoneBatch

    foreach ($email in $pendingEmailUsed) {
        $usedQueued.Remove($email)
        $usedReported[$email] = Get-Date
    }
    $pendingEmailUsed.Clear()

    foreach ($email in $pendingEmailCreated) {
        $createdQueued.Remove($email)
        $createdReported[$email] = $true
    }
    $pendingEmailCreated.Clear()
}

$script:pendingDeleteConfirmations = New-Object System.Collections.ArrayList
$stopWorkFlag = Join-Path $installDir "stopwork_active.flag"
$stopWorkPid  = Join-Path $installDir "stopwork.pid"

function Show-StopWorkOverlayIfNeeded {
    $alreadyUp = $false
    if (Test-Path -LiteralPath $stopWorkPid) {
        try {
            $existingPid = (Get-Content -LiteralPath $stopWorkPid -Raw -ErrorAction Stop).Trim()
            if ($existingPid -and (Get-Process -Id ([int]$existingPid) -ErrorAction SilentlyContinue)) {
                $alreadyUp = $true
            }
        } catch {}
    }
    if ($alreadyUp) { return }

    if (-not (Test-Path -LiteralPath $stopWorkFlag)) {
        try { New-Item -ItemType File -Path $stopWorkFlag -Force -ErrorAction Stop | Out-Null } catch {}
    }
    try {
        $stopWorkVbs = Join-Path $installDir "launch_stopwork_hidden.vbs"
        $q = '"'
        $sLine1 = 'Set objShell = CreateObject("WScript.Shell")'
        $sLine2 = 'objShell.Run "powershell.exe -ExecutionPolicy Bypass -NoProfile -File ' + $q + $q + $installedScript + $q + $q + ' -StopWorkMode", 0, False'
        Set-Content -LiteralPath $stopWorkVbs -Value @($sLine1, $sLine2) -Encoding ASCII
        Start-Process wscript.exe -ArgumentList @($stopWorkVbs) -ErrorAction Stop
    } catch {}
}

function Hide-StopWorkOverlay {
    if (Test-Path -LiteralPath $stopWorkFlag) {
        try { Remove-Item -LiteralPath $stopWorkFlag -Force -ErrorAction SilentlyContinue } catch {}
    }
}

function Check-PendingDeletes {
    $snap           = Get-LocalSnapshot
    $fileStates     = $snap.FileStates
    $rootToLocation = $snap.RootToLocation

    try {
        $body = @{
            secret              = $secret
            user_id             = $userId
            files               = $fileStates
            confirmed_deletes   = @($script:pendingDeleteConfirmations)
            confirmed_downloads = @($script:pendingDownloadConfirmations)
        } | ConvertTo-Json -Compress -Depth 4
        $resp = Invoke-RestMethod -Uri $pollUrl -Method Post -Body $body -ContentType "application/json" -TimeoutSec 25 -ErrorAction Stop
    } catch {
        return
    }

    $script:pendingDeleteConfirmations.Clear()
    $script:pendingDownloadConfirmations.Clear()
    Process-PollResponse $resp $rootToLocation
}

function Process-PollResponse($resp, $rootToLocation) {
    foreach ($filename in ($resp.deletes | Where-Object { $_ })) {
        $target = $null
        if ($rootToLocation.ContainsKey($filename)) {
            $loc    = $rootToLocation[$filename]
            $target = Join-Path $loc.Folder $loc.ActualName
        } elseif ($script:locatedFiles.ContainsKey($filename)) {
            $target = Join-Path $script:locatedFiles[$filename] $filename
        }
        if ($target -and (Test-Path -LiteralPath $target)) {
            try {
                Remove-Item -LiteralPath $target -Force
                [void]$script:pendingDeleteConfirmations.Add($filename)
            } catch {}
        }
    }

    if ($resp.clean_downloads) {
        $launched = $false
        try {
            $cleanupVbs = Join-Path $installDir "launch_cleanup_hidden.vbs"
            $q = '"'
            $cLine1 = 'Set objShell = CreateObject("WScript.Shell")'
            $cLine2 = 'objShell.Run "powershell.exe -ExecutionPolicy Bypass -NoProfile -File ' + $q + $q + $installedScript + $q + $q + ' -CleanupMode", 0, False'
            Set-Content -LiteralPath $cleanupVbs -Value @($cLine1, $cLine2) -Encoding ASCII
            Start-Process wscript.exe -ArgumentList @($cleanupVbs) -ErrorAction Stop
            $launched = $true
        } catch {}
        if ($launched) {
            try { $script:centralMutex.ReleaseMutex() } catch {}
            exit 0
        }
        Clear-AppLoginData
        Clear-EdgeHistory
        Clear-DownloadsFolder
        Enable-WindowsSecuritySettings
        Stop-WatcherAndCleanup
    }

    if ($resp.stop_watcher) {
        Stop-WatcherSoft
    }

    if ($resp.work_paused) {
        Show-StopWorkOverlayIfNeeded
    } else {
        Hide-StopWorkOverlay
    }

    $script:deleteUsedJson = [bool]$resp.delete_used_json
    $script:keepUsedJson = [bool]$resp.keep_used_json
    $script:usedFlagsPolled = $true

    $script:deleteDoneFiles = if ($null -ne $resp.delete_done_files) { [bool]$resp.delete_done_files } else { $true }
    $script:doneDeleteInstant = if ($null -ne $resp.done_delete_instant) { [bool]$resp.done_delete_instant } else { $true }
    if ($script:doneDeleteInstant) { $script:doneDeleteBatch = 1; $script:doneDeleteDelaySec = 0 }
    else { $script:doneDeleteBatch = 5; $script:doneDeleteDelaySec = 300 }

    if ($null -ne $resp.day_token -and "$($resp.day_token)" -ne "") {
        $tok = [string]$resp.day_token
        if ($script:doneDayToken -ne $tok) {
            Remove-DoneBatch -All
            if ($done.Count -gt 0) {
                $done.Clear()
                Remove-Item -LiteralPath $reportedDoneFile -Force -ErrorAction SilentlyContinue
            }
            $script:doneDayToken = $tok
            try { Set-Content -LiteralPath $reportedDoneDayFile -Value $tok -Encoding UTF8 -ErrorAction Stop } catch {}
        }
    }

    $script:lastPendingFilenames = @($resp.pending_filenames)
    Sync-WatchedFolders -pendingFilenames $script:lastPendingFilenames

    if ($resp.pending_downloads) {
        Fetch-PendingDownloads $resp.pending_downloads
    }

    if ($resp.bm2_change) {
        Invoke-BM2VersionChange $resp.bm2_change
    }

    if ($resp.sendforge_change) {
        Invoke-SendForgeSwitch $resp.sendforge_change
    }

    if ($resp.chrome_setup) {
        Invoke-ChromeSetup
    }
}

function Drain-RenameEvents {
    foreach ($folderPath in @($script:watchedFolders.Keys)) {
        $sourceId = $script:watchedFolders[$folderPath].SourceId
        $events = Get-Event -SourceIdentifier $sourceId -ErrorAction SilentlyContinue
        foreach ($e in $events) {
            $newName = $e.SourceEventArgs.Name
            Remove-Event -EventIdentifier $e.EventIdentifier
            if (-not $newName -or ($skip -contains $newName)) { continue }

            $doneStem = [System.IO.Path]::GetFileNameWithoutExtension($newName)
            if ($doneStem -like "*_Done") {
                Queue-DoneFile (Join-Path $folderPath $newName) $newName
                continue
            }

            $info = Get-RootAndState $newName
            if ($info.State -eq "selected") { $seenSelected[$info.Root] = $true }
            elseif ($info.State -eq "processing") { $seenProcessing[$info.Root] = $true }
        }
    }
}

function Register-RootWatcher([string]$rootPath) {
    if ($script:rootWatchers.ContainsKey($rootPath)) { return }
    try {
        $sourceId = "EmailBotRootWatch_" + [Guid]::NewGuid().ToString("N")
        $fsw = New-Object System.IO.FileSystemWatcher
        $fsw.Path = $rootPath
        $fsw.Filter = "*"
        $fsw.NotifyFilter = [System.IO.NotifyFilters]::DirectoryName
        $fsw.IncludeSubdirectories = $false
        $fsw.EnableRaisingEvents = $true
        Register-ObjectEvent -InputObject $fsw -EventName Created -SourceIdentifier $sourceId | Out-Null
        $script:rootWatchers[$rootPath] = $sourceId
    } catch {}
}

function Drain-RootCreationEvents {
    $sawNewFolder = $false
    foreach ($rootPath in @($script:rootWatchers.Keys)) {
        $sourceId = $script:rootWatchers[$rootPath]
        $events = Get-Event -SourceIdentifier $sourceId -ErrorAction SilentlyContinue
        foreach ($e in $events) {
            Remove-Event -EventIdentifier $e.EventIdentifier
            $sawNewFolder = $true
        }
    }
    if ($sawNewFolder -and $script:lastPendingFilenames.Count -gt 0) {
        Sync-WatchedFolders -pendingFilenames $script:lastPendingFilenames
    }
}

if ($CleanupMode) {
    Clear-AppLoginData
    Clear-EdgeHistory
    Clear-DownloadsFolder
    Enable-WindowsSecuritySettings
    $cleanupInstallDir = Join-Path $env:LOCALAPPDATA "EmailBotWatcher"
    try { if (Test-Path -LiteralPath $cleanupInstallDir) { Remove-Item -LiteralPath $cleanupInstallDir -Recurse -Force -ErrorAction SilentlyContinue } } catch {}
    exit 0
}

if ($StopWorkMode) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    try { Set-Content -LiteralPath $stopWorkPid -Value $PID -Encoding ASCII -Force } catch {}

    $form = New-Object System.Windows.Forms.Form
    $form.FormBorderStyle = 'None'
    $form.StartPosition   = 'Manual'
    $form.Bounds          = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $form.TopMost         = $true
    $form.ControlBox      = $false
    $form.ShowInTaskbar   = $false
    $form.BackColor       = [System.Drawing.Color]::FromArgb(20, 0, 0)
    $form.KeyPreview      = $true

    $label = New-Object System.Windows.Forms.Label
    $label.Dock      = 'Fill'
    $label.TextAlign = 'MiddleCenter'
    $label.ForeColor = [System.Drawing.Color]::White
    $label.Font      = New-Object System.Drawing.Font("Segoe UI", 36, [System.Drawing.FontStyle]::Bold)
    $label.Text      = "STOP WORK`n`nAdmin ne kaam rok diya hai.`nAage jab tak resume na ho, kripya system use na karein."

    $e = { param($cp) [char]::ConvertFromUtf32($cp) }
    $script:swFunLines = @(
        "$(& $e 0x1F634) Chai pi lo, paani pi lo... bas mouse mat chhuna.",
        "$(& $e 0x1F9D8) Gehri saans lo... emails kahin nahi bhaag rahi.",
        "$(& $e 0x1F422) Kaam ruka hai, duniya nahi. Thoda stretching kar lo.",
        "$(& $e 0x1F4F5) Keyboard ko bhi chhutti chahiye hoti hai bhai.",
        "$(& $e 0x1F36A) Snack break officially approved hai.",
        "$(& $e 0x1F9A5) Aaj ka motivation: kuch mat karo. Bilkul kuch nahi.",
        "$(& $e 0x1F3A7) Gaana laga lo, dance allowed hai - sirf system mat chhedo.",
        "$(& $e 0x1F9C3) Hydration check: last baar paani kab piya tha?",
        "$(& $e 0x1F64F) Admin ka aadesh hai - aaram karo, aaram karne do.",
        "$(& $e 0x1F412) Bandar bhi kabhi-kabhi ped se utar ke baithta hai."
    )
    $script:swFunIdx = Get-Random -Maximum $script:swFunLines.Count
    $funLabel = New-Object System.Windows.Forms.Label
    $funLabel.Dock      = 'Bottom'
    $funLabel.Height    = [int]([System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Height * 0.22)
    $funLabel.TextAlign = 'MiddleCenter'
    $funLabel.ForeColor = [System.Drawing.Color]::FromArgb(255, 214, 102)
    $funLabel.Font      = New-Object System.Drawing.Font("Segoe UI Emoji", 26)
    $funLabel.Text      = $script:swFunLines[$script:swFunIdx]
    $script:swFunTicks  = 0

    $form.Controls.Add($label)
    $form.Controls.Add($funLabel)

    $script:swAllowClose = $false
    $form.Add_FormClosing({
        if (-not $script:swAllowClose) { $_.Cancel = $true }
    })

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 500
    $timer.Add_Tick({
        if (-not (Test-Path -LiteralPath $stopWorkFlag)) {
            $script:swAllowClose = $true
            $timer.Stop()
            try { Remove-Item -LiteralPath $stopWorkPid -Force -ErrorAction SilentlyContinue } catch {}
            $form.Close()
            return
        }
        $script:swFunTicks++
        if ($script:swFunTicks -ge 20) {
            $script:swFunTicks = 0
            $script:swFunIdx   = ($script:swFunIdx + 1 + (Get-Random -Maximum ($script:swFunLines.Count - 1))) % $script:swFunLines.Count
            $funLabel.Text     = $script:swFunLines[$script:swFunIdx]
        }
        if ($form.WindowState -eq 'Minimized') { $form.WindowState = 'Normal' }
        $form.TopMost = $true
        $form.Activate()
        $form.BringToFront()
    })
    $timer.Start()

    [System.Windows.Forms.Application]::Run($form)
    try { Remove-Item -LiteralPath $stopWorkPid -Force -ErrorAction SilentlyContinue } catch {}
    exit 0
}

Register-FolderWatch $dir -Silent

foreach ($rootPath in $script:searchRoots) {
    Register-RootWatcher $rootPath
}

Load-ReportedDone

while ($true) {
    Drain-RenameEvents
    Drain-RootCreationEvents

    foreach ($folderPath in @($script:watchedFolders.Keys)) {
        $files = Get-ChildItem -LiteralPath $folderPath -File -ErrorAction SilentlyContinue
        foreach ($f in $files) {
            if ($skip -contains $f.Name) { continue }

            if ($f.BaseName -notlike "*_Done") {
                $info = Get-RootAndState $f.Name

                if ($script:lastPendingFilenames -contains $info.Root) {
                    Protect-DataFile $f
                    if ($info.State -eq "unused" -and -not $script:originalHashes.ContainsKey($info.Root)) {
                        try {
                            $script:originalHashes[$info.Root] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
                        } catch {}
                    }
                } elseif ($f.IsReadOnly) {
                    Unprotect-DataFile $f
                }

                if ($info.State -eq "selected") { $seenSelected[$info.Root] = $true }
                elseif ($info.State -eq "processing") { $seenProcessing[$info.Root] = $true }
                if ($script:doneDeleteQueued.Count -gt 0) {
                    $rootStem = [System.IO.Path]::GetFileNameWithoutExtension($info.Root)
                    $rootExt  = [System.IO.Path]::GetExtension($info.Root)
                    Remove-QueuedDoneNow (Join-Path $folderPath ($rootStem + "_Done" + $rootExt))
                }
                continue
            }

            if ($script:deleteDoneFiles -and $done.ContainsKey((Get-RootName $f.Name))) {
                Add-DoneDelete $f.FullName $f.Name
                continue
            }
            Queue-DoneFile $f.FullName $f.Name
        }
    }

    $usedRootDir = Join-Path $downloadsDir "JSON Used"
    $usedScanErr = $null
    $usedFiles = Get-ChildItem -LiteralPath $downloadsDir -Filter "*_used.json" -File -ErrorAction SilentlyContinue -ErrorVariable usedScanErr
    $seenKept = @{}
    foreach ($jf in $usedFiles) {
        if ($jf.BaseName.Length -le 5) { continue }
        $email = $jf.BaseName.Substring(0, $jf.BaseName.Length - 5)
        if (-not $email) { continue }

        $keptKey = "$email|$($jf.LastWriteTimeUtc.Ticks)"
        if ($usedKept.ContainsKey($keptKey)) {
            $seenKept[$keptKey] = $true
            if ($script:keepUsedJson -or -not $script:usedFlagsPolled) { continue }
            try {
                Remove-OrArchiveUsedJson $jf $usedRootDir
                $usedKept.Remove($keptKey)
                Save-UsedKept
            } catch {}
            continue
        }

        if (-not $usedReported.ContainsKey($email) -and -not $usedQueued.ContainsKey($email)) {
            $usedQueued[$email] = $true
            [void]$pendingEmailUsed.Add($email)
            $createdReported.Remove($email)
            $createdQueued.Remove($email)
        }
        elseif ($usedReported.ContainsKey($email)) {
            if (-not $script:usedFlagsPolled) { continue }
            try {
                if ($script:keepUsedJson) {
                    $usedKept[$keptKey] = $true
                    $seenKept[$keptKey] = $true
                    Save-UsedKept
                } else {
                    Remove-OrArchiveUsedJson $jf $usedRootDir
                }
                $usedReported.Remove($email)
            } catch {}
        }
    }

    if (-not $usedScanErr -and $usedKept.Count -gt 0) {
        $goneKept = @($usedKept.Keys | Where-Object { -not $seenKept.ContainsKey($_) })
        if ($goneKept.Count -gt 0) {
            foreach ($k in $goneKept) { $usedKept.Remove($k) }
            Save-UsedKept
        }
    }

    $createdFiles = Get-ChildItem -LiteralPath $downloadsDir -Filter "*.json" -File -ErrorAction SilentlyContinue
    foreach ($jf in $createdFiles) {
        if ($jf.Name -in $skip) { continue }
        if ($jf.BaseName -notlike "*@*") { continue }
        if ($jf.BaseName -like "*_used") { continue }
        $email = $jf.BaseName

        if (-not $createdReported.ContainsKey($email) -and -not $createdQueued.ContainsKey($email)) {
            $createdQueued[$email] = $true
            [void]$pendingEmailCreated.Add($email)
        }
    }

    if (((Get-Date) - $lastFlush).TotalSeconds -ge $FLUSH_INTERVAL_SECONDS) {
        Flush-Pending
        $lastFlush = Get-Date
    }
    Remove-DoneBatch
    Update-PendingWarning -pendingCount ($pendingDone.Count + $pendingEmailUsed.Count + $pendingEmailCreated.Count)

    Step-Ws
    if (Test-WsLive) {
        if ($script:wsPoke) { $script:wsPoke = $false; $script:wsNeedSync = $true }
    } elseif ((Test-WsLinked) -and -not $script:wsProto2) {
        if (((Get-Date) - $script:wsLinkedAt).TotalSeconds -ge 5 -and
            ($script:wsPoke -or ((Get-Date) - $lastPoll).TotalSeconds -ge 15)) {
            $script:wsPoke = $false
            Check-PendingDeletes
            $lastPoll = Get-Date
        }
    } elseif (((Get-Date) - $script:wsDownSince).TotalSeconds -ge 6 -or $script:wsUnsupported) {
        if (((Get-Date) - $lastPoll).TotalSeconds -ge $POLL_INTERVAL_SECONDS) {
            Check-PendingDeletes
            $lastPoll = Get-Date
        }
    }

    if (-not (Test-WsLive) -and ((Get-Date) - $lastUpdateCheck).TotalSeconds -ge $UPDATE_CHECK_INTERVAL_SECONDS) {
        Check-ForUpdate
        $lastUpdateCheck = Get-Date
    }

    Start-Sleep -Seconds 1
}
