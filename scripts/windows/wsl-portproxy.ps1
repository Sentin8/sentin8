# wsl-portproxy.ps1 - keep the Windows -> WSL2 port forward pointed at the
# CURRENT WSL VM IP (RIGMODE-1 `public`-mode ingress prerequisite).
#
# The rig's internet-facing path is: internet client -> home router
# (public IP, e.g. 154.64.64.170) -> Windows host (LAN IP, e.g.
# 192.168.2.128) -> WSL2 VM (e.g. 172.22.216.164) -> sentin8-proxy
# (0.0.0.0:443, and :80 in public mode). WSL2 sits behind the Windows
# host's NAT, so the router's forward reaches Windows only - the last
# hop needs a netsh portproxy. The WSL2 IP changes on every WSL
# restart, so a static portproxy dies silently; this script
# reconciles the forwarding to the live IP.
#
# Usage (elevated PowerShell - netsh and the firewall cmdlets need it):
#   powershell -ExecutionPolicy Bypass -File scripts\windows\wsl-portproxy.ps1
#
# Register it as a Windows scheduled task so it re-runs at logon and
# every 5 minutes (covers wsl --shutdown mid-session):
#   powershell -ExecutionPolicy Bypass -File scripts\windows\wsl-portproxy.ps1 -RegisterTask
#
# It is idempotent and churn-free:
#   - stale entries (our ports, a WSL-range connect address, wrong IP)
#     are deleted - unrelated portproxy rows are never touched;
#   - live entries are added only when absent;
#   - the firewall rule is created only when missing.
# Every action lands in "$env:ProgramData\sentin8\wsl-portproxy.log".

param(
    # Register the logon + 5-minute scheduled task instead of running once.
    [switch]$RegisterTask
)

$ErrorActionPreference = 'Stop'

# ---- tune here ----
$Distro        = 'Ubuntu'      # `wsl -l -q` to list distros
$ListenPorts   = @(80, 443)    # 443 = TLS ingress, 80 = http-01 challenge (public mode)
$ListenAddress = '0.0.0.0'     # all interfaces - survives LAN/DHCP IP changes too
$FirewallRule  = 'WSL2 ingress 80+443 (sentin8 rig)'
$TaskName      = 'sentin8 wsl portproxy refresh'
$ScriptPath    = 'C:\Scripts\wsl-portproxy.ps1'   # the scheduled task runs THIS copy
# -------------------

$Log = "$env:ProgramData\sentin8\wsl-portproxy.log"
New-Item -ItemType Directory -Force -Path (Split-Path $Log) | Out-Null

# -RegisterTask: install the scheduled task (logon + 5-minute repetition,
# elevated) that keeps this script's copy at ScriptPath current, then exit.
# The task runs ScriptPath - copy the script there first.
if ($RegisterTask) {
    New-Item -ItemType Directory -Force -Path (Split-Path $ScriptPath) | Out-Null
    Copy-Item -Force $PSCommandPath $ScriptPath

    $action   = New-ScheduledTaskAction -Execute 'powershell.exe' `
                -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $ScriptPath"
    $atLogon  = New-ScheduledTaskTrigger -AtLogOn
    $repeat   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
                -RepetitionInterval (New-TimeSpan -Minutes 5) `
                -RepetitionDuration (New-TimeSpan -Days 3650)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    Register-ScheduledTask -TaskName $TaskName -Action $action `
        -Trigger $atLogon, $repeat -Settings $settings -RunLevel Highest -Force | Out-Null
    Add-Content $Log "$(Get-Date -Format s) task registered ($TaskName -> $ScriptPath)"
    Write-Host "task '$TaskName' registered (logon + 5-minute, from $ScriptPath)"
    exit 0
}

function Get-WslIp {
    # Wait up to ~2 min: at logon the WSL VM may not be up yet.
    for ($i = 0; $i -lt 24; $i++) {
        $line = (& wsl.exe -d $Distro -- hostname -I) 2>$null
        if ($LASTEXITCODE -eq 0 -and $line) {
            $ip = ($line -split '\s+' | Where-Object { $_ -match '^\d+\.' }) | Select-Object -First 1
            if ($ip) { return $ip.Trim() }
        }
        Start-Sleep -Seconds 5
    }
    throw "no WSL IP after 2 minutes - is distro '$Distro' installed?"
}

try {
    $wslIp = Get-WslIp

    # 1. Drop OUR stale entries: connect address is a WSL-range private IP
    #    (172.16-31) different from the current one, on our connect ports.
    #    Unrelated portproxy rows are left untouched.
    $rows = netsh interface portproxy show v4tov4 | ForEach-Object {
        if ($_ -match '^\s*([\d.]+)\s+(\d+)\s+([\d.]+)\s+(\d+)\s*$') {
            [pscustomobject]@{
                ListenAddress  = $matches[1]
                ListenPort     = [int]$matches[2]
                ConnectAddress = $matches[3]
                ConnectPort    = [int]$matches[4]
            }
        }
    }
    foreach ($r in $rows) {
        $isWslIp = $r.ConnectAddress -match '^172\.(1[6-9]|2\d|3[01])\.'
        $isStale = ($ListenPorts -contains $r.ConnectPort) -and $isWslIp -and
                   ($r.ConnectAddress -ne $wslIp)
        if ($isStale) {
            netsh interface portproxy delete v4tov4 `
                listenaddress=$r.ListenAddress listenport=$r.ListenPort | Out-Null
            Add-Content $Log "$(Get-Date -Format s) removed stale $($r.ListenAddress):$($r.ListenPort) -> $($r.ConnectAddress)"
        }
    }

    # 2. Ensure one live entry per port (add only when absent - no churn).
    foreach ($p in $ListenPorts) {
        $live = $rows | Where-Object {
            $_.ListenAddress -eq $ListenAddress -and $_.ListenPort -eq $p -and
            $_.ConnectAddress -eq $wslIp
        }
        if (-not $live) {
            netsh interface portproxy add v4tov4 `
                listenaddress=$ListenAddress listenport=$p `
                connectaddress=$wslIp connectport=$p | Out-Null
            Add-Content $Log "$(Get-Date -Format s) added $ListenAddress`:$p -> ${wslIp}:$p"
        }
    }

    # 3. Firewall ingress (idempotent).
    if (-not (Get-NetFirewallRule -DisplayName $FirewallRule -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $FirewallRule -Direction Inbound `
            -Protocol TCP -LocalPort ($ListenPorts -join ',') -Action Allow | Out-Null
        Add-Content $Log "$(Get-Date -Format s) firewall rule created ($FirewallRule)"
    }

    exit 0
} catch {
    Add-Content $Log "$(Get-Date -Format s) FAILED: $_"
    exit 1
}
