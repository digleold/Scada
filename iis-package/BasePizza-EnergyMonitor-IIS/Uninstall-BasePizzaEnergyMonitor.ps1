<#
.SYNOPSIS
  Rimuove da IIS la demo "Base Pizza SRL - Energy Monitor".
  Non disinstalla IIS e non tocca gli altri siti.

.EXAMPLE
  .\Uninstall-BasePizzaEnergyMonitor.ps1
  Rimuove sito, application pool e regole firewall, lasciando i file.

.EXAMPLE
  .\Uninstall-BasePizzaEnergyMonitor.ps1 -RemoveFiles
  Rimuove anche la cartella del sito.
#>
#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$SiteName = 'BasePizza-EnergyMonitor',
    [string]$InstallPath = 'C:\inetpub\BasePizza-EnergyMonitor',
    [switch]$RemoveFiles
)

$ErrorActionPreference = 'Stop'
Import-Module WebAdministration

if (Test-Path "IIS:\Sites\$SiteName") {
    Stop-Website -Name $SiteName -ErrorAction SilentlyContinue
    Remove-Website -Name $SiteName
    Write-Host "Sito $SiteName rimosso."
}
$pool = "$SiteName-Pool"
if (Test-Path "IIS:\AppPools\$pool") {
    Remove-WebAppPool -Name $pool
    Write-Host "Application pool $pool rimosso."
}
Get-NetFirewallRule -DisplayName 'Base Pizza Energy Monitor*' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
if ($RemoveFiles -and (Test-Path $InstallPath)) {
    Remove-Item -Path $InstallPath -Recurse -Force
    Write-Host "Cartella $InstallPath eliminata."
}
Write-Host 'Disinstallazione completata.' -ForegroundColor Green
