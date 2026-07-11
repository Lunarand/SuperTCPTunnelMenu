# super-file.ps1
$ErrorActionPreference = "Stop"
$TrackDir = "$env:USERPROFILE\.cf_tunnels"
if (-not (Test-Path $TrackDir)) { New-Item -ItemType Directory -Path $TrackDir | Out-Null }

# 1. Install cloudflared for Windows if missing
function Install-Cloudflared {
    $cfPath = "$env:USERPROFILE\cloudflared.exe"
    if (-not (Test-Path $cfPath)) {
        Write-Host "cloudflared is not installed. Downloading..." -ForegroundColor Yellow
        Invoke-WebRequest -Uri "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe" -OutFile $cfPath
        Write-Host "cloudflared installed successfully!" -ForegroundColor Green
    }
    return $cfPath
}

$cfExe = Install-Cloudflared

# 2. Get and validate Port
function Get-ValidPort {
    while ($true) {
        $port = Read-Host "Enter the port you want to forward (e.g., 8080)"
        if ($port -match '^\d+$' -and [int]$port -ge 1 -and [int]$port -le 65535) {
            return [int]$port
        }
        Write-Host "Invalid input. Please enter a valid port number between 1 and 65535." -ForegroundColor Red
    }
}

# 3. Check Local Service
function Check-LocalService {
    param([int]$Port)
    Write-Host "Checking if a service is running on port $Port..." -ForegroundColor Cyan
    $connection = Test-NetConnection -ComputerName 127.0.0.1 -Port $Port -WarningAction SilentlyContinue
    if ($connection.TcpTestSucceeded) {
        Write-Host "Success: An active service was detected on port $Port!" -ForegroundColor Green
        return $true
    } else {
        Write-Host "Warning: No active local service detected on port $Port." -ForegroundColor Yellow
        $proceed = Read-Host "Do you want to create the tunnel anyway? (y/n)"
        if ($proceed -match '^[Yy]') { return $true }
        Write-Host "Aborted. Returning to menu." -ForegroundColor Red
        return $false
    }
}

# 4. Extract URL from logs
function Wait-ForUrl {
    param([string]$LogFile)
    Write-Host -NoNewline "Requesting tunnel URL from Cloudflare..."
    for ($i = 0; $i -lt 15; $i++) {
        if (Test-Path $LogFile) {
            $match = Select-String -Path $LogFile -Pattern 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' | Select-Object -First 1
            if ($match) {
                Write-Host "`nSuccess! Your URL is: " -ForegroundColor Green -NoNewline
                Write-Host $match.Matches.Value -ForegroundColor Cyan
                return
            }
        }
        Write-Host -NoNewline "."
        Start-Sleep -Seconds 1
    }
    Write-Host "`nTimeout: Could not retrieve URL. Check logs at $LogFile" -ForegroundColor Red
}

# 5. Cleanup dead background tunnels
function Cleanup-DeadTunnels {
    Get-ChildItem -Path $TrackDir -Filter "*.pid" | ForEach-Object {
        $pidValue = Get-Content $_.FullName
        $process = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
        if (-not $process -or $process.ProcessName -notmatch "cloudflared") {
            $port = $_.BaseName
            Remove-Item "$TrackDir\$port.pid" -Force -ErrorAction SilentlyContinue
            Remove-Item "$TrackDir\$port.log" -Force -ErrorAction SilentlyContinue
        }
    }
}

# Main Application Run
while ($true) {
    Cleanup-DeadTunnels
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "           SuperTCPTunnelMenu           " -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "1) Start trycloudflare (Foreground)"
    Write-Host "2) Start trycloudflare (Background)"
    Write-Host "3) Stop a Background Tunnel"
    Write-Host "4) List Active Tunnels"
    Write-Host "5) Exit"
    Write-Host "========================================" -ForegroundColor Cyan
    $option = Read-Host "Select an option [1-5]"

    switch ($option) {
        '1' {
            $port = Get-ValidPort
            if (-not (Check-LocalService -Port $port)) { continue }
            Write-Host "Starting tunnel on port $port. Press Ctrl+C to stop." -ForegroundColor Yellow
            & $cfExe tunnel --url http://localhost:$port
        }
        '2' {
            $port = Get-ValidPort
            if (Test-Path "$TrackDir\$port.pid") {
                Write-Host "A tunnel is already running on port $port!" -ForegroundColor Red
                continue
            }
            if (-not (Check-LocalService -Port $port)) { continue }

            $logFile = "$TrackDir\$port.log"
            $pidFile = "$TrackDir\$port.pid"
            
            # Run in background and pipe errors/output to log
            $process = Start-Process -FilePath $cfExe -ArgumentList "tunnel --url http://localhost:$port" -NoNewWindow -RedirectStandardError $logFile -RedirectStandardOutput $logFile -PassThru
            $process.Id | Out-File -FilePath $pidFile -Encoding ASCII
            
            Wait-ForUrl -LogFile $logFile
        }
        '3' {
            $pids = Get-ChildItem -Path $TrackDir -Filter "*.pid"
            if (-not $pids) {
                Write-Host "No background tunnels are currently running." -ForegroundColor Yellow
                continue
            }
            Write-Host "`nActive Tunnels:" -ForegroundColor Yellow
            $pids | ForEach-Object { Write-Host " - Port $($_.BaseName)" }

            $stopPort = Read-Host "Enter the port to stop (or 'all' to stop everything)"
            if ($stopPort -eq 'all') {
                $pids | ForEach-Object {
                    $p = Get-Content $_.FullName
                    Stop-Process -Id $p -Force -ErrorAction SilentlyContinue
                    Remove-Item $_.FullName -Force
                    Remove-Item "$TrackDir\$($_.BaseName).log" -Force -ErrorAction SilentlyContinue
                }
                Write-Host "All background tunnels stopped." -ForegroundColor Green
            } elseif (Test-Path "$TrackDir\$stopPort.pid") {
                $p = Get-Content "$TrackDir\$stopPort.pid"
                Stop-Process -Id $p -Force -ErrorAction SilentlyContinue
                Remove-Item "$TrackDir\$stopPort.pid" -Force
                Remove-Item "$TrackDir\$stopPort.log" -Force -ErrorAction SilentlyContinue
                Write-Host "Tunnel on port $stopPort stopped." -ForegroundColor Green
            } else {
                Write-Host "No active tunnel found for port $stopPort." -ForegroundColor Red
            }
        }
        '4' {
            $pids = Get-ChildItem -Path $TrackDir -Filter "*.pid"
            if (-not $pids) {
                Write-Host "No background tunnels are currently running." -ForegroundColor Yellow
            } else {
                Write-Host "`nActive Background Tunnels:" -ForegroundColor Green
                $pids | ForEach-Object {
                    $port = $_.BaseName
                    $logFile = "$TrackDir\$port.log"
                    $url = ""
                    if (Test-Path $logFile) {
                        $match = Select-String -Path $logFile -Pattern 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' | Select-Object -First 1
                        if ($match) { $url = $match.Matches.Value }
                    }
                    Write-Host " -> Port $port : $url" -ForegroundColor Cyan
                }
            }
        }
        '5' {
            Write-Host "Exiting SuperTCPTunnelMenu..." -ForegroundColor Green
            break
        }
        default {
            Write-Host "Invalid option. Please enter a number between 1 and 5." -ForegroundColor Red
        }
    }
}
