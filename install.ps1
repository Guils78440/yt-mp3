# =====================================================================
#  YT MP3 - installation en une ligne (sans droits administrateur)
#
#  Dans PowerShell :
#     irm https://raw.githubusercontent.com/Guils78440/yt-mp3/main/install.ps1 | iex
#
#  Ce que fait ce script :
#   - copie YT MP3 dans %LOCALAPPDATA%\Programs\YT MP3 (ton compte uniquement)
#   - cree les raccourcis du menu Demarrer et du bureau
#   - ajoute YT MP3 dans "Applications installees" (pour le desinstaller)
#   - lance l'application
#  Les fichiers sont recuperes par PowerShell : Windows ne les marque pas comme
#  "telecharges d'Internet", donc aucune alerte SmartScreen.
#  (Fichier volontairement en ASCII pur : il est lu tel quel par "irm | iex".)
# =====================================================================
& {
    $ErrorActionPreference = 'Stop'
    $e = [char]0xE9; $ea = [char]0xE8; $a = [char]0xE0   # e accent aigu, e accent grave, a accent grave

    $Base = 'https://raw.githubusercontent.com/Guils78440/yt-mp3/main'
    if ($env:YTMP3_BASE) { $Base = $env:YTMP3_BASE.TrimEnd('/') }
    $Dir = Join-Path $env:LOCALAPPDATA 'Programs\YT MP3'
    $PS = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $Launch = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Dir\yt-mp3.ps1`""

    Write-Host ''
    Write-Host '  YT MP3 - installation' -ForegroundColor Magenta
    Write-Host "  Dossier : $Dir"
    Write-Host ''

    try {
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

        # 1. Arrete YT MP3 s'il est ouvert (mise a jour par-dessus une version existante)
        Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like '*\yt-mp3.ps1*' -and $_.ProcessId -ne $PID } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Milliseconds 500

        # 2. Recupere les fichiers de l'application
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        $wc = New-Object Net.WebClient
        $wc.Headers['Cache-Control'] = 'no-cache'
        foreach ($f in @('yt-mp3.ps1', 'app.ico', 'desinstaller.ps1')) {
            Write-Host "  T${e}l${e}chargement de $f..."
            $tmp = Join-Path $Dir "$f.tmp"
            $wc.DownloadFile("$Base/$($f)?t=" + [DateTime]::UtcNow.Ticks, $tmp)
            Move-Item -LiteralPath $tmp -Destination (Join-Path $Dir $f) -Force
        }
        $m = Select-String -LiteralPath (Join-Path $Dir 'yt-mp3.ps1') -Pattern "^\`$AppVersion = '([0-9.]+)'" | Select-Object -First 1
        if (-not $m) { throw "Le fichier yt-mp3.ps1 recu n'est pas valide." }
        $Ver = $m.Matches[0].Groups[1].Value
        Set-Content -LiteralPath (Join-Path $Dir 'installe.txt') -Value $Ver
        # Restes de l'ancien installateur .exe
        foreach ($old in @('YT MP3.exe', 'Desinstaller.exe')) { Remove-Item -LiteralPath (Join-Path $Dir $old) -Force -ErrorAction SilentlyContinue }

        # 3. Raccourcis menu Demarrer + bureau
        Write-Host "  Cr${e}ation des raccourcis..."
        $sh = New-Object -ComObject WScript.Shell
        foreach ($lnk in @((Join-Path ([Environment]::GetFolderPath('Programs')) 'YT MP3.lnk'),
                           (Join-Path ([Environment]::GetFolderPath('Desktop')) 'YT MP3.lnk'))) {
            $s = $sh.CreateShortcut($lnk)
            $s.TargetPath = $PS
            $s.Arguments = $Launch
            $s.IconLocation = "$Dir\app.ico,0"
            $s.WindowStyle = 7
            $s.WorkingDirectory = $env:USERPROFILE
            $s.Description = 'YT MP3 - convertisseur YouTube vers MP3'
            $s.Save()
        }

        # 4. Lien ytmp3:// (bouton "Relancer YT MP3" dans la fenetre)
        $k = 'HKCU:\Software\Classes\ytmp3'
        New-Item -Path "$k\shell\open\command" -Force | Out-Null
        New-Item -Path "$k\DefaultIcon" -Force | Out-Null
        Set-ItemProperty -Path $k -Name '(default)' -Value 'URL:YT MP3'
        Set-ItemProperty -Path $k -Name 'URL Protocol' -Value ''
        Set-ItemProperty -Path "$k\DefaultIcon" -Name '(default)' -Value "$Dir\app.ico"
        Set-ItemProperty -Path "$k\shell\open\command" -Name '(default)' -Value "`"$PS`" $Launch silencieux"

        # 5. Entree "Applications installees" de Windows
        $u = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\YTMP3'
        New-Item -Path $u -Force | Out-Null
        Set-ItemProperty -Path $u -Name DisplayName -Value 'YT MP3'
        Set-ItemProperty -Path $u -Name DisplayVersion -Value $Ver
        Set-ItemProperty -Path $u -Name Publisher -Value 'Guils78440'
        Set-ItemProperty -Path $u -Name DisplayIcon -Value "$Dir\app.ico"
        Set-ItemProperty -Path $u -Name InstallLocation -Value $Dir
        Set-ItemProperty -Path $u -Name URLInfoAbout -Value 'https://github.com/Guils78440/yt-mp3'
        Set-ItemProperty -Path $u -Name UninstallString -Value "`"$PS`" -NoProfile -ExecutionPolicy Bypass -File `"$Dir\desinstaller.ps1`""
        Set-ItemProperty -Path $u -Name NoModify -Value 1 -Type DWord
        Set-ItemProperty -Path $u -Name NoRepair -Value 1 -Type DWord
        Set-ItemProperty -Path $u -Name EstimatedSize -Value 300000 -Type DWord
        New-Item -Path 'HKCU:\Software\YT MP3' -Force | Out-Null
        Set-ItemProperty -Path 'HKCU:\Software\YT MP3' -Name InstallDir -Value $Dir

        Write-Host ''
        Write-Host "  YT MP3 v$Ver est install${e} !" -ForegroundColor Green
        Write-Host "  Il s'ouvre dans quelques secondes. Raccourcis : menu D${e}marrer et bureau."
        Write-Host ''

        # 6. Lancement
        Start-Process -FilePath $PS -ArgumentList $Launch -WindowStyle Hidden
    } catch {
        Write-Host ''
        Write-Host "  Installation impossible : $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  V${e}rifie ta connexion Internet puis relance la commande." -ForegroundColor Red
        Write-Host ''
    }
}
