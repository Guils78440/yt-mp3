# =====================================================================
#  YT MP3 - désinstallation
#  Lancé depuis Paramètres Windows > Applications installées > YT MP3 > Désinstaller.
#  Tes MP3 ne sont jamais supprimés.
# =====================================================================
Add-Type -AssemblyName System.Windows.Forms
$Dir = $PSScriptRoot
$rep = [System.Windows.Forms.MessageBox]::Show(
    "Désinstaller YT MP3 ?`n`nL'application, ses outils et sa bibliothèque seront retirés de ce PC.`nTes fichiers MP3 ne seront PAS supprimés.",
    'YT MP3', 'YesNo', 'Question')
if ($rep -ne 'Yes') { exit }

# Arrête YT MP3 s'il est ouvert
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*\yt-mp3.ps1*' -and $_.ProcessId -ne $PID } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 800

# Raccourcis et inscriptions dans Windows
foreach ($lnk in @((Join-Path ([Environment]::GetFolderPath('Programs')) 'YT MP3.lnk'),
                   (Join-Path ([Environment]::GetFolderPath('Desktop')) 'YT MP3.lnk'))) {
    Remove-Item -LiteralPath $lnk -Force -ErrorAction SilentlyContinue
}
foreach ($k in @('HKCU:\Software\Classes\ytmp3',
                 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\YTMP3',
                 'HKCU:\Software\YT MP3')) {
    Remove-Item -Path $k -Recurse -Force -ErrorAction SilentlyContinue
}

# Fichiers de l'application (les MP3 sont ailleurs : Musique\YT MP3 ou le dossier choisi)
Set-Location $env:TEMP
if ($Dir -and (Test-Path -LiteralPath (Join-Path $Dir 'yt-mp3.ps1'))) {
    Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue
}

[void][System.Windows.Forms.MessageBox]::Show(
    "YT MP3 a été désinstallé.`n`nTes MP3 n'ont pas été touchés (par défaut dans Musique\YT MP3).",
    'YT MP3', 'OK', 'Information')
