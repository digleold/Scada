<#
.SYNOPSIS
  Installa su IIS la demo "Base Pizza SRL - Energy Monitor".

.DESCRIPTION
  Abilita i componenti IIS necessari, copia il sito, crea application pool e sito web,
  imposta i permessi e (a richiesta) apre la porta nel firewall e configura HTTPS.
  Si puo' rilanciare piu' volte: aggiorna il sito senza perdere logo e config.js personalizzati.

.EXAMPLE
  .\Install-BasePizzaEnergyMonitor.ps1
  Sito su http://localhost:8080/

.EXAMPLE
  .\Install-BasePizzaEnergyMonitor.ps1 -Port 80 -HostName energia.basepizza.local -OpenFirewall

.EXAMPLE
  .\Install-BasePizzaEnergyMonitor.ps1 -Port 80 -HttpsPort 443 -CertThumbprint 0123ABCD... -OpenFirewall
#>
#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$SiteName = 'BasePizza-EnergyMonitor',
    [int]$Port = 8080,
    [string]$HostName = '',
    [string]$InstallPath = 'C:\inetpub\BasePizza-EnergyMonitor',
    [switch]$OpenFirewall,
    [int]$HttpsPort = 0,
    [string]$CertThumbprint = ''
)

$ErrorActionPreference = 'Stop'
function Write-Step($text) { Write-Host ("==> " + $text) -ForegroundColor Cyan }

# 1. Controlli iniziali
$source = Join-Path $PSScriptRoot 'site'
if (-not (Test-Path (Join-Path $source 'index.html'))) {
    throw "Cartella 'site' non trovata accanto allo script: $source"
}
if ($HttpsPort -gt 0 -and [string]::IsNullOrWhiteSpace($CertThumbprint)) {
    throw "Per HTTPS indicare anche -CertThumbprint (identificazione personale del certificato)."
}

# 2. Componenti IIS
Write-Step 'Abilito i componenti IIS necessari'
if (Get-Command Install-WindowsFeature -ErrorAction SilentlyContinue) {
    foreach ($feature in 'Web-Server', 'Web-Static-Content', 'Web-Default-Doc', 'Web-Http-Errors', 'Web-Http-Logging', 'Web-Filtering', 'Web-Stat-Compression', 'Web-Mgmt-Console') {
        if (-not (Get-WindowsFeature -Name $feature).Installed) {
            Install-WindowsFeature -Name $feature | Out-Null
        }
    }
}
else {
    foreach ($feature in 'IIS-WebServerRole', 'IIS-WebServer', 'IIS-StaticContent', 'IIS-DefaultDocument', 'IIS-HttpErrors', 'IIS-HttpLogging', 'IIS-RequestFiltering', 'IIS-HttpCompressionStatic', 'IIS-ManagementConsole') {
        Enable-WindowsOptionalFeature -Online -FeatureName $feature -All -NoRestart | Out-Null
    }
}
Import-Module WebAdministration

# 3. Copia dei file (conservando logo e config.js gia' personalizzati)
Write-Step "Copio il sito in $InstallPath"
$keep = @{}
foreach ($name in 'config.js', 'logo.svg', 'logo.png') {
    $existing = Join-Path $InstallPath ('assets\' + $name)
    if (Test-Path $existing) { $keep[$name] = [System.IO.File]::ReadAllBytes($existing) }
}
New-Item -ItemType Directory -Force -Path $InstallPath | Out-Null
Copy-Item -Path (Join-Path $source '*') -Destination $InstallPath -Recurse -Force
foreach ($name in $keep.Keys) {
    [System.IO.File]::WriteAllBytes((Join-Path $InstallPath ('assets\' + $name)), $keep[$name])
    Write-Host ("    mantenuto assets\" + $name + " esistente")
}

# 4. Permessi di lettura
Write-Step 'Imposto i permessi di lettura'
& icacls.exe $InstallPath /grant 'IIS_IUSRS:(OI)(CI)RX' /T /C | Out-Null
& icacls.exe $InstallPath /grant 'IUSR:(OI)(CI)RX' /T /C | Out-Null

# 5. Application pool
$pool = "$SiteName-Pool"
Write-Step "Application pool $pool"
if (-not (Test-Path "IIS:\AppPools\$pool")) { New-WebAppPool -Name $pool | Out-Null }
Set-ItemProperty "IIS:\AppPools\$pool" -Name managedRuntimeVersion -Value ''

# 6. Sito web
Write-Step "Sito web $SiteName sulla porta $Port"
$bindingInfo = ('*:{0}:{1}' -f $Port, $HostName)
$conflict = Get-WebBinding | Where-Object {
    $_.protocol -eq 'http' -and $_.bindingInformation -eq $bindingInfo -and $_.ItemXPath -notlike ("*@name='" + $SiteName + "'*")
}
if ($conflict) {
    throw "La porta $Port e' gia' usata da un altro sito IIS. Rilanciare con -Port diverso (esempio -Port 8081) oppure -HostName."
}
if (Test-Path "IIS:\Sites\$SiteName") {
    Set-ItemProperty "IIS:\Sites\$SiteName" -Name physicalPath -Value $InstallPath
    Set-ItemProperty "IIS:\Sites\$SiteName" -Name applicationPool -Value $pool
    if (-not (Get-WebBinding -Name $SiteName -Protocol http | Where-Object { $_.bindingInformation -eq $bindingInfo })) {
        New-WebBinding -Name $SiteName -Protocol http -Port $Port -HostHeader $HostName
    }
}
else {
    New-Website -Name $SiteName -PhysicalPath $InstallPath -ApplicationPool $pool -Port $Port -HostHeader $HostName | Out-Null
}

# 7. HTTPS facoltativo
if ($HttpsPort -gt 0) {
    Write-Step "Configuro HTTPS sulla porta $HttpsPort"
    $cert = Get-Item ("Cert:\LocalMachine\My\" + $CertThumbprint) -ErrorAction Stop
    $sslFlags = 0
    if ($HostName) { $sslFlags = 1 }
    $httpsBinding = Get-WebBinding -Name $SiteName -Protocol https | Where-Object { $_.bindingInformation -eq ('*:{0}:{1}' -f $HttpsPort, $HostName) }
    if (-not $httpsBinding) {
        New-WebBinding -Name $SiteName -Protocol https -Port $HttpsPort -HostHeader $HostName -SslFlags $sslFlags
        $httpsBinding = Get-WebBinding -Name $SiteName -Protocol https | Where-Object { $_.bindingInformation -eq ('*:{0}:{1}' -f $HttpsPort, $HostName) }
    }
    $httpsBinding.AddSslCertificate($cert.Thumbprint, 'My')
}

# 8. Firewall facoltativo
if ($OpenFirewall) {
    Write-Step 'Apro le porte nel firewall di Windows'
    $ports = @($Port)
    if ($HttpsPort -gt 0) { $ports += $HttpsPort }
    foreach ($p in $ports) {
        $ruleName = "Base Pizza Energy Monitor (TCP $p)"
        if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol TCP -LocalPort $p -Action Allow | Out-Null
        }
    }
}

# 9. Avvio e prova
Write-Step 'Avvio il sito'
if ((Get-WebsiteState -Name $SiteName).Value -ne 'Started') { Start-Website -Name $SiteName }
if ([string]::IsNullOrWhiteSpace($HostName)) {
    try {
        $r = Invoke-WebRequest -Uri ("http://localhost:{0}/" -f $Port) -UseBasicParsing -TimeoutSec 15
        Write-Host ("    risposta HTTP " + $r.StatusCode) -ForegroundColor Green
    }
    catch {
        Write-Warning ("Prova su localhost non riuscita: " + $_.Exception.Message + " (vedere LEGGIMI.txt, sezione Problemi)")
    }
}

$address = $HostName
if ([string]::IsNullOrWhiteSpace($address)) { $address = $env:COMPUTERNAME }
Write-Host ''
Write-Host 'Installazione completata.' -ForegroundColor Green
Write-Host ("Indirizzo interno:   http://{0}:{1}/" -f $address, $Port)
if ($HttpsPort -gt 0) { Write-Host ("Indirizzo protetto:  https://{0}:{1}/" -f $address, $HttpsPort) }
Write-Host ("Personalizzazione:   " + (Join-Path $InstallPath 'assets\config.js'))
