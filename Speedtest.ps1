<#
.SYNOPSIS
    Internet speed test using free public endpoints (no self-hosted servers).

.DESCRIPTION
    Measures latency, jitter, download and upload throughput.
    - Works in Windows PowerShell 5.1 and PowerShell 7+
    - Pure PowerShell / .NET (no external modules, no installs)
    - Honors the system proxy and uses the logged-on user's credentials
    - Shows the real underlying error when something is blocked
    - Falls back to a single smaller stream if parallel transfers fail
    - Optional CSV logging for tracking results over time

    Providers:
      Cloudflare (default) - speed.cloudflare.com (HTTPS)
      Tele2                - speedtest.tele2.net  (HTTP; fallback if Cloudflare is blocked)

.EXAMPLE
    .\Speedtest.ps1

.EXAMPLE
    .\Speedtest.ps1 -DownloadMB 50 -UploadMB 20 -Streams 6 -LogPath C:\Temp\speedtest.csv

.EXAMPLE
    .\Speedtest.ps1 -Proxy http://proxy.corp.local:8080

.EXAMPLE
    .\Speedtest.ps1 -Provider Tele2
#>

[CmdletBinding()]
param(
    [ValidateSet('Cloudflare', 'Tele2')]
    [string]$Provider = 'Cloudflare',

    [ValidateRange(1, 200)]
    [int]$DownloadMB = 25,        # total download volume across all streams

    [ValidateRange(1, 100)]
    [int]$UploadMB = 10,          # total upload volume across all streams

    [ValidateRange(1, 16)]
    [int]$Streams = 1,            # parallel connections (increase for faster links)

    [ValidateRange(3, 50)]
    [int]$LatencySamples = 10,

    [string]$Proxy,               # e.g. http://proxy.corp.local:8080 (default = system proxy)

    [string]$LogPath              # optional CSV path to append results to
)

$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 does not load System.Net.Http by default
try {
    Add-Type -AssemblyName System.Net.Http
} catch {
    try { [void][System.Reflection.Assembly]::LoadWithPartialName('System.Net.Http') } catch { }
}

# TLS 1.2 (needed on older Windows PowerShell)
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

# ---------------------------------------------------------------- providers
$Providers = @{
    Cloudflare = @{
        Ping     = 'https://speed.cloudflare.com/__down?bytes=0'
        Download = { param($bytes) "https://speed.cloudflare.com/__down?bytes=$bytes" }
        Upload   = 'https://speed.cloudflare.com/__up'
        Meta     = 'https://speed.cloudflare.com/meta'
    }
    Tele2 = @{
        Ping     = 'http://speedtest.tele2.net/1KB.zip'
        Download = { param($bytes) 'http://speedtest.tele2.net/10MB.zip' }   # fixed-size file
        FixedDownloadBytes = 10MB
        Upload   = 'http://speedtest.tele2.net/upload.php'
        Meta     = $null
    }
}
$P = $Providers[$Provider]

# ---------------------------------------------------------------- helpers
function Get-RealError($ex) {
    # Unwrap AggregateException / InnerException chains into a readable string
    $messages = New-Object System.Collections.Generic.List[string]
    $stack = New-Object System.Collections.Generic.Stack[object]
    $stack.Push($ex)
    while ($stack.Count -gt 0) {
        $e = $stack.Pop()
        if ($null -eq $e) { continue }
        if ($e -is [System.AggregateException]) {
            foreach ($inner in $e.InnerExceptions) { $stack.Push($inner) }
            continue
        }
        $messages.Add(("{0}: {1}" -f $e.GetType().Name, $e.Message))
        if ($e.InnerException) { $stack.Push($e.InnerException) }
    }
    return (($messages | Select-Object -Unique) -join ' | ')
}

function Get-Mbps([double]$bytes, [double]$seconds) {
    if ($seconds -le 0) { return 0 }
    return [math]::Round(($bytes * 8) / 1e6 / $seconds, 2)
}

function Wait-AllTasks($tasks) {
    try {
        [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($tasks))
    } catch {
        throw (Get-RealError $_.Exception)
    }
}

function New-SpeedClient {
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $true

    if ($Proxy) {
        $wp = New-Object System.Net.WebProxy($Proxy, $true)
        $wp.Credentials = [System.Net.CredentialCache]::DefaultCredentials
        $handler.Proxy = $wp
        $handler.UseProxy = $true
    }
    else {
        $handler.UseProxy = $true
        $sysProxy = [System.Net.WebRequest]::GetSystemWebProxy()
        $sysProxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials
        $handler.Proxy = $sysProxy
    }

    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(120)
    [void]$client.DefaultRequestHeaders.TryAddWithoutValidation('Cache-Control', 'no-cache')
    [void]$client.DefaultRequestHeaders.UserAgent.TryParseAdd('Mozilla/5.0 PowerShell-SpeedTest/1.1')
    return $client
}

function Invoke-DownloadTest([int]$streamCount, [int]$bytesPerStream) {
    $url = & $P.Download $bytesPerStream
    if ($P.FixedDownloadBytes) { $bytesPerStream = $P.FixedDownloadBytes }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    $reqTasks = @(1..$streamCount | ForEach-Object {
        $client.GetAsync($url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead)
    })
    Wait-AllTasks $reqTasks

    # Check HTTP status of each response before reading bodies
    foreach ($t in $reqTasks) {
        $code = [int]$t.Result.StatusCode
        if ($code -lt 200 -or $code -ge 300) {
            throw ("HTTP {0} {1} from {2}" -f $code, $t.Result.ReasonPhrase, $url)
        }
    }

    $copyTasks = @(foreach ($t in $reqTasks) {
        $stream = $t.Result.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $stream.CopyToAsync([System.IO.Stream]::Null)
    })
    Wait-AllTasks $copyTasks
    $sw.Stop()

    foreach ($t in $reqTasks) { $t.Result.Dispose() }

    [pscustomobject]@{
        Bytes   = [int64]$bytesPerStream * $streamCount
        Seconds = $sw.Elapsed.TotalSeconds
    }
}

function Invoke-UploadTest([int]$streamCount, [int]$bytesPerStream) {
    $payload = New-Object byte[] $bytesPerStream
    (New-Object System.Random).NextBytes($payload)   # incompressible data

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    $upTasks = @(1..$streamCount | ForEach-Object {
        $content = New-Object System.Net.Http.ByteArrayContent(, $payload)
        $content.Headers.ContentType = New-Object System.Net.Http.Headers.MediaTypeHeaderValue('application/octet-stream')
        $client.PostAsync($P.Upload, $content)
    })
    Wait-AllTasks $upTasks
    $sw.Stop()

    foreach ($t in $upTasks) {
        $code = [int]$t.Result.StatusCode
        if ($code -lt 200 -or $code -ge 300) {
            throw ("HTTP {0} {1} from {2}" -f $code, $t.Result.ReasonPhrase, $P.Upload)
        }
        $t.Result.Dispose()
    }

    [pscustomobject]@{
        Bytes   = [int64]$bytesPerStream * $streamCount
        Seconds = $sw.Elapsed.TotalSeconds
    }
}

$client = New-SpeedClient

# ---------------------------------------------------------------- header
Write-Host ""
Write-Host "=== Speed Test ===" -ForegroundColor Cyan
Write-Host ("Provider : {0}" -f $Provider)
Write-Host ("Host     : {0}" -f $env:COMPUTERNAME)
Write-Host ("Time     : {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

$meta = $null
if ($P.Meta) {
    try {
        $metaParams = @{ Uri = $P.Meta; TimeoutSec = 15; UseBasicParsing = $true; ErrorAction = 'Stop' }
        if ($Proxy) {
            $metaParams['Proxy'] = $Proxy
            $metaParams['ProxyUseDefaultCredentials'] = $true
        } else {
            $sp = ([System.Net.WebRequest]::GetSystemWebProxy()).GetProxy($P.Meta)
            if ($sp -and $sp.AbsoluteUri -ne $P.Meta) {
                $metaParams['Proxy'] = $sp
                $metaParams['ProxyUseDefaultCredentials'] = $true
            }
        }
        $meta = Invoke-RestMethod @metaParams
    } catch { $meta = $null }

    if ($meta) {
        Write-Host ("Public IP: {0}" -f $meta.clientIp)
        Write-Host ("ISP/ASN  : {0} (AS{1})" -f $meta.asOrganization, $meta.asn)
        Write-Host ("Edge     : {0}, {1}" -f $meta.city, $meta.country)
    }
}
Write-Host ""

# ---------------------------------------------------------------- latency
Write-Host "Testing latency..." -ForegroundColor Yellow
$latencies = @()
try {
    # First request warms up DNS/TCP/TLS and is discarded
    $r = $client.GetAsync($P.Ping).GetAwaiter().GetResult()
    [void]$r.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    $r.Dispose()

    for ($i = 0; $i -lt $LatencySamples; $i++) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $r = $client.GetAsync($P.Ping).GetAwaiter().GetResult()
        [void]$r.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        $sw.Stop()
        $r.Dispose()
        $latencies += $sw.Elapsed.TotalMilliseconds
    }
}
catch {
    Write-Host ("Latency test failed: {0}" -f (Get-RealError $_.Exception)) -ForegroundColor Red
    Write-Host "Check proxy/firewall rules for the provider's domain, or try -Provider Tele2 / -Proxy." -ForegroundColor Red
    exit 1
}

$latAvg = [math]::Round(($latencies | Measure-Object -Average).Average, 1)
$latMin = [math]::Round(($latencies | Measure-Object -Minimum).Minimum, 1)
$latMax = [math]::Round(($latencies | Measure-Object -Maximum).Maximum, 1)
$jitter = 0
if ($latencies.Count -gt 1) {
    $diffs = for ($i = 1; $i -lt $latencies.Count; $i++) { [math]::Abs($latencies[$i] - $latencies[$i - 1]) }
    $jitter = [math]::Round(($diffs | Measure-Object -Average).Average, 1)
}
Write-Host ("  Latency: avg {0} ms (min {1} / max {2}), jitter {3} ms" -f $latAvg, $latMin, $latMax, $jitter)

# ---------------------------------------------------------------- download
Write-Host "Testing download ($DownloadMB MB across $Streams streams)..." -ForegroundColor Yellow
$dlMbps = 0
$dlStreamsUsed = $Streams
$perStreamDown = [int][math]::Floor(($DownloadMB * 1MB) / $Streams)
$dl = $null
try {
    $dl = Invoke-DownloadTest $Streams $perStreamDown
}
catch {
    Write-Host ("  Parallel download failed: {0}" -f $_) -ForegroundColor DarkYellow
    if ($Streams -gt 1 -or $perStreamDown -gt 5MB) {
        Write-Host "  Retrying with 1 stream x 5 MB..." -ForegroundColor Yellow
        try {
            $dlStreamsUsed = 1
            $dl = Invoke-DownloadTest 1 (5MB)
        } catch {
            Write-Host ("  Download test failed: {0}" -f $_) -ForegroundColor Red
            Write-Host "  Try: -Provider Tele2, -Proxy <url>, or ask IT to allow speed.cloudflare.com." -ForegroundColor Red
        }
    }
}
if ($dl) {
    $dlMbps = Get-Mbps $dl.Bytes $dl.Seconds
    Write-Host ("  Download: {0} Mbps  ({1:N1} MB in {2:N2}s)" -f $dlMbps, ($dl.Bytes / 1MB), $dl.Seconds) -ForegroundColor Green
}

# ---------------------------------------------------------------- upload
Write-Host "Testing upload ($UploadMB MB across $Streams streams)..." -ForegroundColor Yellow
$ulMbps = 0
$perStreamUp = [int][math]::Floor(($UploadMB * 1MB) / $Streams)
$ul = $null
try {
    $ul = Invoke-UploadTest $Streams $perStreamUp
}
catch {
    Write-Host ("  Parallel upload failed: {0}" -f $_) -ForegroundColor DarkYellow
    if ($Streams -gt 1 -or $perStreamUp -gt 2MB) {
        Write-Host "  Retrying with 1 stream x 2 MB..." -ForegroundColor Yellow
        try {
            $ul = Invoke-UploadTest 1 (2MB)
        } catch {
            Write-Host ("  Upload test failed: {0}" -f $_) -ForegroundColor Red
        }
    }
}
if ($ul) {
    $ulMbps = Get-Mbps $ul.Bytes $ul.Seconds
    Write-Host ("  Upload:   {0} Mbps  ({1:N1} MB in {2:N2}s)" -f $ulMbps, ($ul.Bytes / 1MB), $ul.Seconds) -ForegroundColor Green
}

# ---------------------------------------------------------------- summary
Write-Host ""
Write-Host "=== Results ===" -ForegroundColor Cyan
Write-Host ("Download : {0} Mbps" -f $dlMbps)
Write-Host ("Upload   : {0} Mbps" -f $ulMbps)
Write-Host ("Latency  : {0} ms (jitter {1} ms)" -f $latAvg, $jitter)
Write-Host ""

$result = [pscustomobject]@{
    Timestamp    = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    ComputerName = $env:COMPUTERNAME
    UserName     = $env:USERNAME
    Provider     = $Provider
    PublicIP     = if ($meta) { $meta.clientIp } else { '' }
    ISP          = if ($meta) { $meta.asOrganization } else { '' }
    DownloadMbps = $dlMbps
    UploadMbps   = $ulMbps
    LatencyMs    = $latAvg
    JitterMs     = $jitter
    Streams      = $Streams
}

if ($LogPath) {
    try {
        $dir = Split-Path -Parent $LogPath
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $result | Export-Csv -Path $LogPath -Append -NoTypeInformation
        Write-Host "Result appended to $LogPath" -ForegroundColor DarkGray
    } catch {
        Write-Host "Could not write log: $($_.Exception.Message)" -ForegroundColor Red
    }
}

$client.Dispose()
$result
