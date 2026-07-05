$ErrorActionPreference = 'Stop'

winget install --id Tailscale.Tailscale --exact --accept-package-agreements --accept-source-agreements

Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'

Set-Service -Name 'sshd' -StartupType Automatic
Start-Service -Name 'sshd'

if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule `
        -Name 'OpenSSH-Server-In-TCP' `
        -DisplayName 'OpenSSH Server (TCP-In)' `
        -Direction Inbound `
        -Action Allow `
        -Protocol TCP `
        -LocalPort 22
}

$tailscale = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'

& $tailscale up
& $tailscale status
& $tailscale ip -4

Get-Service -Name 'sshd'
