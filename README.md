SYNOPSIS: 
    Internet speed test using free public endpoints (no self-hosted servers).

DESCRIPTION

    * Measures latency, jitter, download and upload throughput.
    
    *  Works in Windows PowerShell 5.1 and PowerShell 7+
    
    *  Pure PowerShell / .NET (no external modules, no installs)
    
    *  Honors the system proxy and uses the logged-on user's credentials
    
    *  Shows the real underlying error when something is blocked

    *  Falls back to a single smaller stream if parallel transfers fail
    
    *  Optional CSV logging for tracking results over time

    Providers:
      Cloudflare (default) - speed.cloudflare.com (HTTPS)
      Tele2                - speedtest.tele2.net  (HTTP; fallback if Cloudflare is blocked)

EXAMPLE
```
    .\Speedtest.ps1
```

EXAMPLE
```
    .\Speedtest.ps1 -DownloadMB 50 -UploadMB 20 -Streams 6 -LogPath C:\Temp\speedtest.csv
```
EXAMPLE
```
    .\Speedtest.ps1 -Proxy http://proxy.corp.local:8080
```
EXAMPLE
```
    .\Speedtest.ps1 -Provider Tele2
```
