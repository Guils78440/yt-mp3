# =====================================================================
#  YT MP3 v2.6 - convertisseur YouTube vers MP3 (usage personnel)
#  Moteur : yt-dlp + ffmpeg + deno, installés automatiquement dans .\outils
# =====================================================================

$ErrorActionPreference = 'Stop'
$AppVersion = '2.6'   # à incrémenter à chaque évolution (voir CHANGELOG dans l'interface)
# Dossier de l'application : celui du script (version installée) ou celui du .bat (version portable)
$Root = $PSScriptRoot
if ($env:YTMP3_DIR) { $Root = $env:YTMP3_DIR.TrimEnd('\', '/') }
$Bin      = Join-Path $Root 'outils'
$Installed = Test-Path -LiteralPath (Join-Path $Root 'installe.txt')
# « silencieux » : relance demandée depuis la fenêtre déjà ouverte (lien ytmp3://), pas de nouvelle fenêtre
$Silent = @($args) -contains 'silencieux'
# Délai d'inactivité avant arrêt automatique (fenêtre fermée sans prévenir)
$IdleSeconds = 600
# Dépôt GitHub d'où viennent les mises à jour
$UpdateBase = 'https://raw.githubusercontent.com/Guils78440/yt-mp3/main'
if ($env:YTMP3_BASE) { $UpdateBase = $env:YTMP3_BASE.TrimEnd('/') }
# L'API GitHub donne toujours la dernière version déposée (raw.githubusercontent.com garde ~5 min de cache)
$UpdateApi = 'https://api.github.com/repos/Guils78440/yt-mp3/contents'
if ($env:YTMP3_BASE) { $UpdateApi = '' }
if ($env:YTMP3_API) { $UpdateApi = $env:YTMP3_API.TrimEnd('/') }
$SelfPath = $PSCommandPath   # vide en version portable (.bat)
if ($env:YTMP3_IDLE_SEC) { $IdleSeconds = [int]$env:YTMP3_IDLE_SEC }
# Version installée : les MP3 vont par défaut dans « Musique\YT MP3 »
$DefaultOut = Join-Path $Root 'MP3'
if ($Installed) {
    $music = [Environment]::GetFolderPath('MyMusic')
    if ($music) { $DefaultOut = Join-Path $music 'YT MP3' }
}
$Data     = Join-Path $Bin 'data'
$HistFile = Join-Path $Data 'historique.json'
$SettingsFile = Join-Path $Data 'parametres.json'
$VersionFile  = Join-Path $Data 'version.txt'
$Port     = 8765   # port préféré ; un autre est choisi s'il est occupé (voir « Instance unique »)
$Url      = "http://127.0.0.1:$Port/"
$YtDlp    = Join-Path $Bin 'yt-dlp.exe'
$Ffmpeg   = Join-Path $Bin 'ffmpeg.exe'
$Deno     = Join-Path $Bin 'deno.exe'
$PyDir    = Join-Path $Bin 'python'
$PyExe    = Join-Path $PyDir 'python.exe'
$SepMarker = Join-Path $PyDir 'demucs-ok.txt'
$SepStepFile = Join-Path $Bin 'data\separation-etape.txt'
$GpuMarker = Join-Path $PyDir 'gpu-ok.txt'     # PyTorch CUDA installé et carte NVIDIA reconnue
$TorchCuda = 'https://download.pytorch.org/whl/cu124'
# Carte NVIDIA présente ? (seules les cartes NVIDIA accélèrent Demucs de façon fiable)
$script:gpuName = ''
try {
    $script:gpuName = [string](@(Get-CimInstance Win32_VideoController -ErrorAction Stop | Where-Object { $_.Name -match 'NVIDIA' } | ForEach-Object { $_.Name }) | Select-Object -First 1)
} catch {}
if ($env:YTMP3_FAKE_GPU) { $script:gpuName = $env:YTMP3_FAKE_GPU }

foreach ($d in @($Bin, $Data)) {
    if (-not (Test-Path -LiteralPath $d)) { [void](New-Item -ItemType Directory -Path $d) }
}

# ---------- Paramètres ----------
# Sources de recherche (ordre d'affichage dans « Tout »)
$SourceNames = [ordered]@{ ytmusic = 'YouTube Music'; youtube = 'YouTube'; soundcloud = 'SoundCloud' }
$script:settings = [PSCustomObject]@{ outDir = $DefaultOut; cookies = 'aucun'; quality = 'auto'; normalize = $true; trim = $true; clean = $true; sources = @('ytmusic', 'youtube', 'soundcloud') }
if (Test-Path -LiteralPath $SettingsFile) {
    try {
        $s = Get-Content -LiteralPath $SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($s.outDir) { $script:settings.outDir = [string]$s.outDir }
        if ($s.cookies -eq 'firefox') { $script:settings.cookies = 'firefox' }
        if (@('auto', '192', '320') -contains [string]$s.quality) { $script:settings.quality = [string]$s.quality }
        if ($null -ne $s.normalize) { $script:settings.normalize = [bool]$s.normalize }
        if ($null -ne $s.trim) { $script:settings.trim = [bool]$s.trim }
        if ($null -ne $s.clean) { $script:settings.clean = [bool]$s.clean }
        if ($null -ne $s.sources) { $script:settings.sources = @(@($s.sources) | Where-Object { $SourceNames.Contains([string]$_) }) }
    } catch {}
}
function Save-Settings {
    ConvertTo-Json -InputObject $script:settings | Set-Content -LiteralPath $SettingsFile -Encoding UTF8
}
function Get-Out {
    $d = $script:settings.outDir
    if (-not $d) { $d = $DefaultOut }
    if (-not (Test-Path -LiteralPath $d)) { try { [void](New-Item -ItemType Directory -Path $d -Force) } catch {} }
    return $d
}
[void](Get-Out)
# yt-dlp trouve ffmpeg et deno (nécessaire pour YouTube) via le PATH
$env:PATH = "$Bin;$env:PATH"
$env:TORCH_HOME = Join-Path $Bin 'modeles'   # modèle de séparation rangé avec les outils

function Open-Window {
    if ($Silent) { return }
    try { Start-Process 'msedge.exe' -ArgumentList "--app=$Url", '--window-size=1000,800' -ErrorAction Stop }
    catch { try { Start-Process $Url } catch {} }
}

function Show-Error([string]$msg) {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show($msg, 'YT MP3', 'OK', 'Error')
    } catch { Write-Host $msg }
}

# ---------- Instance unique ----------
# Simple écoute TCP sur 127.0.0.1 : contrairement à HttpListener, aucun droit administrateur n'est nécessaire
# Pour chaque port de 8765 à 8780 : si YT MP3 y tourne déjà, on rouvre sa fenêtre ;
# s'il est libre, on le prend ; s'il est occupé par un autre programme, on passe au suivant.
$listener = $null
foreach ($p in 8765..8780) {
    $Url = "http://127.0.0.1:$p/"
    try {
        $r = Invoke-RestMethod -Uri ($Url + 'api/state') -TimeoutSec 2
        if ($r.appVersion) { Open-Window; exit }
    } catch {}
    try {
        $l = New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $p)
        $l.ExclusiveAddressUse = $true
        $l.Start()
        $listener = $l; $Port = $p
        break
    } catch {}
}
if (-not $listener) {
    Show-Error "Impossible de démarrer YT MP3 : aucun port libre entre 8765 et 8780.`n`nRedémarre le PC puis relance l'application."
    exit
}

# =====================================================================
#  Interface
# =====================================================================
$Html = @'
<!doctype html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>YT MP3</title>
<style>
:root{
  --bg:#0b0c10; --panel:#13151c; --panel2:#191c25; --line:#252935; --line2:#30354300;
  --text:#eceef4; --muted:#8a90a0; --faint:#5d6272;
  --a1:#ff3b6b; --a2:#8b5cf6; --ok:#34d399; --err:#f87171;
  --grad:linear-gradient(135deg,var(--a1),var(--a2));
  --r:14px;
}
*{box-sizing:border-box}
html,body{margin:0;height:100%}
body{
  background:
    radial-gradient(900px 420px at 15% -10%, #ff3b6b1c, transparent 60%),
    radial-gradient(800px 420px at 95% 0%, #8b5cf61f, transparent 60%),
    var(--bg);
  background-attachment:fixed;
  color:var(--text);
  font:15px/1.45 "Segoe UI Variable Text","Segoe UI",system-ui,sans-serif;
  -webkit-font-smoothing:antialiased;
}
button{font:inherit;color:inherit;cursor:pointer;border:0;background:none}
svg{width:18px;height:18px;flex:none}
main{max-width:880px;margin:0 auto;padding:26px 24px 60px}

/* ---- En-tête ---- */
header{display:flex;align-items:center;gap:14px;margin-bottom:22px}
.logo{width:42px;height:42px;border-radius:12px;background:var(--grad);display:grid;place-items:center;box-shadow:0 8px 24px #ff3b6b40}
.logo svg{width:22px;height:22px;color:#fff}
.brand h1{margin:0;font:600 20px/1.1 "Segoe UI Variable Display","Segoe UI",system-ui;letter-spacing:.2px}
.ver{font:500 11.5px "Segoe UI",system-ui;color:var(--muted);background:var(--panel2);border:1px solid var(--line);border-radius:6px;padding:2px 7px;vertical-align:3px;margin-left:4px;cursor:pointer}
.ver:hover{color:var(--text)}
.newver{font:600 11.5px "Segoe UI",system-ui;color:#fff;background:var(--grad);border-radius:6px;padding:3px 8px;vertical-align:3px;margin-left:6px;cursor:pointer;box-shadow:0 4px 14px #ff3b6b40}
.updst{display:flex;align-items:center;gap:10px;font-size:14px;margin-bottom:14px}
.box.dlg{text-align:left;width:min(460px,92vw)}
.dlg h3{margin:14px 0 4px}
.dlg-ic{width:44px;height:44px;border-radius:12px;background:var(--grad);display:grid;place-items:center;color:#fff;box-shadow:0 8px 24px #ff3b6b40}
.dlg-ic svg{width:22px;height:22px}
.dlg-notes{margin:14px 0 0;padding-left:20px;color:var(--text);font-size:14px;display:flex;flex-direction:column;gap:6px}
.dlg-notes:empty{display:none}
.dlg-btns{display:flex;justify-content:flex-end;align-items:center;gap:10px;margin-top:22px}
.box.dlg .dlg-btns .go{margin:0}
.box.dlg p{margin:0}
.updst .spin{width:18px;height:18px;border-width:2px;margin:0}
.log{list-style:none;margin:0;padding:0;display:flex;flex-direction:column;gap:14px}
.log li{display:flex;gap:14px}
.log .v{flex:none;width:52px;font-weight:600;font-size:13.5px}
.log .v small{display:block;font-weight:400;color:var(--faint);font-size:11.5px;margin-top:2px}
.log ul{margin:0;padding-left:18px;color:var(--muted);font-size:13.5px}
.log li.cur .v{color:var(--a1)}
.brand p{margin:3px 0 0;color:var(--muted);font-size:13px}
header .sp{flex:1}
.btn-ghost{display:flex;align-items:center;gap:8px;padding:9px 14px;border-radius:10px;background:var(--panel2);border:1px solid var(--line);font-size:14px;transition:.15s}
.btn-ghost:hover{border-color:#3a4050;background:#20232d}

/* ---- Zone de saisie ---- */
.hero{background:var(--panel);border:1px solid var(--line);border-radius:18px;padding:18px;position:relative;transition:.2s}
.hero.drag{border-color:var(--a1);box-shadow:0 0 0 4px #ff3b6b22}
.field{display:flex;align-items:center;gap:10px;background:var(--bg);border:1px solid var(--line);border-radius:12px;padding:0 6px 0 14px;transition:.15s}
.field:focus-within{border-color:#ff3b6b99;box-shadow:0 0 0 3px #ff3b6b1f}
.field svg{color:var(--faint)}
.field input{flex:1;min-width:0;background:none;border:0;outline:0;color:var(--text);font:inherit;font-size:15.5px;padding:15px 0}
.field input::placeholder{color:var(--faint)}
.paste{display:flex;align-items:center;gap:6px;padding:8px 12px;border-radius:9px;color:var(--muted);font-size:13.5px}
.paste:hover{background:var(--panel2);color:var(--text)}
.row{display:flex;align-items:center;gap:14px;margin-top:14px;flex-wrap:wrap}
.lbl{color:var(--muted);font-size:13px}
.seg{display:inline-flex;background:var(--bg);border:1px solid var(--line);border-radius:10px;padding:3px}
.seg button{padding:7px 14px;border-radius:7px;font-size:13.5px;color:var(--muted);transition:.15s}
.seg button.on{background:var(--panel2);color:var(--text);box-shadow:inset 0 0 0 1px var(--line)}
.seg small{opacity:.6;margin-left:4px;font-size:11.5px}
.row .sp{flex:1}
.auto-q{display:flex;align-items:center;gap:8px;color:var(--muted);font-size:13.5px}
.auto-q svg{color:var(--a1)}
.tag.src{color:var(--text);border-color:#3a4050}
.go{display:flex;align-items:center;gap:9px;padding:12px 22px;border-radius:11px;background:var(--grad);color:#fff;font-weight:600;font-size:15px;box-shadow:0 8px 22px #ff3b6b35;transition:.15s}
.go:hover{filter:brightness(1.08);transform:translateY(-1px)}
.go:disabled{opacity:.45;transform:none;cursor:default}
.hint{margin:12px 2px 0;color:var(--faint);font-size:12.5px}
.hint kbd{font:11.5px "Segoe UI",system-ui;background:var(--panel2);border:1px solid var(--line);border-radius:5px;padding:1px 6px;color:var(--muted)}

/* ---- Sections ---- */
section{margin-top:28px}
.sh{display:flex;align-items:center;gap:10px;margin:0 2px 12px}
.sh h2{margin:0;font-size:12px;font-weight:600;letter-spacing:1.2px;text-transform:uppercase;color:var(--muted)}
.sh .count{font-size:12px;color:var(--faint)}
.sh .sp{flex:1}
.search{display:flex;align-items:center;gap:8px;background:var(--panel);border:1px solid var(--line);border-radius:9px;padding:0 10px;width:230px}
.search svg{width:15px;height:15px;color:var(--faint)}
.search input{background:none;border:0;outline:0;color:var(--text);font:inherit;font-size:13.5px;padding:7px 0;width:100%}

/* ---- Cartes ---- */
.list{display:flex;flex-direction:column;gap:8px}
.item{display:flex;align-items:center;gap:14px;background:var(--panel);border:1px solid var(--line);border-radius:var(--r);padding:10px 12px 10px 10px;transition:.15s}
.lib .item:hover{background:#171a22;border-color:#2f3442}
.thumb{width:104px;height:58px;border-radius:9px;background:var(--panel2) center/cover no-repeat;flex:none;position:relative;overflow:hidden}
.thumb .ph{position:absolute;inset:0;display:grid;place-items:center;color:var(--faint)}
.thumb .dur{position:absolute;right:5px;bottom:5px;background:#000c;font-size:11px;padding:1px 5px;border-radius:4px}
.thumb .play{position:absolute;inset:0;display:grid;place-items:center;background:#0008;opacity:0;transition:.15s}
.thumb .play svg{width:24px;height:24px;color:#fff}
.lib .item:hover .play{opacity:1}
.meta{flex:1;min-width:0}
.t{font-weight:500;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.s{color:var(--muted);font-size:13px;margin-top:2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.s .dot{margin:0 6px;opacity:.5}
.tag{font-size:11px;padding:1px 6px;border-radius:5px;border:1px solid var(--line);color:var(--muted);margin-left:6px}
.bar{height:5px;background:var(--panel2);border-radius:5px;overflow:hidden;margin-top:9px}
.bar>i{display:block;height:100%;width:0;background:var(--grad);border-radius:5px;transition:width .4s}
.bar.ind>i{width:35%!important;animation:ind 1.1s ease-in-out infinite}
@keyframes ind{0%{transform:translateX(-100%)}100%{transform:translateX(300%)}}
.st{font-size:12.5px;color:var(--muted);white-space:nowrap}
.st.err{color:var(--err)}
.acts{display:flex;gap:2px}
.ib{width:34px;height:34px;border-radius:9px;display:grid;place-items:center;color:var(--muted);transition:.15s}
.ib:hover{background:var(--panel2);color:var(--text)}
.ib.del:hover{color:var(--err)}
.ib svg{width:17px;height:17px}
.missing .t{color:var(--faint);text-decoration:line-through}
.empty{text-align:center;padding:38px 20px;border:1px dashed var(--line);border-radius:var(--r);color:var(--faint)}
.empty svg{width:34px;height:34px;margin-bottom:8px;opacity:.6}

/* ---- Résultats de recherche ---- */
.res .item{padding-right:10px}
.add{display:flex;align-items:center;gap:6px;padding:8px 14px;border-radius:9px;background:var(--panel2);border:1px solid var(--line);font-size:13.5px;white-space:nowrap;transition:.15s}
.add:hover{border-color:var(--a1);color:#fff}
.add.done{color:var(--ok);border-color:#34d39955;cursor:default}
.add svg{width:15px;height:15px}
.sk{height:12px;border-radius:6px;background:linear-gradient(90deg,var(--panel2),#232733,var(--panel2));background-size:200% 100%;animation:sk 1.2s linear infinite}
@keyframes sk{to{background-position:-200% 0}}
.stabs{display:flex;gap:6px;flex-wrap:wrap;margin-bottom:4px}
.stabs button{display:flex;align-items:center;gap:7px;padding:7px 12px;border-radius:9px;background:var(--panel);border:1px solid var(--line);font-size:13px;color:var(--muted)}
.stabs button.on{color:var(--text);border-color:#3a4050;background:var(--panel2)}
.stabs small{color:var(--faint);font-size:11.5px}
.stabs i{width:8px;height:8px;border-radius:50%;display:inline-block}
.dot-ytmusic,.b-ytmusic{--c:#ff4d6d}.dot-youtube,.b-youtube{--c:#ff8a3d}.dot-soundcloud,.b-soundcloud{--c:#ff7700}
.dot-ytmusic{background:#ff4d6d}.dot-youtube{background:#e5e7eb}.dot-soundcloud{background:#ff7700}
.badge{font-size:10.5px;font-weight:600;letter-spacing:.3px;padding:1px 6px;border-radius:5px;margin-right:8px;border:1px solid}
.b-ytmusic{color:#ff6b86;border-color:#ff4d6d55;background:#ff4d6d14}
.b-youtube{color:#d1d5db;border-color:#4b5563;background:#ffffff08}
.b-soundcloud{color:#ff9a3d;border-color:#ff770055;background:#ff770014}
.mini-spin{width:11px;height:11px;border-radius:50%;border:2px solid var(--line);border-top-color:var(--a1);animation:sp .8s linear infinite;display:inline-block}
.more{align-self:center;margin-top:6px}

/* ---- Interrupteurs ---- */
.opt{display:flex;align-items:flex-start;gap:14px;padding:14px 0;border-top:1px solid var(--line);cursor:pointer}
.opt:first-of-type{border-top:0;padding-top:4px}
.opt .ot{flex:1}
.opt b{display:block;font-weight:600;font-size:14.5px}
.opt span{display:block;color:var(--muted);font-size:13px;margin-top:3px;max-width:600px}
.sw{flex:none;width:40px;height:23px;border-radius:12px;background:var(--panel2);border:1px solid var(--line);position:relative;transition:.2s;margin-top:2px}
.sw::after{content:"";position:absolute;top:2px;left:2px;width:17px;height:17px;border-radius:50%;background:var(--muted);transition:.2s}
.opt.on .sw{background:var(--grad);border-color:transparent}
.opt.on .sw::after{left:19px;background:#fff}

/* ---- Séparation ---- */
.stems{display:flex;gap:6px;margin-top:7px;flex-wrap:wrap}
.stem{display:flex;align-items:center;gap:6px;padding:4px 10px;border-radius:7px;background:var(--panel2);border:1px solid var(--line);font-size:12.5px;color:var(--text)}
.stem:hover{border-color:var(--a2)}
.stem svg{width:12px;height:12px}
.gpubox{margin-top:14px;padding:12px 14px;border:1px solid var(--line);border-radius:12px;font-size:13.5px;display:flex;flex-direction:column;gap:3px}
.gpubox span{color:var(--muted)}.gpubox.on{border-color:#34d39955}.gpubox.on b{color:var(--ok)}
.sepline{display:flex;align-items:center;gap:10px;margin-top:7px;font-size:12.5px;color:var(--muted)}
.sepline .bar{flex:1;margin:0;max-width:260px}
.sepline.err{color:var(--err)}
.sepst{display:flex;align-items:center;gap:12px;font-size:14px}
.sepst .spin{width:22px;height:22px;border-width:2px;margin:0}
.ok-txt{color:var(--ok)}

/* ---- Lecteur ---- */
body.has-player main{padding-bottom:130px}
body.has-player{--toast-b:112px}
.player{position:fixed;left:0;right:0;bottom:0;z-index:15;display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1.25fr) minmax(0,1fr);align-items:center;gap:18px;
  padding:12px 20px;background:#101218ee;backdrop-filter:blur(14px);border-top:1px solid var(--line)}
.player[hidden]{display:none}
.pl-left{display:flex;align-items:center;gap:12px;min-width:0}
.pl-cover{width:56px;height:56px;border-radius:10px;background:var(--panel2) center/cover no-repeat;flex:none;display:grid;place-items:center;color:var(--faint);box-shadow:0 6px 18px #0007}
.pl-meta{min-width:0}
.pl-meta .t{font-size:14.5px}
.pl-center{display:flex;flex-direction:column;align-items:center;gap:6px;min-width:0}
.pl-ctrl{display:flex;align-items:center;gap:6px}
.pl-ctrl .ib.on{color:var(--a1)}
.pl-ctrl .ib small{position:absolute;font-size:9px;font-weight:700;margin:12px 0 0 14px}
.pl-play{width:42px;height:42px;border-radius:50%;background:#fff;color:#0b0c10;display:grid;place-items:center;transition:.15s;margin:0 6px}
.pl-play:hover{transform:scale(1.06)}
.pl-play svg{width:20px;height:20px}
.pl-seek{display:flex;align-items:center;gap:10px;width:100%;font-size:11.5px;color:var(--muted);font-variant-numeric:tabular-nums}
.pl-seek input{flex:1}
.player input[type=range]{-webkit-appearance:none;appearance:none;height:4px;border-radius:4px;background:linear-gradient(90deg,var(--a1) var(--p,0%),#2b303c var(--p,0%));outline:0;cursor:pointer}
.player input[type=range]::-webkit-slider-thumb{-webkit-appearance:none;width:12px;height:12px;border-radius:50%;background:#fff;opacity:0;transition:.15s}
.player input[type=range]:hover::-webkit-slider-thumb{opacity:1}
.pl-right{display:flex;align-items:center;justify-content:flex-end;gap:8px;min-width:0}
.pl-right #plVol{width:90px}
.seg.mini{padding:2px}
.seg.mini button{padding:4px 9px;font-size:12px}
.seg.mini button:disabled{opacity:.3;cursor:default}
.ib.fade{width:auto;padding:0 10px;font-size:12px;gap:6px;display:flex;align-items:center}
.ib.fade.on{color:var(--a1);background:#ff3b6b14}
/* Titre en cours dans la bibliothèque */
.item.playing{border-color:#ff3b6b66;background:linear-gradient(90deg,#ff3b6b10,transparent 60%),var(--panel)}
.item.playing .t{color:#fff}
.eq{position:absolute;inset:0;display:flex;align-items:flex-end;justify-content:center;gap:3px;padding-bottom:16px;background:#0009}
.eq i{width:4px;background:var(--a1);border-radius:2px;animation:eq .9s ease-in-out infinite}
.eq i:nth-child(2){animation-delay:-.3s}.eq i:nth-child(3){animation-delay:-.6s}
.eq.paused i{animation-play-state:paused}
@keyframes eq{0%,100%{height:6px}50%{height:22px}}
@media (max-width:820px){.player{grid-template-columns:1fr auto;}.pl-right{display:none}}

/* ---- Mode DJ ---- */
body.dj-mode main{max-width:1240px}
body.dj-mode .player{display:none}
body.dj-mode main{padding-bottom:60px}
.dj{display:grid;grid-template-columns:1fr 1fr;gap:14px}
.deck{background:var(--panel);border:1px solid var(--line);border-radius:18px;padding:14px;display:flex;flex-direction:column;gap:10px;min-width:0;--dc:var(--a1)}
#deckB{--dc:var(--a2)}
.deck.on{border-color:color-mix(in srgb,var(--dc) 55%,transparent);box-shadow:0 0 0 1px color-mix(in srgb,var(--dc) 25%,transparent),0 10px 30px #0006}
.dk-head{display:flex;align-items:center;gap:12px;min-width:0}
.dk-cover{width:52px;height:52px;border-radius:10px;background:var(--panel2) center/cover no-repeat;flex:none;display:grid;place-items:center;color:var(--faint);position:relative}
.dk-letter{position:absolute;left:-6px;top:-6px;width:22px;height:22px;border-radius:7px;background:var(--dc);color:#fff;font-weight:700;font-size:12px;display:grid;place-items:center}
.dk-meta{flex:1;min-width:0}
.dk-bpm{text-align:right;line-height:1.1}
.dk-bpm b{display:block;font-size:20px;font-variant-numeric:tabular-nums}
.dk-bpm small{color:var(--muted);font-size:11px;letter-spacing:.8px}
.dk-wave{width:100%;height:74px;border-radius:10px;background:var(--bg);cursor:pointer;display:block}
.dk-time{display:flex;justify-content:space-between;font-size:12px;color:var(--muted);font-variant-numeric:tabular-nums;margin-top:-4px}
.dk-row{display:flex;align-items:center;gap:8px;flex-wrap:wrap}
.dk-btn{height:40px;min-width:54px;padding:0 12px;border-radius:11px;background:var(--panel2);border:1px solid var(--line);font-weight:700;font-size:13px;letter-spacing:.5px;display:grid;place-items:center}
.dk-btn:hover{border-color:#3a4050}
.dk-play{background:var(--dc);border-color:transparent;color:#fff;min-width:64px}
.dk-play svg{width:20px;height:20px}
.dk-cue{color:#fbbf24}
.dk-row .sp{flex:1}
.dk-grid{display:grid;grid-template-columns:72px 1fr 66px;align-items:center;gap:6px 10px;font-size:12.5px;color:var(--muted)}
.dk-grid output{font-variant-numeric:tabular-nums;text-align:right;color:var(--text);font-size:12px;white-space:nowrap}
.deck input[type=range],.xf input[type=range]{-webkit-appearance:none;appearance:none;height:4px;border-radius:4px;background:#2b303c;outline:0;cursor:pointer;width:100%}
.deck input[type=range]::-webkit-slider-thumb,.xf input[type=range]::-webkit-slider-thumb{-webkit-appearance:none;width:14px;height:14px;border-radius:50%;background:#fff;box-shadow:0 0 0 3px color-mix(in srgb,var(--dc,#fff) 45%,transparent)}
.dk-sync{height:28px;padding:0 8px;border-radius:8px;background:var(--panel2);border:1px solid var(--line);font-size:11.5px;font-weight:700;color:var(--text)}
.dk-sync:hover{border-color:var(--dc)}
.xfrow{display:flex;align-items:center;justify-content:center;gap:22px;margin:16px 0 4px;flex-wrap:wrap}
.xf{display:flex;align-items:center;gap:12px;background:var(--panel);border:1px solid var(--line);border-radius:14px;padding:12px 18px;width:min(460px,100%)}
.xf b{font-size:13px;width:22px;height:22px;border-radius:7px;display:grid;place-items:center;color:#fff;background:var(--a1)}
.xf b:last-child{background:var(--a2)}
.xf input[type=range]{height:8px;background:linear-gradient(90deg,var(--a1),#2b303c 50%,var(--a2))}
.mixctl{display:flex;align-items:center;gap:10px}
.mixctl .go.sm{box-shadow:none}
.djrow .acts{gap:6px}
.ab{width:36px;height:32px;border-radius:9px;font-weight:700;font-size:13px;border:1px solid var(--line);background:var(--panel2)}
.ab.a:hover{border-color:var(--a1);color:#ff8aa5}.ab.b:hover{border-color:var(--a2);color:#c4b5fd}
.ab.on{color:#fff;border-color:transparent}.ab.a.on{background:var(--a1)}.ab.b.on{background:var(--a2)}
.dk-bpm{min-width:64px}
.dk-beats{display:flex;gap:3px;justify-content:flex-end;margin-top:5px}
.dk-beats i{width:9px;height:5px;border-radius:2px;background:#2b303c;transition:background .08s}
.dk-beats i.on{background:color-mix(in srgb,var(--dc) 55%,#2b303c)}
.dk-beats i.hit{background:var(--dc);box-shadow:0 0 8px var(--dc)}
.dk-sync,.dk-pfl{min-width:0;padding:0 11px;font-size:12px;color:var(--muted)}
.dk-sync.on{color:#fff;background:#0ea5e9;border-color:transparent}
.dk-pfl svg{width:18px;height:18px}
.dk-pfl.on{color:#0b0c10;background:#fbbf24;border-color:transparent}
.dk-row2{gap:6px}
.dk-hots,.dk-loops{display:flex;gap:5px}
.dk-hot{width:34px;height:30px;border-radius:8px;border:1px solid var(--line);background:var(--panel2);font-weight:700;font-size:12.5px;color:var(--faint)}
.dk-hot.set{background:var(--hc);color:#0b0c10;border-color:transparent}
.dk-hot:hover{border-color:var(--hc)}
.dk-lbl{color:var(--faint);display:flex}.dk-lbl svg{width:16px;height:16px}
.dk-loop{width:34px;height:30px;border-radius:8px;border:1px solid var(--line);background:var(--panel2);font-weight:700;font-size:12.5px;color:var(--muted)}
.dk-loop.on{background:#22c55e;color:#0b0c10;border-color:transparent}
.recb{display:flex;align-items:center;gap:7px;font-size:13.5px}
.recb svg{width:15px;height:15px}
#recbtn svg{color:#f43f5e}
#recbtn.on{background:#f43f5e;color:#fff;border-color:transparent;font-variant-numeric:tabular-nums}
#recbtn.on svg{color:#fff;animation:blink 1s steps(2) infinite}
@keyframes blink{50%{opacity:.25}}
.keys .kgrid{display:grid;grid-template-columns:1fr 1fr;gap:8px 20px;margin-top:12px;font-size:13.5px;color:var(--muted)}
.keys .kgrid b{color:var(--text)}
kbd{font:600 11.5px "Segoe UI",system-ui;background:var(--panel2);border:1px solid var(--line);border-bottom-width:2px;border-radius:5px;padding:1px 6px;color:var(--text);margin-right:3px}
.plsample{margin:12px 0 0;padding:10px 12px;border:1px solid var(--line);border-radius:10px;font-size:13px;color:var(--muted);display:flex;flex-direction:column;gap:3px;max-height:140px;overflow:hidden}
.plsample i{font-style:normal;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.dlg-choice{display:flex;flex-direction:column;gap:10px;margin-top:18px}
.dlg-choice .go,.dlg-choice .btn-ghost{width:100%;justify-content:center;margin:0}
.chk{display:flex;align-items:center;gap:10px;margin-top:14px;font-size:14px;cursor:pointer}
.chk input{width:17px;height:17px;accent-color:#ff3b6b}
.chk span{flex:1}.chk small{display:block;color:var(--muted);font-size:12.5px;margin-top:2px}
.fwrow{display:flex;align-items:center;gap:10px;padding:11px 0;border-top:1px solid var(--line);font-size:14px}
.fwrow .ft{flex:1;min-width:0}.fwrow .ft b{display:block;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.fwrow .ft span{color:var(--muted);font-size:12.5px}
.box.dlg.wide{width:min(620px,94vw)}
.exlist{margin-top:12px;max-height:290px;overflow:auto;border:1px solid var(--line);border-radius:10px}
.exlist label{display:flex;align-items:center;gap:10px;padding:7px 12px;border-top:1px solid var(--line);font-size:13.5px;cursor:pointer}
.exlist label:first-child{border-top:0}
.exlist label span{flex:1;min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.exlist label em{font-style:normal;color:var(--muted);font-size:12px}
.exlist input{accent-color:#ff3b6b}
.expre{display:flex;gap:8px;flex-wrap:wrap;margin-top:12px}
.expre .btn-ghost{padding:6px 12px;font-size:13px}
.exsum{margin-top:10px;font-size:13px;color:var(--muted)}
.exdest{display:flex;gap:8px;margin-top:12px}
.exdest input{flex:1;min-width:0;background:var(--bg);color:var(--text);border:1px solid var(--line);border-radius:10px;padding:9px 10px;font:inherit;font-size:14px}
.usbb{display:inline-flex;align-items:center;gap:6px;margin-right:10px}
.usbb svg{width:16px;height:16px}
.outrow{display:flex;align-items:center;gap:12px;margin-top:10px}
.outrow span{width:84px;color:var(--muted);font-size:13.5px}
.outrow select{flex:1;max-width:460px;background:var(--bg);color:var(--text);border:1px solid var(--line);border-radius:10px;padding:9px 10px;font:inherit;font-size:14px}
.dk-key{font-size:11px;font-weight:700;color:var(--muted);margin-top:3px;letter-spacing:.3px}
.dk-key b{display:inline;font-size:11px;color:#fff;background:#334155;border-radius:4px;padding:0 5px;margin-right:4px}
.dk-key.ok b{background:#16a34a}
.djbottom{display:grid;grid-template-columns:minmax(300px,380px) 1fr;gap:18px;margin-top:26px;align-items:start}
.djbottom section{margin-top:0}
.setpanel{position:sticky;top:12px}
.setnow{font-size:12.5px;color:var(--muted);margin:-4px 2px 10px;min-height:1em}
.setnow b{color:var(--text);font-weight:600}
.setlist{gap:6px;max-height:62vh;overflow:auto;padding-right:2px}
.setitem{display:flex;align-items:center;gap:10px;background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:8px 8px 8px 6px;cursor:grab}
.setitem.drag{opacity:.4}
.setitem.over{border-color:var(--a1)}
.setitem.now{border-color:#22c55e;background:linear-gradient(90deg,#22c55e18,transparent 70%),var(--panel)}
.setitem.next{border-color:#38bdf8}
.setitem.done{opacity:.45}
.setitem .num{width:22px;text-align:center;color:var(--faint);font-size:12px;font-variant-numeric:tabular-nums}
.setitem .meta{min-width:0}
.setitem .t{font-size:13.5px}
.setitem .s{font-size:12px}
.setitem .ib{width:28px;height:28px}
.setitem .thumb{width:52px;height:34px;flex:none;border-radius:7px}
.setempty{border:1px dashed var(--line);border-radius:12px;padding:22px 16px;text-align:center;color:var(--faint);font-size:13px}
.ab.plus{font-size:16px;line-height:1}
.ab.plus.on{background:#22c55e;color:#0b0c10}
#autodj.on{background:#22c55e;color:#0b0c10;border-color:transparent}
.autodjb{width:100%;justify-content:center;margin-bottom:10px;padding:11px;font-weight:600}
#autodj svg{width:16px;height:16px}
.tag.key{color:#e2e8f0}
@media (max-width:980px){.djbottom{grid-template-columns:1fr}.setpanel{position:static}}
@media (max-width:900px){.dj{grid-template-columns:1fr}}

/* ---- Onglets & paramètres ---- */
.tabs{display:flex;background:var(--panel);border:1px solid var(--line);border-radius:11px;padding:3px;gap:2px}
.tabs button{display:flex;align-items:center;gap:7px;padding:7px 14px;border-radius:8px;font-size:14px;color:var(--muted);transition:.15s}
.tabs button svg{width:16px;height:16px}
.tabs button.on{background:var(--panel2);color:var(--text);box-shadow:inset 0 0 0 1px var(--line)}
.tabs button:hover{color:var(--text)}
.card{background:var(--panel);border:1px solid var(--line);border-radius:16px;padding:20px;margin-bottom:14px}
.card h3{margin:0 0 4px;font-size:16px;font-weight:600}
.card p{margin:0 0 14px;color:var(--muted);font-size:13.5px;max-width:640px}
.go.sm{padding:9px 18px;font-size:14px;box-shadow:none}
.lnk{color:var(--muted);font-size:13px;text-decoration:underline;text-underline-offset:3px}
.lnk:hover{color:var(--text)}
.st .lnk{color:var(--a1);margin-left:6px}
@media (max-width:760px){header{flex-wrap:wrap}}

/* ---- Installation ---- */
.overlay{position:fixed;inset:0;background:#0b0c10f0;backdrop-filter:blur(6px);display:none;place-items:center;z-index:10}
.overlay.show{display:grid}
.box{width:min(420px,90vw);text-align:center;padding:30px;background:var(--panel);border:1px solid var(--line);border-radius:18px}
.box h3{margin:16px 0 6px;font-size:18px}
.box p{margin:0;color:var(--muted);font-size:14px}
.spin{width:44px;height:44px;margin:0 auto;border-radius:50%;border:3px solid var(--line);border-top-color:var(--a1);animation:sp 0.9s linear infinite}
@keyframes sp{to{transform:rotate(360deg)}}
.box .bar{margin-top:18px}
.box .go{margin:18px auto 0}

/* ---- Notifications ---- */
.toasts{position:fixed;left:50%;bottom:var(--toast-b,22px);transform:translateX(-50%);display:flex;flex-direction:column;gap:8px;z-index:20}
.toast{background:var(--panel2);border:1px solid var(--line);padding:10px 16px;border-radius:10px;font-size:14px;box-shadow:0 10px 30px #0008;animation:tin .2s ease-out}
.toast.ok{border-color:#34d39955}.toast.err{border-color:#f8717166}
@keyframes tin{from{opacity:0;transform:translateY(8px)}}
@media (max-width:640px){.thumb{width:80px;height:45px}.search{width:150px}}
</style>
</head>
<body>
<main>
  <header>
    <div class="logo"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 18V5l12-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="18" cy="16" r="3"/></svg></div>
    <div class="brand"><h1>YT MP3 <span class="ver" id="appver"></span><span class="newver" id="newver" hidden></span></h1><p id="stats">Bibliothèque vide</p></div>
    <div class="sp"></div>
    <nav class="tabs">
      <button data-tab="main" class="on">Convertir</button>
      <button data-tab="dj"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="7" cy="12" r="4.5"/><circle cx="17" cy="12" r="4.5"/><circle cx="7" cy="12" r="1"/><circle cx="17" cy="12" r="1"/></svg>Mix</button>
      <button data-tab="set"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/></svg>Paramètres</button>
    </nav>
    <button class="btn-ghost" id="folder"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/></svg>Dossier MP3</button>
  </header>

  <div id="v-main">
  <div class="hero" id="hero">
    <form id="form">
      <div class="field">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10 13a5 5 0 0 0 7.5.5l3-3a5 5 0 0 0-7-7l-1.7 1.7"/><path d="M14 11a5 5 0 0 0-7.5-.5l-3 3a5 5 0 0 0 7 7l1.7-1.7"/></svg>
        <input id="url" placeholder="Colle un lien YouTube ou tape une recherche…" autocomplete="off" spellcheck="false">
        <button type="button" class="paste" id="paste"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="8" y="2" width="8" height="4" rx="1"/><path d="M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2"/></svg>Coller</button>
      </div>
      <div class="row">
        <span class="auto-q" id="qinfo"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M2 12h3l3-8 4 16 3-8h7"/></svg><span></span></span>
        <div class="sp"></div>
        <button class="go" id="go" type="submit"></button>
      </div>
    </form>
    <p class="hint">Astuce : <kbd>Ctrl</kbd> + <kbd>V</kbd> n'importe où, glisser-déposer un lien, plusieurs liens d'un coup, ou simplement « artiste titre » pour chercher sur YouTube Music, YouTube et SoundCloud.</p>
  </div>

  <section id="ssec" hidden>
    <div class="sh"><h2 id="stitle">Résultats</h2><div class="sp"></div><button class="ib" id="sclose" title="Fermer les résultats"></button></div>
    <div class="list" id="sres"></div>
  </section>

  <section id="qsec" hidden>
    <div class="sh"><h2>En cours</h2><span class="count" id="qcount"></span></div>
    <div class="list" id="queue"></div>
  </section>

  <section>
    <div class="sh">
      <h2>Bibliothèque</h2><span class="count" id="hcount"></span><div class="sp"></div>
      <button class="lnk usbb" id="usbbtn" title="Copier des titres sur une clé USB ou une carte SD"></button>
      <label class="search"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/></svg><input id="q" placeholder="Rechercher…"></label>
    </div>
    <div class="list lib" id="lib"></div>
  </section>
  </div>

  <div id="v-dj" hidden>
    <div class="dj">
      <div class="deck" id="deckA"></div>
      <div class="deck" id="deckB"></div>
    </div>
    <div class="xfrow">
      <div class="xf"><b>A</b><input type="range" id="xf" min="0" max="1000" value="500" title="Crossfader (double-clic : centre)"><b>B</b></div>
      <div class="mixctl">
        <button class="go sm" id="automix" title="Espace"></button>
        <div class="seg mini" id="mixlen" title="Durée de l'enchaînement">
          <button type="button" data-l="4">4 s</button><button type="button" data-l="8">8 s</button><button type="button" data-l="16">16 s</button>
        </div>
        <button class="btn-ghost recb" id="recbtn"></button>
        <button class="btn-ghost recb" id="keysbtn" title="Raccourcis clavier"></button>
      </div>
    </div>
    <div class="djbottom">
      <section class="setpanel">
        <div class="sh"><h2>Liste de soirée</h2><span class="count" id="setcount"></span><div class="sp"></div>
          <button class="lnk" id="setsort" title="Trie par tempo croissant pour faire monter l'énergie">Trier par BPM</button>
          <button class="lnk" id="setclear">Vider</button></div>
        <button class="btn-ghost recb autodjb" id="autodj" title="Auto-DJ : enchaîne tout seul la liste de soirée (puis des morceaux compatibles)"></button>
        <div class="setnow" id="setnow"></div>
        <div class="list setlist" id="setlist"></div>
      </section>
      <section class="djlibpanel">
        <div class="sh"><h2>Bibliothèque</h2><span class="count" id="anacount"></span><div class="sp"></div>
          <label class="search"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/></svg><input id="djq" placeholder="Rechercher…"></label></div>
        <div class="list" id="djlib"></div>
      </section>
    </div>
  </div>

  <div id="v-set" hidden>
    <div class="card">
      <h3>Dossier de téléchargement</h3>
      <p>Tous les nouveaux MP3 seront enregistrés ici. Les fichiers déjà téléchargés restent où ils sont.</p>
      <div class="field">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/></svg>
        <input id="dir" spellcheck="false" placeholder="D:\Musique">
        <button type="button" class="paste" id="pick">Parcourir…</button>
      </div>
      <div class="row">
        <button class="go sm" id="saveDir">Enregistrer</button>
        <button class="btn-ghost" id="openDir">Ouvrir le dossier</button>
        <div class="sp"></div>
        <button class="lnk" id="resetDir">Revenir au dossier par défaut</button>
      </div>
    </div>

    <div class="card">
      <h3>Qualité de sortie</h3>
      <p>En automatique, YT MP3 analyse la piste audio de chaque vidéo et choisit le débit MP3 le plus bas qui conserve toute sa qualité. Un débit plus élevé grossirait le fichier sans rien apporter à l'écoute.</p>
      <div class="seg" id="qmode">
        <button type="button" data-m="auto">Automatique (recommandé)</button>
        <button type="button" data-m="192">Toujours 192 kbps</button>
        <button type="button" data-m="320">Toujours 320 kbps</button>
      </div>
    </div>

    <div class="card">
      <h3>Traitement automatique</h3>
      <p>Appliqué à chaque nouveau téléchargement.</p>
      <div class="opt" data-opt="trim"><div class="ot"><b>Ne garder que la musique</b><span>Retire les passages non musicaux des clips (intro parlée, scènes, générique) repérés par la communauté SponsorBlock, ainsi que les silences en début et en fin de morceau.</span></div><div class="sw"></div></div>
      <div class="opt" data-opt="normalize"><div class="ot"><b>Volume homogène</b><span>Ramène chaque morceau au même niveau sonore (-14 LUFS, la référence de Spotify et YouTube) : plus besoin de toucher au volume entre deux titres.</span></div><div class="sw"></div></div>
      <div class="opt" data-opt="clean"><div class="ot"><b>Noms et pochettes propres</b><span>Sépare l'artiste et le titre, retire « Clip Officiel », « HD », « Lyrics »… du nom et des tags, et recadre la pochette en carré pour le téléphone et l'autoradio.</span></div><div class="sw"></div></div>
    </div>

    <div class="card" id="djcard">
      <h3>Sorties audio</h3>
      <p>Choisis où part le son de chaque partie de YT MP3. Une enceinte Bluetooth appairée à Windows (Echo Dot, JBL…) apparaît ici comme n'importe quelle sortie. En mode DJ, le bouton casque d'une platine te fait entendre le morceau suivant dans le casque pendant que la salle écoute l'autre.</p>
      <div class="outrow"><span>Lecteur</span><select id="outPlayer"></select></div>
      <div class="outrow"><span>Mix salle</span><select id="outMain"></select></div>
      <div class="outrow"><span>Mix casque</span><select id="outCue"></select></div>
      <div class="row" style="margin-top:12px"><button class="btn-ghost" id="outNames">Afficher les noms</button><span class="lbl" id="outHint"></span></div>
      <p style="margin:12px 0 0;font-size:12.5px">Windows ne donne le nom des sorties audio qu'après une autorisation d'accès au micro : il n'est jamais utilisé ni enregistré.</p>
    </div>

    <div class="card" id="plcard">
      <h3>Playlists suivies</h3>
      <p>Les nouveaux titres ajoutés à ces playlists YouTube sont téléchargés automatiquement, au démarrage puis toutes les 6 heures. Pour suivre une playlist, colle son lien dans l'onglet Convertir.</p>
      <div id="plbox"></div>
    </div>

    <div class="card" id="sepcard">
      <h3>Séparation voix / instrumental</h3>
      <p>Module optionnel basé sur Demucs (Meta) : à partir d'un MP3 de la bibliothèque, crée un fichier avec uniquement les voix et un autre avec uniquement l'instrumental. Installation unique d'environ 1,2 Go ; ensuite, compte 1 à 3 minutes par morceau selon ton processeur.</p>
      <div id="sepbox"></div>
    </div>

    <div class="card">
      <h3>Sources de recherche</h3>
      <p>Quand tu tapes une recherche, YT MP3 interroge en même temps toutes les sources activées. Un même morceau trouvé sur YouTube Music et YouTube n'apparaît qu'une fois.</p>
      <div class="opt" data-src="ytmusic"><div class="ot"><b>YouTube Music</b><span>Uniquement des morceaux officiels (pas de clips, lives ou réactions), avec artiste et titre propres. Idéal pour retrouver un titre précis.</span></div><div class="sw"></div></div>
      <div class="opt" data-src="youtube"><div class="ot"><b>YouTube</b><span>Le plus large : clips, lives, remixes, mixtapes, freestyles.</span></div><div class="sw"></div></div>
      <div class="opt" data-src="soundcloud"><div class="ot"><b>SoundCloud</b><span>Remixes, DJ sets et artistes indépendants qu'on ne trouve pas sur YouTube.</span></div><div class="sw"></div></div>
    </div>

    <div class="card">
      <h3>Connexion YouTube</h3>
      <p>Si YouTube bloque les téléchargements (erreur 403), YT MP3 peut emprunter ta session Firefox : YouTube te reconnaît alors comme un visiteur normal. Il suffit d'avoir ouvert YouTube au moins une fois dans Firefox.</p>
      <div class="seg" id="ck">
        <button type="button" data-c="aucun">Désactivée</button>
        <button type="button" data-c="firefox">Utiliser Firefox</button>
      </div>
    </div>

    <div class="card" id="updcard">
      <h3>Mises à jour de YT MP3</h3>
      <p>YT MP3 vérifie à chaque démarrage si une nouvelle version est disponible sur GitHub. La mise à jour s'installe en quelques secondes, sans aucune alerte Windows, et l'application redémarre toute seule. Ta bibliothèque et tes réglages sont conservés.</p>
      <div id="updbox"></div>
    </div>

    <div class="card">
      <h3>Moteur de conversion</h3>
      <p id="ver">yt-dlp, mis à jour automatiquement à chaque lancement.</p>
      <div class="row" style="margin-top:12px"><button class="btn-ghost" data-act="setup">Mettre à jour maintenant</button></div>
    </div>

    <div class="card" id="about">
      <h3>Versions</h3>
      <p id="aboutTxt"></p>
      <ul class="log" id="log"></ul>
    </div>
  </div>
</main>

<div class="overlay" id="ov"><div class="box" id="ovbox"></div></div>
<div class="overlay" id="keyhelp"><div class="box dlg keys">
  <h3>Raccourcis clavier de l'onglet Mix</h3>
  <div class="kgrid">
    <b>Platine A</b><b>Platine B</b>
    <span><kbd>A</kbd> lecture / pause</span><span><kbd>P</kbd> lecture / pause</span>
    <span><kbd>Z</kbd> CUE</span><span><kbd>O</kbd> CUE</span>
    <span><kbd>E</kbd> SYNC</span><span><kbd>I</kbd> SYNC</span>
    <span><kbd>1</kbd><kbd>2</kbd><kbd>3</kbd><kbd>4</kbd> hot cues</span><span><kbd>7</kbd><kbd>8</kbd><kbd>9</kbd><kbd>0</kbd> hot cues</span>
  </div>
  <p style="margin-top:14px"><kbd>Espace</kbd> enchaîner vers l'autre platine · <kbd>←</kbd> <kbd>→</kbd> crossfader · <kbd>Maj</kbd> + chiffre : effacer un hot cue (ou clic droit sur le repère)</p>
  <div class="dlg-btns"><button class="go kclose">OK</button></div>
</div></div>
<div class="overlay" id="pldlg"><div class="box dlg" id="plbox2"></div></div>
<div class="overlay" id="expdlg"><div class="box dlg wide">
  <h3 style="margin-top:0">Copier sur une clé USB</h3>
  <p>Coche les titres à copier. L'ordre de la copie est celui de la liste : pratique pour un autoradio qui lit les fichiers dans l'ordre.</p>
  <div class="expre"><button class="btn-ghost" data-ex="all">Tout</button><button class="btn-ghost" data-ex="set">Liste de soirée</button><button class="btn-ghost" data-ex="none">Aucun</button></div>
  <div class="exlist" id="exlist"></div>
  <div class="exsum" id="exsum"></div>
  <label class="chk"><input type="checkbox" id="exnum" checked><span>Numéroter les fichiers<small>(01 - …, 02 - … : garde l'ordre sur tous les lecteurs)</small></span></label>
  <label class="chk"><input type="checkbox" id="exascii"><span>Noms sans accents<small>(pour les vieux autoradios)</small></span></label>
  <div class="exdest"><input id="exdir" spellcheck="false" placeholder="Ex. E:\"><button class="btn-ghost" id="expick">Choisir…</button></div>
  <div id="exprog"></div>
  <div class="dlg-btns"><button class="btn-ghost" id="exclose">Fermer</button><button class="go" id="exgo">Copier</button></div>
</div></div>
<div class="overlay" id="upddlg"><div class="box dlg">
  <div class="dlg-ic"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3v12"/><path d="m7 10 5 5 5-5"/><path d="M5 21h14"/></svg></div>
  <h3 id="dlgTitle"></h3>
  <p id="dlgSub"></p>
  <ul class="dlg-notes" id="dlgNotes"></ul>
  <div class="dlg-btns"><button class="btn-ghost" id="dlgLater">Plus tard</button><button class="go" id="dlgGo"></button></div>
</div></div>
<div class="overlay" id="down"><div class="box">
  <div class="spin"></div>
  <h3>YT MP3 s'est arrêté</h3>
  <p id="downMsg">Le moteur de l'application ne répond plus (par exemple après une mise en veille du PC). Tes fichiers et ta bibliothèque ne sont pas touchés.</p>
  <button class="go" id="relaunch">Relancer YT MP3</button>
  <p style="margin-top:12px;font-size:12.5px">Tu peux aussi fermer cette fenêtre et relancer YT MP3 depuis le bureau.</p>
</div></div>
<div class="player" id="player" hidden>
  <div class="pl-left">
    <div class="pl-cover" id="plCover"></div>
    <div class="pl-meta"><div class="t" id="plTitle"></div><div class="s" id="plSub"></div></div>
  </div>
  <div class="pl-center">
    <div class="pl-ctrl">
      <button class="ib" id="plShuffle" title="Lecture aléatoire"></button>
      <button class="ib" id="plPrev" title="Précédent"></button>
      <button class="pl-play" id="plPlay" title="Lecture / pause (Espace)"></button>
      <button class="ib" id="plNext" title="Suivant"></button>
      <button class="ib" id="plRepeat" title="Répéter"></button>
    </div>
    <div class="pl-seek"><span id="plCur">0:00</span><input type="range" id="plSeek" min="0" max="1000" value="0"><span id="plDur">0:00</span></div>
  </div>
  <div class="pl-right">
    <div class="seg mini" id="plStem" title="Piste">
      <button type="button" data-s="orig">Original</button><button type="button" data-s="voix">Voix</button><button type="button" data-s="instru">Instru</button>
    </div>
    <button class="ib fade" id="plFade" title="Fondu enchaîné de 6 secondes entre les morceaux"></button>
    <button class="ib" id="plMute" title="Couper le son"></button>
    <input type="range" id="plVol" min="0" max="100" value="80">
  </div>
</div>

<div class="toasts" id="toasts"></div>

<script>
const $ = s => document.querySelector(s);
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const I = {
  x:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M18 6 6 18M6 6l12 12"/></svg>',
  retry:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 12a9 9 0 1 0 3-6.7L3 8"/><path d="M3 3v5h5"/></svg>',
  play:'<svg viewBox="0 0 24 24" fill="currentColor"><path d="M8 5.5v13a1 1 0 0 0 1.5.86l10.5-6.5a1 1 0 0 0 0-1.72L9.5 4.64A1 1 0 0 0 8 5.5z"/></svg>',
  reveal:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/></svg>',
  trash:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 6h18M8 6V4h8v2M6 6l1 14h10l1-14"/></svg>',
  cut:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="6" cy="6" r="3"/><circle cx="6" cy="18" r="3"/><path d="M20 4 8.12 15.88M14.47 14.48 20 20M8.12 8.12 12 12"/></svg>',
  usb:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 2h6v6H9z"/><path d="M7 8h10v9a5 5 0 0 1-10 0z"/><path d="M12 17v5"/></svg>',
  split:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3v18"/><path d="M8 7v10M4 10v4M16 7v10M20 10v4"/></svg>',
  pause:'<svg viewBox="0 0 24 24" fill="currentColor"><rect x="6" y="4.5" width="4" height="15" rx="1.2"/><rect x="14" y="4.5" width="4" height="15" rx="1.2"/></svg>',
  prev:'<svg viewBox="0 0 24 24" fill="currentColor"><path d="M7 5.5v13M18.5 6.3v11.4a.8.8 0 0 1-1.2.7L9 12.7a.8.8 0 0 1 0-1.4l8.3-5.7a.8.8 0 0 1 1.2.7z"/><rect x="5" y="5" width="2.4" height="14" rx="1"/></svg>',
  next:'<svg viewBox="0 0 24 24" fill="currentColor"><path d="M5.5 6.3v11.4a.8.8 0 0 0 1.2.7l8.3-5.7a.8.8 0 0 0 0-1.4L6.7 5.6a.8.8 0 0 0-1.2.7z"/><rect x="16.6" y="5" width="2.4" height="14" rx="1"/></svg>',
  shuffle:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M16 3h5v5M4 20 21 3M21 16v5h-5M15 15l6 6M4 4l5 5"/></svg>',
  repeat:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m17 2 4 4-4 4"/><path d="M3 11v-1a4 4 0 0 1 4-4h14"/><path d="m7 22-4-4 4-4"/><path d="M21 13v1a4 4 0 0 1-4 4H3"/></svg>',
  vol:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M11 5 6 9H2v6h4l5 4z"/><path d="M15.5 8.5a5 5 0 0 1 0 7M19 5a10 10 0 0 1 0 14"/></svg>',
  mute:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M11 5 6 9H2v6h4l5 4z"/><path d="m22 9-6 6M16 9l6 6"/></svg>',
  fade:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M2 18C8 18 10 6 16 6M8 18c6 0 8-12 14-12" opacity=".9"/></svg>',
  note:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 18V5l12-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="18" cy="16" r="3"/></svg>'
};

let state = null, libKey = '', filter = '';

function ytId(u){ const m = String(u).match(/(?:v=|youtu\.be\/|shorts\/|embed\/|live\/)([\w-]{11})/); return m ? m[1] : ''; }
// Image d'un titre : miniature YouTube si c'est une vidéo YouTube, sinon l'image fournie par la source (SoundCloud…)
function coverUrl(id, img, big){
  if (img && !/ytimg\.com|youtube\.com/.test(img)) return img;
  if (id && /^[\w-]{11}$/.test(id)) return `https://i.ytimg.com/vi/${id}/${big ? 'hqdefault' : 'mqdefault'}.jpg`;
  return img || '';
}
function thumb(id, dur, play, img){
  const u = coverUrl(id, img);
  const bg = u ? `style="background-image:url('${u.replace(/'/g, '%27')}')"` : '';
  return `<div class="thumb" ${bg}>${u ? '' : `<div class="ph">${I.note}</div>`}${dur ? `<span class="dur">${esc(dur)}</span>` : ''}${play ? `<div class="play">${I.play}</div>` : ''}</div>`;
}
/* Étiquette qualité : « Opus 141 → MP3 192 kbps » quand la source est connue */
function qtag(x){
  if (x.auto && !x.analysed) return '';
  const src = x.srcAbr ? `${x.srcCodec ? x.srcCodec + ' ' : ''}${x.srcAbr} → ` : '';
  const title = x.srcAbr ? `Source ${x.srcCodec || ''} ${x.srcAbr} kbps : un MP3 ${x.quality} kbps en conserve toute la qualité` : '';
  const done = [x.trimmed && 'musique seule (intros et silences retirés)', x.normalized && 'volume normalisé à -14 LUFS'].filter(Boolean);
  const vol = done.length ? `<span class="tag" title="${esc('Optimisé : ' + done.join(', '))}">Optimisé</span>` : '';
  const only = '';
  return `<span class="tag ${src ? 'src' : ''}" title="${esc(title)}">${src}MP3 ${x.quality} kbps</span>${vol}${only}`;
}
function sepHtml(x){
  const sp = x.sep;
  if (sp){
    if (sp.status === 'erreur') return `<div class="sepline err">Séparation impossible : ${esc(sp.error)} <button class="lnk" data-act="sepcancel" data-id="${x.id}">Fermer</button></div>`;
    const txt = sp.status === 'attente' ? 'Séparation en attente' : sp.status === 'encodage' ? 'Création des MP3…' : `Séparation des voix… ${sp.progress} %`;
    const ind = sp.status !== 'separation' || !sp.progress;
    return `<div class="sepline">${txt}<div class="bar ${ind ? 'ind' : ''}"><i style="width:${sp.progress}%"></i></div><button class="lnk" data-act="sepcancel" data-id="${x.id}">Annuler</button></div>`;
  }
  if (x.voix || x.instru) return `<div class="stems">
    ${x.voix ? `<button class="stem" data-act="playstem" data-stem="voix" data-id="${x.id}">${I.play}Voix</button>` : ''}
    ${x.instru ? `<button class="stem" data-act="playstem" data-stem="instru" data-id="${x.id}">${I.play}Instrumental</button>` : ''}</div>`;
  return '';
}
function mb(b){ return (b/1048576).toFixed(1).replace('.', ',') + ' Mo'; }
function toast(msg, cls=''){
  const t = document.createElement('div'); t.className = 'toast ' + cls; t.textContent = msg;
  $('#toasts').appendChild(t); setTimeout(() => t.remove(), 3500);
}
async function api(path, body){
  let r;
  try { r = await fetch(path, body === undefined ? {} : {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(body)}); }
  catch { setDown(true); throw new Error('YT MP3 ne répond plus'); }
  if (!r.ok) throw new Error('Erreur ' + r.status);
  return r.json();
}


/* --- Ajout --- */
function extract(text){ return [...new Set((String(text).match(/https?:\/\/[^\s"'<>]+/g) || []))]; }
async function add(text){
  const urls = extract(text);
  if (!urls.length){
    if (String(text).trim()) return search(text);
    toast('Colle un lien ou tape une recherche', 'err'); return;
  }
  if (urls.length === 1 && /youtu.*[?&]list=[\w-]+/.test(urls[0])) {
    $('#url').value = ''; plOpen = true; plKey = '';
    try { render(await api('/api/plinfo', {url: urls[0]})); } catch(e){ toast(e.message, 'err'); }
    return;
  }
  try {
    render(await api('/api/add', {urls}));
    $('#url').value = '';
    toast(urls.length > 1 ? `${urls.length} liens ajoutés` : 'Ajouté à la file');
  } catch(e){ toast(e.message, 'err'); }
}
$('#form').onsubmit = e => { e.preventDefault(); add($('#url').value); };

/* --- Recherche --- */
const GO_DL = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3v12"/><path d="m7 10 5 5 5-5"/><path d="M5 21h14"/></svg>Convertir';
const GO_SEARCH = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"><circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/></svg>Rechercher';
function updateGo(){ const v = $('#url').value; $('#go').innerHTML = (!v.trim() || extract(v).length) ? GO_DL : GO_SEARCH; }
$('#url').addEventListener('input', updateGo); updateGo();
const added = new Set();
let searchKey = '';
async function search(q){
  try { render(await api('/api/search', {q})); } catch(e){ toast(e.message, 'err'); }
}
$('#sclose').innerHTML = I.x;
$('#sclose').onclick = () => { search(''); };
const SRC = { ytmusic: 'YouTube Music', youtube: 'YouTube', soundcloud: 'SoundCloud' };
let srcTab = 'all';
$('#sres').addEventListener('click', async e => {
  const t = e.target.closest('[data-tab-src]');
  if (t) { srcTab = t.dataset.tabSrc; searchKey = ''; renderSearch(state.search); return; }
  if (e.target.closest('#smore')) { try { render(await api('/api/search', {q: state.search.q, more: true})); } catch(err){ toast(err.message, 'err'); } return; }
  const b = e.target.closest('[data-add]'); if (!b || b.classList.contains('done')) return;
  const u = b.dataset.add;
  try { render(await api('/api/add', {urls:[u]})); added.add(u); searchKey = ''; render(state); toast('Ajouté à la file'); }
  catch(err){ toast(err.message, 'err'); }
});
function renderSearch(sr){
  const key = JSON.stringify(sr) + [...added].join();
  if (key === searchKey) return;
  searchKey = key;
  const on = sr && sr.status !== 'vide';
  $('#ssec').hidden = !on;
  if (!on) return;
  $('#stitle').textContent = `Résultats pour « ${sr.q} »`;
  const box = $('#sres'); box.classList.add('res');
  const res = sr.results || [], st = sr.sources || {};
  const srcs = Object.keys(SRC).filter(k => st[k]);
  if (srcTab !== 'all' && !srcs.includes(srcTab)) srcTab = 'all';
  const count = k => res.filter(r => r.src === k).length;
  const uniq = res.filter(r => !r.dup);
  const spin = k => st[k] === 'recherche' ? '<span class="mini-spin"></span>' : '';
  const tabs = srcs.length > 1 ? `<div class="stabs">
      <button data-tab-src="all" class="${srcTab === 'all' ? 'on' : ''}">Tout <small>${uniq.length}</small></button>
      ${srcs.map(k => `<button data-tab-src="${k}" class="${srcTab === k ? 'on' : ''}"><i class="dot-${k}"></i>${SRC[k]} ${st[k] === 'recherche' ? spin(k) : `<small>${st[k] === 'erreur' ? '!' : count(k)}</small>`}</button>`).join('')}
    </div>` : '';
  const shown = srcTab === 'all' ? uniq : res.filter(r => r.src === srcTab);
  const skel = Array.from({length: 3}, () => `<div class="item"><div class="thumb"></div><div class="meta"><div class="sk" style="width:60%"></div><div class="sk" style="width:30%;margin-top:10px"></div></div></div>`).join('');
  let body;
  if (shown.length) {
    body = shown.map(r => `<div class="item">${thumb(r.src === 'soundcloud' ? '' : r.id, r.duration, false, r.thumb)}
      <div class="meta"><div class="t" title="${esc(r.title)}">${esc(r.title)}</div><div class="s"><span class="badge b-${r.src}">${SRC[r.src]}</span>${esc(r.channel)}</div></div>
      <button class="add ${added.has(r.url) ? 'done' : ''}" data-add="${esc(r.url)}">${added.has(r.url) ? '✓ Ajouté' : GO_DL}</button></div>`).join('');
    if (sr.status === 'recherche' && srcTab === 'all') body += skel;
  } else if (sr.status === 'recherche' || st[srcTab] === 'recherche') body = skel;
  else body = `<div class="empty">${st[srcTab] === 'erreur' || sr.status === 'erreur' ? 'La recherche a échoué sur cette source, réessaie dans un instant' : 'Aucun résultat'}</div>`;
  const more = sr.status !== 'recherche' && res.length && sr.count < 40
    ? `<button class="btn-ghost more" id="smore">Plus de résultats</button>` : '';
  box.innerHTML = tabs + body + more;
}
$('#paste').onclick = async () => {
  try { const t = await navigator.clipboard.readText(); if (extract(t).length) add(t); else { $('#url').value = t; $('#url').focus(); } }
  catch { $('#url').focus(); toast('Utilise Ctrl + V'); }
};
document.addEventListener('paste', e => {
  if (e.target.matches('input')) return;
  const t = e.clipboardData.getData('text'); if (extract(t).length){ e.preventDefault(); add(t); }
});
const hero = $('#hero');
['dragenter','dragover'].forEach(ev => document.addEventListener(ev, e => { e.preventDefault(); hero.classList.add('drag'); }));
['dragleave','drop'].forEach(ev => document.addEventListener(ev, e => { if (ev === 'dragleave' && e.relatedTarget) return; hero.classList.remove('drag'); }));
document.addEventListener('drop', e => { e.preventDefault(); add(e.dataTransfer.getData('text/uri-list') || e.dataTransfer.getData('text')); });

/* --- Journal des versions : ajouter une entrée en tête à chaque évolution --- */
const CHANGELOG = [
  ['2.6', '14/10/2026', ['Séparation voix / instrumental 10 à 20 fois plus rapide avec une carte graphique NVIDIA (activation en un clic dans Paramètres)', 'Sans carte NVIDIA : séparation environ 15 % plus rapide sur le processeur', 'Durée de chaque séparation affichée à la fin']],
  ['2.5', '14/10/2026', ['Mix : liste de soirée (glisser-déposer, tri par BPM) et Auto-DJ qui enchaîne tout seul, calé sur le tempo', 'Tonalité de chaque morceau (notation Camelot) et suggestions de morceaux compatibles', 'Effets Écho et Réverb sur chaque platine', 'Playlists YouTube : téléchargement de toute la playlist en un clic, et suivi automatique des nouveaux titres', 'Mixtapes : bouton pour les découper en morceaux séparés (l\'original reste intact)', 'Copie sur clé USB : sélection, liste de soirée, fichiers numérotés, noms sans accents', 'Choix de la sortie audio du lecteur (enceinte Bluetooth comme un Echo Dot, par exemple)']],
  ['2.4', '14/10/2026', ['Mix : pré-écoute au casque (sortie salle et sortie casque séparées)', 'SYNC aligne maintenant les temps et les garde calés, indicateur des 4 temps de la mesure', '4 hot cues par morceau (mémorisés), boucles de 4 et 8 temps, filtre passe-bas / passe-haut', 'Enregistrement du mix en MP3 directement dans ta bibliothèque', 'Raccourcis clavier (A/Z/E et P/O/I, 1-4 et 7-0, Espace, flèches)']],
  ['2.3.1', '13/10/2026', ['Les nouvelles versions sont détectées dès leur dépôt sur GitHub (plus d\'attente de 5 minutes)']],
  ['2.3', '13/10/2026', ['Nouvel onglet Mix : deux platines A et B comme un logiciel DJ', 'BPM détecté automatiquement, tempo ±8 % sans changer la tonalité, bouton SYNC', 'Égaliseur 3 bandes avec coupure, volume par platine, crossfader et enchaînement automatique (4, 8 ou 16 s)', 'Voix / Instrumental au choix sur chaque platine pour mélanger deux morceaux']],
  ['2.2', '13/10/2026', ['Nouvelle version détectée même quand l\'application est déjà ouverte (vérification toutes les 30 min)', 'Fenêtre de proposition avec la liste des nouveautés : Installer maintenant / Plus tard', 'Si un téléchargement est en cours, la mise à jour attend qu\'il soit terminé puis s\'installe toute seule']],
  ['2.1', '13/10/2026', ['Mises à jour intégrées depuis GitHub : vérification au démarrage, installation en un clic, sans alerte Windows', 'Installation en une ligne de commande, sans .exe à télécharger']],
  ['2.0.2', '13/10/2026', ['Noms propres : tirets spéciaux reconnus, « CLIP OFFICIEL » retiré même sans parenthèses', 'Titres du type « Artiste 1 - Artiste 2 " Titre " » correctement séparés']],
  ['2.0.1', '13/10/2026', ['Correction : le moteur ne s\'arrête plus après une mise en veille du PC (erreur « Failed to fetch »)', 'Si le moteur s\'arrête quand même, un bouton « Relancer YT MP3 » apparaît et la fenêtre se reconnecte toute seule']],
  ['2.0', '11/10/2026', ['Recherche multi-sources en parallèle : YouTube Music, YouTube et SoundCloud', 'Onglets par source, badges, doublons fusionnés (version YouTube Music privilégiée)', 'Bouton « Plus de résultats » (jusqu\'à 40 par source)', 'Choix des sources dans Paramètres, pochettes SoundCloud prises en charge']],
  ['1.9', '11/10/2026', ['Lecteur intégré : file de lecture, aléatoire, répétition, volume', 'Fondu enchaîné de 6 s entre les morceaux (mode soirée)', 'Bascule Original / Voix / Instrumental en pleine lecture', 'Touches multimédia du clavier, Espace, flèches, N / P']],
  ['1.8.3', '11/10/2026', ['Correction de l\'installation du module de séparation (Demucs 4.1.0, sans compilation)', 'En cas d\'échec, la cause exacte s\'affiche dans la carte']],
  ['1.8.2', '11/10/2026', ['Plus de lanceur .exe maison : les raccourcis démarrent directement PowerShell (fini les alertes antivirus au lancement)']],
  ['1.8.1', '11/10/2026', ['Démarrage fiable même si le port 8765 est déjà occupé (ancienne version encore ouverte, autre logiciel)']],
  ['1.8', '11/10/2026', ['Plus besoin de droits administrateur : nouveau serveur interne', 'Vrai logiciel à installer (installateur .exe, menu Démarrer, bureau, désinstallation)', 'Version installée : MP3 rangés par défaut dans Musique\\YT MP3']],
  ['1.7', '11/10/2026', ['Séparation voix / instrumental (module optionnel Demucs) : deux MP3 en sortie, avec tags et pochette']],
  ['1.6', '11/10/2026', ['Recherche directe : tape « artiste titre » sans passer par YouTube', 'Ne garder que la musique : intros parlées, scènes de clip et silences retirés', 'Noms et tags propres (artiste / titre séparés, « Clip Officiel », « HD »… retirés) et pochette carrée']],
  ['1.5', '11/10/2026', ['Numéro de version affiché et journal des évolutions']],
  ['1.4', '11/10/2026', ['Volume homogène : tous les morceaux au même niveau sonore (-14 LUFS)']],
  ['1.3', '11/10/2026', ['Analyse de la piste audio source', 'Débit MP3 choisi automatiquement, sans gonfler les fichiers pour rien']],
  ['1.2', '11/10/2026', ['Retélécharger un titre remplace l\'ancien fichier au lieu de créer un doublon']],
  ['1.1', '11/10/2026', ['Onglet Paramètres : dossier de téléchargement, session Firefox', 'Nouvelles tentatives automatiques en cas d\'erreur 403', 'yt-dlp en version nightly']],
  ['1.0', '11/10/2026', ['Application fenêtrée : file d\'attente, bibliothèque, miniatures, glisser-déposer']]
];
let changelogShown = false;
function renderAbout(v){
  $('#appver').textContent = 'v' + v;
  if (changelogShown) return;
  changelogShown = true;
  $('#aboutTxt').textContent = `Tu utilises YT MP3 v${v}.`;
  $('#log').innerHTML = CHANGELOG.map(([ver, date, items]) =>
    `<li class="${ver === v ? 'cur' : ''}"><div class="v">v${ver}<small>${date}</small></div><ul>${items.map(i => `<li>${esc(i)}</li>`).join('')}</ul></li>`).join('');
  // Annonce une fois après chaque mise à jour
  let last = null; try { last = localStorage.getItem('appver'); } catch {}
  if (last && last !== v) {
    const news = (CHANGELOG.find(c => c[0] === v) || [,,[]])[2];
    toast(`Mise à jour v${v} : ${news.join(' · ')}`, 'ok');
  }
  try { localStorage.setItem('appver', v); } catch {}
}
$('#appver').onclick = () => { show('set'); setTimeout(() => $('#about').scrollIntoView({behavior:'smooth'}), 50); };

/* --- Séparation : carte des paramètres --- */
let sepKey = '';
function gpuHtml(sp){
  const n = esc(sp.gpuName || 'NVIDIA');
  if (sp.gpu === 'pret') return `<div class="gpubox on"><b>⚡ Accélération par la carte graphique active</b><span>${n} : compte environ 10 à 30 secondes par morceau.</span></div>`;
  if (sp.gpu === 'installation') return `<div class="gpubox"><div class="sepst"><div class="spin"></div><span>Téléchargement de PyTorch pour ta carte ${n} (environ 2,5 Go)…<br><small style="color:var(--muted)">Les séparations reprendront ensuite, beaucoup plus vite.</small></span></div></div>`;
  if (sp.gpu === 'dispo' || sp.gpu === 'erreur') return `<div class="gpubox"><b>Carte graphique détectée : ${n}</b><span>Elle peut séparer les morceaux 10 à 20 fois plus vite que le processeur (environ 10 à 30 secondes au lieu de 1 à 3 minutes). Téléchargement unique d'environ 2,5 Go.</span>
      ${sp.gpu === 'erreur' ? `<p class="st err" style="white-space:normal;margin:10px 0 0">${esc(sp.gpuError)}</p>` : ''}
      <button class="go sm" data-act="gpuinstall" style="margin-top:12px;align-self:flex-start">⚡ ${sp.gpu === 'erreur' ? 'Réessayer' : 'Activer l\'accélération'}</button></div>`;
  return `<div class="gpubox"><b>Séparation sur le processeur</b><span>Aucune carte graphique NVIDIA détectée : les cartes AMD et Intel ne sont pas prises en charge par le moteur de séparation. Astuce : ferme les autres logiciels lourds pendant une séparation.</span></div>`;
}
function renderSepCard(sp){
  const key = JSON.stringify(sp); if (key === sepKey) return; sepKey = key;
  const box = $('#sepbox');
  if (sp.state === 'pret') box.innerHTML = `<div class="sepst ok-txt">✓ Module installé. Utilise le bouton ${I.split} sur un titre de la bibliothèque.</div>` + gpuHtml(sp);
  else if (sp.state === 'installation') box.innerHTML = `<div class="sepst"><div class="spin"></div><span>${esc(sp.step || 'Installation…')}<br><small style="color:var(--muted)">Tu peux continuer à utiliser l'application pendant ce temps.</small></span></div>`;
  else if (sp.state === 'erreur') box.innerHTML = `<p class="st err" style="white-space:normal;margin-bottom:12px">${esc(sp.error)}</p><button class="go sm" data-act="sepinstall">${I.retry}Réessayer l'installation</button>`;
  else box.innerHTML = `<button class="go sm" data-act="sepinstall">Installer le module (≈ 1,2 Go)</button>`;
}

/* ===================== Lecteur intégré ===================== */
const FADE = 6;   // durée du fondu enchaîné (secondes)
const P = { queue: [], idx: -1, id: null, stem: 'orig', playing: false, fading: false,
            shuffle: false, repeat: 'off', fade: false, vol: 0.8, muted: false };
try { Object.assign(P, JSON.parse(localStorage.getItem('player') || '{}'), { queue: [], idx: -1, id: null, playing: false, fading: false }); } catch {}
const decks = [new Audio(), new Audio()];
let deck = 0;                       // lecteur actif (l'autre sert au fondu)
const A = () => decks[deck];
decks.forEach(a => { a.preload = 'auto'; });
function savePlayer(){ try { localStorage.setItem('player', JSON.stringify({shuffle:P.shuffle, repeat:P.repeat, fade:P.fade, vol:P.vol, muted:P.muted})); } catch {} }
const byId = id => (state && state.history || []).find(x => x.id === id);
const fmtT = t => !isFinite(t) || t < 0 ? '0:00' : `${Math.floor(t / 60)}:${String(Math.floor(t % 60)).padStart(2, '0')}`;
const outVol = () => P.muted ? 0 : P.vol;
const url = (id, stem) => `/media/${id}/${stem}.mp3`;

function stemFor(x, want){ return (want === 'voix' && x.voix) || (want === 'instru' && x.instru) ? want : 'orig'; }

// Démarre la lecture d'un titre et prend la liste visible comme file de lecture
function playFrom(id, stem){
  const visible = [...document.querySelectorAll('#lib .item[data-id]')].map(e => e.dataset.id);
  P.queue = visible.length ? visible : (state.history || []).filter(x => x.exists).map(x => x.id);
  P.idx = Math.max(0, P.queue.indexOf(id));
  P.stem = stem || 'orig';
  load(id);
}

function load(id, opts = {}){
  const x = byId(id); if (!x) return;
  const st = stemFor(x, P.stem);
  const a = opts.deck !== undefined ? decks[opts.deck] : A();
  a.src = url(id, st);
  a.volume = opts.silent ? 0 : outVol();
  if (opts.at) a.addEventListener('loadedmetadata', () => { a.currentTime = opts.at; }, { once: true });
  a.play().catch(() => {});
  if (!opts.silent) { P.id = id; updateMeta(); }
}

function nextIndex(dir = 1){
  const n = P.queue.length; if (!n) return -1;
  if (P.shuffle && dir > 0 && n > 1) { let i; do { i = Math.floor(Math.random() * n); } while (i === P.idx); return i; }
  const i = P.idx + dir;
  if (i >= n) return P.repeat === 'all' ? 0 : -1;
  if (i < 0) return P.repeat === 'all' ? n - 1 : 0;
  return i;
}
function go(dir){
  cancelFade();
  if (dir < 0 && A().currentTime > 3) { A().currentTime = 0; return; }
  const i = nextIndex(dir);
  if (i < 0) { A().pause(); A().currentTime = 0; return; }
  P.idx = i; load(P.queue[i]);
}

// ---- Fondu enchaîné : le morceau suivant démarre sur le 2e lecteur pendant que le premier s'éteint ----
let fadeTimer = null;
function cancelFade(){
  if (!fadeTimer) return;
  clearInterval(fadeTimer); fadeTimer = null; P.fading = false;
  const other = decks[1 - deck]; other.pause(); other.removeAttribute('src');
  A().volume = outVol();
}
function startFade(){
  const i = nextIndex(1); if (i < 0) return;
  P.fading = true;
  const from = A(), toDeck = 1 - deck, to = decks[toDeck];
  load(P.queue[i], { deck: toDeck, silent: true });
  const t0 = performance.now();
  fadeTimer = setInterval(() => {
    const k = Math.min(1, (performance.now() - t0) / (FADE * 1000));
    from.volume = outVol() * (1 - k); to.volume = outVol() * k;
    if (k >= 1) {
      clearInterval(fadeTimer); fadeTimer = null;
      from.pause(); from.removeAttribute('src');
      deck = toDeck; P.idx = i; P.id = P.queue[i]; P.fading = false; updateMeta();
    }
  }, 50);
}

decks.forEach((a, n) => {
  a.addEventListener('timeupdate', () => {
    if (n !== deck) return;
    updateTime();
    if (P.fade && !P.fading && P.repeat !== 'one' && a.duration > FADE * 3 && a.duration - a.currentTime <= FADE) startFade();
  });
  a.addEventListener('ended', () => {
    if (n !== deck || P.fading) return;
    if (P.repeat === 'one') { a.currentTime = 0; a.play(); return; }
    go(1);
  });
  a.addEventListener('play', () => { if (n === deck) { djPauseAll(); P.playing = true; updateMeta(); } });
  a.addEventListener('pause', () => { if (n === deck && !P.fading) { P.playing = false; updateMeta(); } });
  a.addEventListener('error', () => { if (n === deck && a.getAttribute('src')) { toast('Lecture impossible de ce fichier', 'err'); setTimeout(() => go(1), 800); } });
});

function togglePlay(){ if (!P.id) { const f = document.querySelector('#lib .item[data-id]'); if (f) playFrom(f.dataset.id); return; } A().paused ? A().play() : A().pause(); }

// ---- Affichage ----
function setRange(el, k){ el.style.setProperty('--p', (k * 100).toFixed(2) + '%'); }
let seeking = false;
function updateTime(){
  const a = A();
  $('#plCur').textContent = fmtT(a.currentTime); $('#plDur').textContent = fmtT(a.duration);
  if (!seeking && a.duration) { const k = a.currentTime / a.duration; $('#plSeek').value = k * 1000; setRange($('#plSeek'), k); }
}
function updateMeta(){
  const x = byId(P.id);
  document.body.classList.toggle('has-player', !!x);
  $('#player').hidden = !x;
  if (!x) return;
  const st = stemFor(x, P.stem);
  $('#plTitle').textContent = x.title;
  $('#plSub').textContent = x.uploader + (st !== 'orig' ? (st === 'voix' ? ' · Voix seules' : ' · Instrumental') : '');
  const cv = coverUrl(x.vid, x.thumb);
  $('#plCover').style.backgroundImage = cv ? `url('${cv.replace(/'/g, '%27')}')` : '';
  $('#plCover').innerHTML = cv ? '' : I.note;
  $('#plPlay').innerHTML = P.playing ? I.pause : I.play;
  $('#plShuffle').classList.toggle('on', P.shuffle);
  $('#plRepeat').classList.toggle('on', P.repeat !== 'off');
  $('#plRepeat').innerHTML = I.repeat + (P.repeat === 'one' ? '<small>1</small>' : '');
  $('#plRepeat').title = {off:'Répéter : désactivé', all:'Répéter : toute la liste', one:'Répéter : ce titre'}[P.repeat];
  $('#plFade').classList.toggle('on', P.fade);
  $('#plFade').innerHTML = I.fade + 'Fondu';
  $('#plMute').innerHTML = P.muted || P.vol === 0 ? I.mute : I.vol;
  $('#plVol').value = Math.round(P.vol * 100); setRange($('#plVol'), P.vol);
  document.querySelectorAll('#plStem button').forEach(b => {
    b.disabled = b.dataset.s !== 'orig' && !x[b.dataset.s];
    b.classList.toggle('on', b.dataset.s === st);
  });
  $('#plStem').style.display = (x.voix || x.instru) ? '' : 'none';
  document.title = (P.playing ? '▶ ' : '') + x.title + ' — YT MP3';
  if ('mediaSession' in navigator) {
    navigator.mediaSession.metadata = new MediaMetadata({ title: x.title, artist: x.uploader, album: 'YT MP3',
      artwork: coverUrl(x.vid, x.thumb, true) ? [{ src: coverUrl(x.vid, x.thumb, true) }] : [] });
    navigator.mediaSession.playbackState = P.playing ? 'playing' : 'paused';
  }
  libKey = ''; if (state) render(state);   // met à jour l'indicateur dans la bibliothèque
}

// ---- Commandes ----
$('#plShuffle').innerHTML = I.shuffle; $('#plPrev').innerHTML = I.prev; $('#plNext').innerHTML = I.next;
$('#plPlay').onclick = togglePlay;
$('#plPrev').onclick = () => go(-1);
$('#plNext').onclick = () => go(1);
$('#plShuffle').onclick = () => { P.shuffle = !P.shuffle; savePlayer(); updateMeta(); };
$('#plRepeat').onclick = () => { P.repeat = {off:'all', all:'one', one:'off'}[P.repeat]; savePlayer(); updateMeta(); };
$('#plFade').onclick = () => { P.fade = !P.fade; if (!P.fade) cancelFade(); savePlayer(); updateMeta(); toast(P.fade ? 'Fondu enchaîné activé' : 'Fondu enchaîné désactivé'); };
$('#plMute').onclick = () => { P.muted = !P.muted; A().volume = outVol(); savePlayer(); updateMeta(); };
$('#plVol').oninput = e => { P.vol = e.target.value / 100; P.muted = false; if (!P.fading) A().volume = outVol(); setRange(e.target, P.vol); savePlayer(); $('#plMute').innerHTML = P.vol === 0 ? I.mute : I.vol; };
$('#plSeek').oninput = e => { seeking = true; setRange(e.target, e.target.value / 1000); $('#plCur').textContent = fmtT(e.target.value / 1000 * A().duration); };
$('#plSeek').onchange = e => { cancelFade(); if (A().duration) A().currentTime = e.target.value / 1000 * A().duration; seeking = false; };
$('#plStem').onclick = e => {
  const b = e.target.closest('button'); if (!b || b.disabled) return;
  P.stem = b.dataset.s; cancelFade();
  const t = A().currentTime, wasPlaying = !A().paused;
  load(P.id, { at: t }); if (!wasPlaying) A().pause();
};
document.addEventListener('keydown', e => {
  if (!$('#v-dj').hidden) return;   // l'onglet Mix a ses propres raccourcis
  if (e.target.matches('input:not([type=range]), textarea') || !P.id) return;
  if (e.code === 'Space') { e.preventDefault(); togglePlay(); }
  else if (e.code === 'ArrowRight') { A().currentTime = Math.min(A().duration || 0, A().currentTime + 5); }
  else if (e.code === 'ArrowLeft') { A().currentTime = Math.max(0, A().currentTime - 5); }
  else if (e.code === 'KeyN') go(1);
  else if (e.code === 'KeyP') go(-1);
});
if ('mediaSession' in navigator) {
  const ms = navigator.mediaSession;
  ms.setActionHandler('play', () => A().play());
  ms.setActionHandler('pause', () => A().pause());
  ms.setActionHandler('previoustrack', () => go(-1));
  ms.setActionHandler('nexttrack', () => go(1));
  try { ms.setActionHandler('seekto', d => { A().currentTime = d.seekTime; }); } catch {}
}

/* --- Mises à jour --- */
let bootVersion = null, updating = false, updKey = '';
function renderUpdate(s){
  // Après une mise à jour, le moteur redémarre en nouvelle version : on recharge la page pour la nouvelle interface
  if (!bootVersion) bootVersion = s.appVersion;
  else if (s.appVersion !== bootVersion) { location.reload(); return; }
  const u = s.update || {};
  const nv = $('#newver');
  nv.hidden = u.state !== 'dispo';
  nv.textContent = u.planned ? `Mise à jour v${u.latest} prévue` : `Mise à jour v${u.latest}`;
  const key = JSON.stringify(u); if (key === updKey) return; updKey = key;
  let html;
  if (u.state === 'verif') html = `<div class="updst"><div class="spin"></div>Recherche d'une mise à jour…</div>`;
  else if (u.state === 'dispo' && u.planned) html = `<div class="updst"><div class="spin"></div>La v${esc(u.latest)} s'installera automatiquement à la fin des téléchargements en cours.</div><button class="btn-ghost" id="cancelPlan">Annuler</button>`;
  else if (u.state === 'dispo') html = `<div class="updst">Nouvelle version disponible : <b>v${esc(u.latest)}</b> (tu as v${esc(s.appVersion)})</div>`
      + ((u.notes || []).length ? `<ul class="dlg-notes" style="margin:0 0 14px">${u.notes.map(n => `<li>${esc(n)}</li>`).join('')}</ul>` : '')
      + (u.canApply ? `<button class="go sm" id="doUpdate">${u.busy ? 'Installer à la fin des téléchargements' : 'Installer la mise à jour'}</button>`
                    : `<p class="st err" style="white-space:normal">Installe YT MP3 avec la commande d'installation pour profiter des mises à jour automatiques.</p>`);
  else if (u.state === 'ajour') html = `<div class="updst ok-txt">✓ Tu as la dernière version (v${esc(s.appVersion)}).</div><button class="btn-ghost" data-act="checkupdate">Vérifier à nouveau</button>`;
  else if (u.state === 'erreur') html = `<p class="st err" style="white-space:normal;margin-bottom:12px">${esc(u.error)}</p><button class="btn-ghost" data-act="checkupdate">Réessayer</button>`;
  else html = `<button class="btn-ghost" data-act="checkupdate">Rechercher une mise à jour</button>`;
  $('#updbox').innerHTML = html;
  const b = $('#doUpdate'); if (b) b.onclick = () => startUpdate(u);
  const c = $('#cancelPlan'); if (c) c.onclick = async () => { try { render(await api('/api/cancelupdate', {})); toast('Mise à jour programmée annulée'); } catch {} };
}

// Lance la mise à jour : tout de suite, ou à la fin des téléchargements en cours
let updatePlanned = false;
function showUpdating(v){
  updating = true; hideDlg();
  $('#ov').classList.add('show');
  $('#ovbox').innerHTML = `<div class="spin"></div><h3>Mise à jour vers v${esc(v)}</h3><p>YT MP3 redémarre, la fenêtre va se recharger toute seule…</p>`;
}
async function startUpdate(u){
  const btns = [$('#doUpdate'), $('#dlgGo')].filter(Boolean);
  btns.forEach(x => { x.disabled = true; });
  try {
    const r = await api('/api/update', { whenIdle: !!u.busy });
    if (r.error) { toast(r.error, 'err'); return; }
    if (r.planned) { updatePlanned = true; hideDlg(); toast('La mise à jour s\'installera à la fin des téléchargements', 'ok'); return; }
    showUpdating(u.latest);
  } catch(e){ toast(e.message, 'err'); }
  finally { btns.forEach(x => { x.disabled = false; }); }
}

/* --- Fenêtre « nouvelle version disponible » : proposée d'elle-même, une fois par version --- */
let dlgShownFor = null;
function hideDlg(){ $('#upddlg').classList.remove('show'); }
function maybeOfferUpdate(s){
  const u = s.update || {};
  if (u.state !== 'dispo' || !u.canApply || u.planned || updating) { if (u.state !== 'dispo') hideDlg(); return; }
  let dismissed = null; try { dismissed = localStorage.getItem('updDismissed'); } catch {}
  if (dismissed === u.latest || dlgShownFor === u.latest) {
    if ($('#upddlg').classList.contains('show')) fillDlg(u, s.appVersion);   // garde le bon bouton si un téléchargement démarre/finit
    return;
  }
  dlgShownFor = u.latest;
  fillDlg(u, s.appVersion);
  $('#upddlg').classList.add('show');
}
function fillDlg(u, cur){
  $('#dlgTitle').textContent = `YT MP3 v${u.latest} est disponible`;
  $('#dlgSub').textContent = `Tu utilises la v${cur}. La mise à jour prend quelques secondes ; ta bibliothèque et tes réglages sont conservés.` +
    (u.busy ? ' Un téléchargement est en cours : la mise à jour peut attendre qu\'il soit terminé.' : '');
  $('#dlgNotes').innerHTML = (u.notes || []).map(n => `<li>${esc(n)}</li>`).join('');
  $('#dlgGo').textContent = u.busy ? 'Installer à la fin des téléchargements' : 'Installer maintenant';
  $('#dlgGo').onclick = () => startUpdate(u);
}
$('#dlgLater').onclick = () => {
  try { localStorage.setItem('updDismissed', dlgShownFor); } catch {}
  hideDlg(); toast('D\'accord. Le badge en haut reste disponible si tu changes d\'avis.');
};
$('#newver').onclick = () => { show('set'); setTimeout(() => $('#updcard').scrollIntoView({behavior:'smooth'}), 50); };

/* ===================== Mode DJ : deux platines ===================== */
// Graphe audio de chaque platine (contexte « salle ») :
//   lecteur → graves → médiums → aigus → passe-bas → passe-haut ─┬→ volume → crossfader → sortie salle (+ enregistrement)
//                                                                 └→ pré-écoute (0/1) → bus casque → 2e contexte audio → sortie casque
const DJ = { ctx: null, master: null, cueBus: null, cueCtx: null, xf: 0.5, len: 8, mix: null, d: [], rec: null };
const DJ_MAX = 40 * 1048576;   // au-delà (mixtapes), pas de forme d'onde ni d'analyse : lecture et mixage restent possibles
const HOT_COL = ['#f43f5e', '#f59e0b', '#22c55e', '#38bdf8'];
const LSJ = {
  get(k, def){ try { const v = localStorage.getItem(k); return v === null ? def : JSON.parse(v); } catch { return def; } },
  set(k, v){ try { localStorage.setItem(k, JSON.stringify(v)); } catch {} }
};
const djInfo = id => (LSJ.get('djinfo', {}))[id] || null;               // { bpm, b0 } : tempo et position d'un temps
const djInfoSave = (id, v) => { const c = LSJ.get('djinfo', {}); c[id] = v; LSJ.set('djinfo', c); };
const djCuesOf = id => (LSJ.get('djcues', {}))[id] || [null, null, null, null];
const djCuesSave = (id, v) => { const c = LSJ.get('djcues', {}); c[id] = v; LSJ.set('djcues', c); };
const djOut = () => LSJ.get('djout', { main: '', cue: '', player: '' });
async function applyPlayerOut(){
  const o = djOut().player || '';
  for (const a of decks) { try { if (a.setSinkId && (o || a.sinkId)) await a.setSinkId(o); } catch { toast('Sortie du lecteur introuvable : sortie par défaut utilisée', 'err'); break; } }
}
const fr1 = v => (+v).toFixed(1).replace('.', ',');

const IC = {
  phones: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 18v-6a9 9 0 0 1 18 0v6"/><path d="M21 19a2 2 0 0 1-2 2h-1v-6h3zM3 19a2 2 0 0 0 2 2h1v-6H3z"/></svg>',
  loop: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m17 2 4 4-4 4"/><path d="M3 11v-1a4 4 0 0 1 4-4h14"/><path d="m7 22-4-4 4-4"/><path d="M21 13v1a4 4 0 0 1-4 4H3"/></svg>',
  rec: '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="6" fill="currentColor"/></svg>',
  keys: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><rect x="2" y="6" width="20" height="12" rx="2"/><path d="M6 10h.01M10 10h.01M14 10h.01M18 10h.01M7 14h10"/></svg>'
};

function djDeckHtml(L){
  const keys = L === 'A' ? ['A', 'Z', 'E', '1-4'] : ['P', 'O', 'I', '7-0'];
  return `<div class="dk-head"><div class="dk-cover"><span class="dk-letter">${L}</span></div>
    <div class="dk-meta"><div class="t dk-title">Platine ${L} vide</div><div class="s dk-sub">Charge un morceau avec le bouton ${L} de la bibliothèque</div></div>
    <div class="dk-bpm"><b class="dk-bpmv">--</b><small>BPM</small><div class="dk-beats" title="Temps de la mesure"><i></i><i></i><i></i><i></i></div><div class="dk-key" title="Tonalité (notation Camelot). En vert : compatible avec l'autre platine"></div></div></div>
  <canvas class="dk-wave" title="Clique pour te déplacer dans le morceau"></canvas>
  <div class="dk-time"><span class="dk-cur">0:00</span><span class="dk-rem">-0:00</span></div>
  <div class="dk-row">
    <button class="dk-btn dk-cue" title="CUE (${keys[1]}) : à l'arrêt, place le point de départ ; en lecture, y revient">CUE</button>
    <button class="dk-btn dk-play" title="Lecture / pause (${keys[0]})"></button>
    <button class="dk-btn dk-sync" title="SYNC (${keys[2]}) : cale le tempo ET les temps sur l'autre platine, et les garde alignés">SYNC</button>
    <button class="dk-btn dk-pfl" title="Pré-écoute au casque : tu entends cette platine dans le casque, la salle ne l'entend que via le crossfader">${IC.phones}</button>
    <div class="sp"></div>
    <div class="seg mini dk-stem"><button type="button" data-s="orig">Original</button><button type="button" data-s="voix">Voix</button><button type="button" data-s="instru">Instru</button></div>
  </div>
  <div class="dk-row dk-row2">
    <div class="dk-hots" title="Hot cues (${keys[3]}) : clic sur un repère vide = le placer ; clic = y sauter ; clic droit = l'effacer">
      ${[0, 1, 2, 3].map(n => `<button class="dk-hot" data-h="${n}" style="--hc:${HOT_COL[n]}">${n + 1}</button>`).join('')}
    </div>
    <div class="sp"></div>
    <span class="dk-lbl">${IC.loop}</span>
    <div class="dk-loops" title="Boucle de 4 ou 8 temps, calée sur le tempo (re-clic pour sortir)">
      <button class="dk-loop" data-n="4">4</button><button class="dk-loop" data-n="8">8</button>
    </div>
  </div>
  <div class="dk-grid">
    <span>Tempo</span><input type="range" class="dk-tempo" min="-8" max="8" step="0.1" value="0" title="Double-clic : 0 %"><output data-o="tempo">0,0 %</output>
    <span>Filtre</span><input type="range" class="dk-filt" min="-100" max="100" step="1" value="0" title="À gauche : son étouffé (passe-bas) · à droite : son aigu (passe-haut) · double-clic : neutre"><output data-o="filt">—</output>
    <span>Écho</span><input type="range" class="dk-fx" data-fx="echo" min="0" max="100" value="0" title="Écho calé sur le tempo (3/4 de temps) · double-clic : 0"><output data-o="echo">—</output>
    <span>Réverb</span><input type="range" class="dk-fx" data-fx="rev" min="0" max="100" value="0" title="Réverbération · double-clic : 0"><output data-o="rev">—</output>
    <span>Aigus</span><input type="range" class="dk-eq" data-b="high" min="-26" max="6" step="0.5" value="0" title="Double-clic : neutre"><output data-o="high">0 dB</output>
    <span>Médiums</span><input type="range" class="dk-eq" data-b="mid" min="-26" max="6" step="0.5" value="0" title="Double-clic : neutre"><output data-o="mid">0 dB</output>
    <span>Graves</span><input type="range" class="dk-eq" data-b="low" min="-26" max="6" step="0.5" value="0" title="Double-clic : neutre"><output data-o="low">0 dB</output>
    <span>Volume</span><input type="range" class="dk-vol" min="0" max="100" value="100"><output data-o="vol">100 %</output>
  </div>`;
}

/* ---------- Contexte audio, sorties salle / casque ---------- */
function djCtx(){
  if (!DJ.ctx) {
    const C = window.AudioContext || window.webkitAudioContext;
    DJ.ctx = new C({ latencyHint: 'interactive' });
    DJ.master = DJ.ctx.createGain(); DJ.master.connect(DJ.ctx.destination);
    DJ.cueBus = DJ.ctx.createMediaStreamDestination();
    DJ.d.forEach(d => {
      const c = DJ.ctx, src = c.createMediaElementSource(d.el);
      const low = c.createBiquadFilter(); low.type = 'lowshelf'; low.frequency.value = 220;
      const mid = c.createBiquadFilter(); mid.type = 'peaking'; mid.frequency.value = 1000; mid.Q.value = 0.8;
      const high = c.createBiquadFilter(); high.type = 'highshelf'; high.frequency.value = 3500;
      const lp = c.createBiquadFilter(); lp.type = 'lowpass'; lp.frequency.value = 20000; lp.Q.value = 1.1;
      const hp = c.createBiquadFilter(); hp.type = 'highpass'; hp.frequency.value = 10; hp.Q.value = 1.1;
      const vol = c.createGain(), xg = c.createGain(), pfl = c.createGain(), sum = c.createGain();
      // Écho : retard réinjecté (feedback) ; réverbération : convolution avec une réponse générée
      const delay = c.createDelay(2), fb = c.createGain(), echoWet = c.createGain();
      const conv = c.createConvolver(), revWet = c.createGain();
      conv.buffer = djImpulse(c, 2.6);
      echoWet.gain.value = 0; revWet.gain.value = 0; fb.gain.value = 0;
      src.connect(low).connect(mid).connect(high).connect(lp).connect(hp);
      hp.connect(sum);
      hp.connect(delay); delay.connect(fb).connect(delay); delay.connect(echoWet).connect(sum);
      hp.connect(conv).connect(revWet).connect(sum);
      sum.connect(vol).connect(xg).connect(DJ.master);
      sum.connect(pfl).connect(DJ.cueBus);
      d.nodes = { low, mid, high, lp, hp, vol, xg, pfl, delay, fb, echoWet, revWet };
      djApply(d);
    });
    djApplyXf();
    djApplyOutputs();
  }
  if (DJ.ctx.state === 'suspended') DJ.ctx.resume();
  return DJ.ctx;
}
async function djApplyOutputs(){
  const o = djOut();
  // On ne change de sortie que si une sortie précise est choisie (ou pour revenir à la sortie par défaut)
  try {
    if (DJ.ctx && DJ.ctx.setSinkId && (o.main || DJ.ctx.sinkId)) await DJ.ctx.setSinkId(o.main || '');
    if (DJ.ctx && DJ.ctx.state === 'suspended') DJ.ctx.resume();
  } catch { toast('Sortie salle introuvable : sortie par défaut utilisée', 'err'); }
  if (o.cue && DJ.ctx) {
    if (!DJ.cueCtx) {
      const C = window.AudioContext || window.webkitAudioContext;
      DJ.cueCtx = new C({ latencyHint: 'interactive' });
      DJ.cueCtx.createMediaStreamSource(DJ.cueBus.stream).connect(DJ.cueCtx.destination);
    }
    try { if (DJ.cueCtx.setSinkId) await DJ.cueCtx.setSinkId(o.cue); } catch { toast('Sortie casque introuvable : vérifie qu’il est allumé et connecté', 'err'); }
    if (DJ.cueCtx.state === 'suspended') DJ.cueCtx.resume();
  } else if (DJ.cueCtx) { DJ.cueCtx.close(); DJ.cueCtx = null; }
}
// Réponse impulsionnelle d'une salle : bruit stéréo qui décroît
function djImpulse(c, sec){
  const len = Math.floor(c.sampleRate * sec), buf = c.createBuffer(2, len, c.sampleRate);
  for (let ch = 0; ch < 2; ch++) { const x = buf.getChannelData(ch); for (let i = 0; i < len; i++) x[i] = (Math.random() * 2 - 1) * Math.pow(1 - i / len, 3.2); }
  return buf;
}
function djApply(d){
  if (!d.nodes) return;
  const t = DJ.ctx.currentTime, n = d.nodes;
  const beat = d.bpm ? 60 / (d.bpm * d.rate) : 0.5;
  n.delay.delayTime.setTargetAtTime(Math.min(1.9, beat * 0.75), t, 0.05);
  n.fb.gain.setTargetAtTime(d.echo ? 0.25 + 0.45 * d.echo : 0, t, 0.02);
  n.echoWet.gain.setTargetAtTime(d.echo * 0.7, t, 0.02);
  n.revWet.gain.setTargetAtTime(d.rev * 0.9, t, 0.03);
  ['low', 'mid', 'high'].forEach(b => n[b].gain.setTargetAtTime(d.eq[b], t, 0.015));
  n.vol.gain.setTargetAtTime(d.vol, t, 0.015);
  // Filtre : à gauche passe-bas de 20 kHz à 200 Hz, à droite passe-haut de 20 Hz à 5 kHz (courbes exponentielles)
  const f = d.filt / 100;
  n.lp.frequency.setTargetAtTime(f < 0 ? 20000 * Math.pow(200 / 20000, -f) : 20000, t, 0.02);
  n.hp.frequency.setTargetAtTime(f > 0 ? 20 * Math.pow(5000 / 20, f) : 10, t, 0.02);
  n.pfl.gain.setTargetAtTime(d.pfl ? 1 : 0, t, 0.01);
}
function djApplyXf(){   // crossfader à puissance constante : pas de creux de volume au milieu
  if (!DJ.ctx) return;
  const t = DJ.ctx.currentTime, x = DJ.xf;
  DJ.d[0].nodes.xg.gain.setTargetAtTime(Math.cos(x * Math.PI / 2), t, 0.015);
  DJ.d[1].nodes.xg.gain.setTargetAtTime(Math.sin(x * Math.PI / 2), t, 0.015);
}
function djPauseAll(){ (DJ.d || []).forEach(d => { if (!d.el.paused) d.el.pause(); }); djStopMix(); }
function djPauseMain(){ if (typeof P !== 'undefined' && P.id && !A().paused) { cancelFade(); A().pause(); } }

/* ---------- Chargement et analyse (forme d'onde, tempo, grille des temps) ---------- */
function djLoad(i, id, stem, quiet){
  const d = DJ.d[i], x = byId(id); if (!x) return;
  if (!quiet) djStopMix();
  d.el.pause();
  d.id = id; d.stem = stemFor(x, stem || 'orig'); d.cue = 0; d.peaks = null; d.loop = null; d.sync = false; d.nudge = 1;
  const inf = djInfo(id); d.bpm = inf ? inf.bpm : null; d.b0 = inf ? inf.b0 : 0; d.key = inf ? inf.key : null;
  d.hot = djCuesOf(id);
  djSetSrc(d, 0, false);
  djMeta(d); djAnalyse(d); djRenderLib(true); djRenderSet();
  if (!quiet) toast(`${x.title} chargé sur la platine ${d.L}`);
}
function djSetSrc(d, at, play){
  d.el.src = url(d.id, d.stem);
  d.el.defaultPlaybackRate = d.rate * d.nudge; d.el.preservesPitch = true;
  d.el.addEventListener('loadedmetadata', () => {
    d.el.playbackRate = d.rate * d.nudge;
    if (at) d.el.currentTime = at;
    if (play) d.el.play().catch(() => {});
  }, { once: true });
}
// Récupère tout le fichier par morceaux (le moteur envoie 2 Mo maximum par requête)
async function djFetchAll(u){
  const parts = []; let got = 0, total = null;
  while (total === null || got < total) {
    const r = await fetch(u, { headers: { Range: `bytes=${got}-` } });
    if (!r.ok) return null;
    const m = (r.headers.get('Content-Range') || '').match(/\/(\d+)$/);
    total = m ? +m[1] : null;
    if (total && total > DJ_MAX) return null;
    const b = new Uint8Array(await r.arrayBuffer());
    if (!b.length) break;
    parts.push(b); got += b.length;
    if (total === null) break;
  }
  const out = new Uint8Array(got); let o = 0;
  parts.forEach(p => { out.set(p, o); o += p.length; });
  return out.buffer;
}
// Décode un fichier en 11 kHz mono (léger) ; null si trop long ou illisible
async function djDecode(u){
  const buf = await djFetchAll(u);
  if (!buf) return null;
  const ab = await new OfflineAudioContext(1, 1, 11025).decodeAudioData(buf);
  let mono = ab.getChannelData(0);
  if (ab.numberOfChannels > 1) { const r = ab.getChannelData(1); const m = new Float32Array(mono.length); for (let i = 0; i < m.length; i++) m[i] = (mono[i] + r[i]) / 2; mono = m; }
  return { mono, sr: ab.sampleRate };
}
// Tempo et tonalité se calculent sur l'original (les voix seules n'ont pas de rythme fiable)
function djAnalyseMono(id, mono, sr){
  const inf = Object.assign({}, djInfo(id) || {});
  if (!inf.bpm) { const r = djRhythm(mono, sr); if (r) Object.assign(inf, r); }
  if (!inf.key) { const k = djKey(mono, sr); if (k) inf.key = k; }
  inf.v = 2;
  djInfoSave(id, inf);
  return inf;
}
async function djAnalyse(d){
  const id = d.id, stem = d.stem;
  try {
    const r = await djDecode(url(id, stem));
    if (d.id !== id || d.stem !== stem) return;
    if (!r) { d.peaks = 'x'; return; }
    d.peaks = djPeaks(r.mono, 1200);
    if (stem === 'orig' && (!d.bpm || !d.key)) {
      const inf = djAnalyseMono(id, r.mono, r.sr);
      d.bpm = inf.bpm || null; d.b0 = inf.b0 || 0; d.key = inf.key || null;
    }
    djMeta(d); djMeta(DJ.d[1 - d.i]); djRenderLib(true); djRenderSet();
  } catch { if (d.id === id) d.peaks = 'x'; }
}

/* ---------- Tonalité : profil de chroma (12 notes) comparé aux 24 gammes (Krumhansl) ---------- */
const NOTE_FR = ['Do', 'Do♯', 'Ré', 'Mi♭', 'Mi', 'Fa', 'Fa♯', 'Sol', 'La♭', 'La', 'Si♭', 'Si'];
const KS_MAJ = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88];
const KS_MIN = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17];
function djFFT(re, im){
  const n = re.length;
  for (let i = 1, j = 0; i < n; i++) { let bit = n >> 1; for (; j & bit; bit >>= 1) j ^= bit; j ^= bit; if (i < j) { [re[i], re[j]] = [re[j], re[i]]; [im[i], im[j]] = [im[j], im[i]]; } }
  for (let len = 2; len <= n; len <<= 1) {
    const ang = -2 * Math.PI / len, wr = Math.cos(ang), wi = Math.sin(ang);
    for (let i = 0; i < n; i += len) {
      let cr = 1, ci = 0;
      for (let k = 0; k < len / 2; k++) {
        const a = i + k, b = a + len / 2, tr = re[b] * cr - im[b] * ci, ti = re[b] * ci + im[b] * cr;
        re[b] = re[a] - tr; im[b] = im[a] - ti; re[a] += tr; im[a] += ti;
        const nr = cr * wr - ci * wi; ci = cr * wi + ci * wr; cr = nr;
      }
    }
  }
}
function djKey(x, sr){
  const N = 4096, len = Math.min(x.length, Math.floor(sr * 120)), start = Math.max(0, Math.floor((x.length - len) / 2));
  const frames = Math.floor(len / N); if (frames < 8) return null;
  const chroma = new Float64Array(12), re = new Float64Array(N), im = new Float64Array(N), win = new Float64Array(N);
  for (let i = 0; i < N; i++) win[i] = 0.5 - 0.5 * Math.cos(2 * Math.PI * i / (N - 1));
  const kMin = Math.ceil(60 * N / sr), kMax = Math.floor(2100 * N / sr), pcOf = new Int8Array(kMax + 1);
  for (let k = kMin; k <= kMax; k++) pcOf[k] = ((Math.round(12 * Math.log2(k * sr / N / 440)) + 69) % 12 + 12) % 12;
  for (let f = 0; f < frames; f++) {
    const o = start + f * N;
    for (let i = 0; i < N; i++) { re[i] = x[o + i] * win[i]; im[i] = 0; }
    djFFT(re, im);
    let tot = 0; const fr = new Float64Array(12);
    for (let k = kMin; k <= kMax; k++) { const m = Math.sqrt(re[k] * re[k] + im[k] * im[k]); fr[pcOf[k]] += m; tot += m; }
    if (tot > 0) for (let p = 0; p < 12; p++) chroma[p] += fr[p] / tot;   // chaque trame compte pareil
  }
  const corr = (a, b) => { const ma = a.reduce((s, v) => s + v, 0) / 12, mb = b.reduce((s, v) => s + v, 0) / 12; let n = 0, da = 0, db = 0; for (let i = 0; i < 12; i++) { n += (a[i] - ma) * (b[i] - mb); da += (a[i] - ma) ** 2; db += (b[i] - mb) ** 2; } return n / Math.sqrt(da * db || 1); };
  let best = -2, key = null;
  for (let tonic = 0; tonic < 12; tonic++) for (const minor of [false, true]) {
    const prof = minor ? KS_MIN : KS_MAJ, rot = Array.from({ length: 12 }, (_, i) => prof[(i - tonic + 12) % 12]);
    const c = corr(Array.from(chroma), rot);
    if (c > best) { best = c; key = { tonic, minor }; }
  }
  if (best < 0.45) return { cam: '', name: '', none: true };
  const camMaj = pc => ((pc * 7) % 12 + 7) % 12 + 1;
  const num = key.minor ? camMaj((key.tonic + 3) % 12) : camMaj(key.tonic);
  return { cam: num + (key.minor ? 'A' : 'B'), name: NOTE_FR[key.tonic] + (key.minor ? ' mineur' : ' majeur') };
}
// Compatibilité harmonique (roue de Camelot) : même case, voisine (±1), ou relative (A↔B)
function djKeyOk(a, b){
  if (!a || !b || !a.cam || !b.cam) return false;
  const na = parseInt(a.cam), nb = parseInt(b.cam), la = a.cam.slice(-1), lb = b.cam.slice(-1);
  if (na === nb) return true;
  return la === lb && (Math.abs(na - nb) === 1 || Math.abs(na - nb) === 11);
}
function djPeaks(x, n){
  const step = Math.max(1, Math.floor(x.length / n)), p = new Float32Array(n); let mx = 0;
  for (let i = 0; i < n; i++) {
    let m = 0; const s = i * step, e = Math.min(x.length, s + step);
    for (let j = s; j < e; j += 2) { const v = Math.abs(x[j]); if (v > m) m = v; }
    p[i] = m; if (m > mx) mx = m;
  }
  if (mx > 0) for (let i = 0; i < n; i++) p[i] /= mx;
  return p;
}
// Tempo (autocorrélation de l'enveloppe d'attaques) et grille des temps (décalage qui aligne le mieux les attaques)
function djRhythm(x, sr){
  const hop = 64, win = 256;
  const len = Math.min(x.length, Math.floor(sr * 90)), start = Math.max(0, Math.floor((x.length - len) / 2));
  const nF = Math.floor((len - win) / hop); if (nF < 400) return null;
  // Copie filtrée passe-bas 150 Hz (biquad) : le rythme se lit surtout dans la grosse caisse et la basse
  const lowx = new Float32Array(len);
  { const w = 2 * Math.PI * 150 / sr, al = Math.sin(w) / (2 * 0.707), c = Math.cos(w), a0 = 1 + al;
    const b0 = (1 - c) / 2 / a0, b1 = (1 - c) / a0, b2 = b0, a1 = -2 * c / a0, a2 = (1 - al) / a0;
    let x1 = 0, x2 = 0, y1 = 0, y2 = 0;
    for (let i = 0; i < len; i++) { const xi = x[start + i], y = b0 * xi + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2; x2 = x1; x1 = xi; y2 = y1; y1 = y; lowx[i] = y; } }
  const onsetOf = (sig, off) => {
    const env = new Float32Array(nF), o2 = new Float32Array(nF); let m = 0;
    for (let f = 0; f < nF; f++) { let s = 0; const o = off + f * hop; for (let j = 0; j < win; j++) { const v = sig[o + j]; s += v * v; } env[f] = Math.sqrt(s / win); }
    for (let f = 1; f < nF; f++) { const dv = env[f] - env[f - 1]; o2[f] = dv > 0 ? dv : 0; m += o2[f]; }
    m = m / nF || 1; for (let f = 0; f < nF; f++) o2[f] /= m;
    return o2;
  };
  const onFull = onsetOf(x, start), onLow = onsetOf(lowx, 0);
  const on = new Float32Array(nF), onc = new Float32Array(nF); let mean = 0;
  for (let f = 0; f < nF; f++) { on[f] = 1.5 * onLow[f] + onFull[f]; mean += on[f]; }
  mean /= nF; for (let f = 0; f < nF; f++) onc[f] = on[f] - mean;
  const fd = hop / sr, minL = Math.floor(60 / 200 / fd), maxL = Math.ceil(60 / 60 / fd);
  const ac = new Float32Array(2 * maxL + 2);
  for (let L = minL - 1; L <= Math.min(2 * maxL + 1, nF - 1); L++) { let s = 0; for (let f = 0; f + L < nF; f++) s += onc[f] * onc[f + L]; ac[L] = s / (nF - L); }
  let best = -Infinity, bL = 0;
  for (let L = minL; L <= maxL; L++) { const sc = ac[L] + 0.5 * ac[2 * L]; if (sc > best) { best = sc; bL = L; } }
  if (!bL || best <= 0) return null;
  const a = ac[bL - 1], b = ac[bL], c = ac[bL + 1], den = a - 2 * b + c;
  let bpm = 60 / ((bL + (den ? 0.5 * (a - c) / den : 0)) * fd);
  while (bpm < 75) bpm *= 2; while (bpm >= 165) bpm /= 2;
  bpm = Math.round(bpm * 10) / 10;
  // Grille : on teste 96 décalages sur une période et on garde celui qui tombe le plus sur les attaques
  const per = 60 / bpm / fd; let bo = 0, bs = -1;
  for (let s = 0; s < 96; s++) {
    const off = s / 96 * per; let sum = 0;
    for (let k = off; k < nF - 1; k += per) { const i = Math.round(k); sum += on[i] + 0.5 * (on[i - 1] || 0) + 0.5 * on[i + 1]; }
    if (sum > bs) { bs = sum; bo = off; }
  }
  const period = 60 / bpm;
  let b0 = (start / sr + bo * fd) % period;
  return { bpm, b0: Math.round(b0 * 10000) / 10000 };
}
// Position dans la grille : nombre de temps écoulés (décimal) à un instant du morceau
const djBeatPos = (d, t) => d.bpm ? (t - d.b0) / (60 / d.bpm) : 0;
const djBeatTime = (d, n) => d.b0 + n * 60 / d.bpm;   // instant du n-ième temps
const djQuant = (d, t) => d.bpm ? djBeatTime(d, Math.round(djBeatPos(d, t))) : t;

/* ---------- Affichage ---------- */
function djMeta(d){
  const x = byId(d.id), q = s => d.root.querySelector(s);
  djPlayIcon(d);
  if (!x) return;
  q('.dk-title').textContent = x.title;
  q('.dk-sub').textContent = x.uploader + (d.stem === 'voix' ? ' · Voix seules' : d.stem === 'instru' ? ' · Instrumental' : '');
  const cv = coverUrl(x.vid, x.thumb), cov = q('.dk-cover');
  cov.style.backgroundImage = cv ? `url('${cv.replace(/'/g, '%27')}')` : '';
  q('.dk-bpmv').textContent = d.bpm ? fr1(d.bpm * d.rate) : '--';
  d.root.querySelectorAll('.dk-stem button').forEach(b => {
    b.disabled = b.dataset.s !== 'orig' && !x[b.dataset.s];
    b.classList.toggle('on', b.dataset.s === d.stem);
  });
  d.root.querySelectorAll('.dk-hot').forEach(b => b.classList.toggle('set', d.hot[+b.dataset.h] !== null));
  const kel = q('.dk-key'), o = DJ.d[1 - d.i];
  kel.innerHTML = d.key && d.key.cam ? `<b>${d.key.cam}</b>${d.key.name}` : '';
  kel.classList.toggle('ok', !!(o && o.id && djKeyOk(d.key, o.key)));
  d.root.querySelectorAll('.dk-loop').forEach(b => b.classList.toggle('on', !!d.loop && d.loop.n === +b.dataset.n));
  q('.dk-sync').classList.toggle('on', d.sync);
  q('.dk-pfl').classList.toggle('on', d.pfl);
}
function djPlayIcon(d){
  d.root.querySelector('.dk-play').innerHTML = d.el.paused ? I.play : I.pause;
  d.root.classList.toggle('on', !d.el.paused);
  if (!DJ.mix) djMixBtn();
}
function djSetTempoUI(d){
  const v = (d.rate - 1) * 100, q = s => d.root.querySelector(s);
  q('.dk-tempo').value = v;
  q('output[data-o="tempo"]').textContent = `${v > 0.04 ? '+' : ''}${fr1(v)} %`;
  q('.dk-bpmv').textContent = d.bpm ? fr1(d.bpm * d.rate) : '--';
}
// Forme d'onde : partie jouée, boucle, hot cues, point CUE, tête de lecture ; indicateur des 4 temps
function djDraw(){
  if (!$('#v-dj').hidden) DJ.d.forEach(d => {
    const cv = d.root.querySelector('.dk-wave'), w = cv.clientWidth, h = cv.clientHeight, r = devicePixelRatio || 1;
    if (!w) return;
    if (cv.width !== Math.round(w * r)) { cv.width = Math.round(w * r); cv.height = Math.round(h * r); }
    const g = cv.getContext('2d'); g.setTransform(r, 0, 0, r, 0, 0); g.clearRect(0, 0, w, h);
    const dur = d.el.duration || 0, cur = d.el.currentTime || 0, k = dur ? cur / dur : 0;
    const col = d.i ? '#8b5cf6' : '#ff3b6b';
    if (dur && d.loop) { g.fillStyle = '#22c55e26'; g.fillRect(d.loop.in / dur * w, 0, Math.max(2, (d.loop.out - d.loop.in) / dur * w), h); }
    if (d.peaks instanceof Float32Array) {
      const n = d.peaks.length;
      for (let px = 0; px < w; px += 2) {
        const v = d.peaks[Math.floor(px / w * n)], bh = Math.max(1, v * (h - 10));
        g.fillStyle = px / w < k ? col : '#3a4050'; g.fillRect(px, (h - bh) / 2, 1.4, bh);
      }
    } else {
      g.fillStyle = '#2b303c'; g.fillRect(0, h / 2 - 1, w, 2);
      g.fillStyle = col; g.fillRect(0, h / 2 - 1, w * k, 2);
      if (d.id) { g.fillStyle = '#8a90a0'; g.font = '12px Segoe UI, system-ui'; g.fillText(d.peaks === 'x' ? 'Forme d’onde indisponible (fichier trop long)' : 'Analyse du morceau…', 10, 18); }
    }
    if (dur) {
      d.hot.forEach((t, n) => {
        if (t === null) return;
        const x = t / dur * w;
        g.fillStyle = HOT_COL[n]; g.fillRect(x, 0, 2, h);
        g.fillRect(x, 0, 12, 12); g.fillStyle = '#0b0c10'; g.font = 'bold 9px Segoe UI, system-ui'; g.fillText(n + 1, x + 3.5, 9.5);
      });
      g.fillStyle = '#fbbf24'; g.fillRect(d.cue / dur * w, h - 10, 2, 10);
      g.fillStyle = '#fff'; g.fillRect(k * w - 1, 0, 2, h);
    }
    d.root.querySelector('.dk-cur').textContent = fmtT(cur);
    d.root.querySelector('.dk-rem').textContent = '-' + fmtT(Math.max(0, dur - cur));
    const beats = d.root.querySelectorAll('.dk-beats i'), bp = d.bpm && d.id ? djBeatPos(d, cur) : null;
    const nb = bp === null ? -1 : ((Math.floor(bp) % 4) + 4) % 4, flash = bp !== null && bp - Math.floor(bp) < 0.25 && !d.el.paused;
    beats.forEach((b, n) => { b.classList.toggle('on', n === nb); b.classList.toggle('hit', n === nb && flash); });
  });
  requestAnimationFrame(djDraw);
}

/* ---------- SYNC : tempo + temps alignés, puis maintenus (petites corrections de vitesse) ---------- */
// Écart (en secondes réelles) entre le prochain temps de d et celui de l'autre platine o, ramené à ± une demi-période
function djPhaseErr(d, o){
  const pd = 60 / (d.bpm * d.el.playbackRate), po = 60 / (o.bpm * o.el.playbackRate);
  const bd = djBeatPos(d, d.el.currentTime), bo = djBeatPos(o, o.el.currentTime);
  let e = (Math.ceil(bd) - bd) * pd - (Math.ceil(bo) - bo) * po;
  const p = Math.min(pd, po);
  e = ((e % p) + p) % p; if (e > p / 2) e -= p;
  return e;
}
function djSyncOn(d, quiet){
  const o = DJ.d[1 - d.i], say = (m) => { if (!quiet) toast(m, 'err'); };
  if (!d.id || !o.id) { say('Charge un morceau sur les deux platines'); return false; }
  if (!d.bpm || !o.bpm) { say('Tempo pas encore détecté sur les deux platines'); return false; }
  let ratio = o.bpm * o.rate / d.bpm, f = 1;
  [2, 0.5].forEach(m => { if (Math.abs(ratio * m - 1) < Math.abs(ratio - 1)) { ratio *= m; f = m; } });   // demi/double tempo
  if (Math.abs(ratio - 1) > 0.08) { say('Écart de tempo trop grand (plus de 8 %)'); return false; }
  if (o.sync) { o.sync = false; djMeta(o); }   // une seule platine suit l'autre
  d.sync = true; d.syncF = f; d.rate = ratio; d.nudge = 1;
  d.el.playbackRate = d.rate; d.el.defaultPlaybackRate = d.rate;
  djSetTempoUI(d); djAlign(d); djMeta(d);
  return true;
}
function djAlign(d){   // saut immédiat pour aligner les temps (si les deux platines jouent)
  const o = DJ.d[1 - d.i];
  if (!d.sync || d.el.paused || o.el.paused || !d.el.duration) return;
  const e = djPhaseErr(d, o);
  if (Math.abs(e) > 0.004) d.el.currentTime = Math.max(0, d.el.currentTime + e * d.el.playbackRate);
}
setInterval(() => {
  DJ.d.forEach(d => {
    const o = DJ.d[1 - d.i];
    if (!d.sync || !o.id || !o.bpm) return;
    // suit le tempo de l'autre platine
    const target = o.bpm * o.rate * d.syncF / d.bpm;
    if (Math.abs(target - d.rate) > 0.0005) { d.rate = target; djSetTempoUI(d); }
    if (d.el.paused || o.el.paused) { if (d.nudge !== 1) { d.nudge = 1; d.el.playbackRate = d.rate; } return; }
    const e = djPhaseErr(d, o);
    if (Math.abs(e) > 0.06) { d.nudge = 1; d.el.playbackRate = d.rate; djAlign(d); return; }
    d.nudge = 1 + Math.max(-0.02, Math.min(0.02, e * 0.6));   // rattrape la dérive en douceur
    d.el.playbackRate = d.rate * d.nudge;
  });
}, 100);

/* ---------- Boucles ---------- */
function djLoop(d, n){
  if (!d.id) return;
  if (d.loop && d.loop.n === n) { d.loop = null; djMeta(d); return; }
  if (!d.bpm) { toast('Tempo pas encore détecté : boucle impossible', 'err'); return; }
  const t = d.el.currentTime, i = Math.floor(djBeatPos(d, t) + 0.02);
  const start = djBeatTime(d, i);
  d.loop = { n, in: start, out: start + n * 60 / d.bpm };
  djMeta(d);
}
setInterval(() => {
  DJ.d.forEach(d => {
    if (!d.loop || d.el.paused) return;
    const t = d.el.currentTime;
    if (t >= d.loop.out - 0.012) d.el.currentTime = d.loop.in + Math.max(0, t - d.loop.out);
    else if (t < d.loop.in - 0.5) d.loop = null;   // déplacé avant la boucle : on en sort
  });
}, 8);

/* ---------- Hot cues ---------- */
function djHot(d, n, erase){
  if (!d.id) return;
  if (erase) { d.hot[n] = null; djCuesSave(d.id, d.hot); djMeta(d); return; }
  if (d.hot[n] === null) {
    d.hot[n] = Math.max(0, djQuant(d, d.el.currentTime));
    djCuesSave(d.id, d.hot); djMeta(d);
    toast(`Repère ${n + 1} placé sur la platine ${d.L}`);
    return;
  }
  d.loop = null;
  d.el.currentTime = d.hot[n];
  if (d.el.paused) { djCtx(); d.el.play().catch(() => {}); }
  djMeta(d);
}

/* ---------- Enchaînement automatique : le crossfader glisse vers l'autre platine ---------- */
function djStopMix(){ if (DJ.mix) { clearInterval(DJ.mix.timer); DJ.mix = null; } djMixBtn(); }
function djMixTarget(){   // platine visée : celle qui ne joue pas
  const pa = !DJ.d[0].el.paused, pb = !DJ.d[1].el.paused;
  if (pa && !pb) return 1;
  if (pb && !pa) return 0;
  return DJ.xf <= 0.5 ? 1 : 0;
}
function djMixBtn(){
  const b = $('#automix'); if (!b || DJ.d.length < 2) return;
  b.textContent = DJ.mix ? 'Arrêter l’enchaînement' : (djMixTarget() ? 'Enchaîner vers B ▶' : '◀ Enchaîner vers A');
}
function djAutoMix(){
  if (DJ.mix) { djStopMix(); return; }
  const to = djMixTarget(), from = 1 - to, dt = DJ.d[to];
  if (!dt.id) { toast(`Charge d'abord un morceau sur la platine ${dt.L}`, 'err'); return; }
  djCtx(); djPauseMain();
  if (dt.el.paused) dt.el.play().catch(() => {});
  const x0 = DJ.xf, x1 = to ? 1 : 0, t0 = performance.now(), ms = DJ.len * 1000;
  DJ.mix = { timer: setInterval(() => {
    const k = Math.min(1, (performance.now() - t0) / ms);
    DJ.xf = x0 + (x1 - x0) * k; $('#xf').value = Math.round(DJ.xf * 1000); djApplyXf();
    if (k >= 1) { DJ.d[from].el.pause(); djStopMix(); }
  }, 40) };
  djMixBtn();
}

/* ---------- Enregistrement du mix (sortie salle) en MP3 ---------- */
function djRecBtn(){
  const b = $('#recbtn'); if (!b) return;
  if (DJ.rec) {
    const s = Math.floor((performance.now() - DJ.rec.t0) / 1000);
    b.innerHTML = `${IC.rec}<span>${fmtT(s)}</span>`; b.classList.add('on'); b.title = 'Arrêter et enregistrer le mix en MP3';
  } else { b.innerHTML = `${IC.rec}<span>Enregistrer</span>`; b.classList.remove('on'); b.title = 'Enregistrer ton mix (sortie salle) en MP3'; }
}
function djRecToggle(){
  if (DJ.rec) { DJ.rec.mr.stop(); return; }
  if (!window.MediaRecorder) { toast('Enregistrement non pris en charge', 'err'); return; }
  djCtx();
  const dest = DJ.ctx.createMediaStreamDestination(); DJ.master.connect(dest);
  const type = ['audio/webm;codecs=opus', 'audio/webm', 'audio/ogg;codecs=opus'].find(t => MediaRecorder.isTypeSupported(t)) || '';
  const mr = new MediaRecorder(dest.stream, type ? { mimeType: type, audioBitsPerSecond: 256000 } : {});
  const chunks = [];
  mr.ondataavailable = e => { if (e.data && e.data.size) chunks.push(e.data); };
  mr.onstop = async () => {
    clearInterval(DJ.rec.timer); try { DJ.master.disconnect(dest); } catch {}
    const secs = (performance.now() - DJ.rec.t0) / 1000; DJ.rec = null; djRecBtn();
    if (secs < 2) { toast('Enregistrement trop court, ignoré'); return; }
    const blob = new Blob(chunks, { type: type || 'audio/webm' });
    toast('Mix enregistré, conversion en MP3…');
    try {
      const r = await fetch('/api/recording', { method: 'POST', headers: { 'Content-Type': 'application/octet-stream' }, body: blob });
      if (!r.ok) throw new Error();
    } catch { toast('Impossible d’enregistrer le mix', 'err'); }
  };
  mr.start(1000);
  DJ.rec = { mr, t0: performance.now(), timer: setInterval(djRecBtn, 500) };
  djRecBtn();
  toast('Enregistrement du mix démarré');
}

/* ---------- Création des deux platines et de leurs commandes ---------- */
['A', 'B'].forEach((L, i) => {
  const root = $('#deck' + L); root.innerHTML = djDeckHtml(L);
  const el = new Audio(); el.preload = 'auto';
  const d = { i, L, root, el, id: null, stem: 'orig', cue: 0, bpm: null, b0: 0, peaks: null, rate: 1, nudge: 1, vol: 1,
              eq: { low: 0, mid: 0, high: 0 }, filt: 0, echo: 0, rev: 0, key: null, pfl: false, sync: false, syncF: 1, loop: null, hot: [null, null, null, null], nodes: null };
  DJ.d.push(d);
  const q = s => root.querySelector(s);
  root.querySelectorAll('.dk-stem button').forEach(b => { b.disabled = b.dataset.s !== 'orig'; b.classList.toggle('on', b.dataset.s === 'orig'); });
  djPlayIcon(d);
  el.addEventListener('play', () => { djPlayIcon(d); djPauseMain(); });
  el.addEventListener('playing', () => { DJ.autoPending = false; djAlign(d); });
  el.addEventListener('pause', () => djPlayIcon(d));
  el.addEventListener('ended', () => djPlayIcon(d));
  d.toggle = () => {
    if (!d.id) { toast(`Charge un morceau sur la platine ${L}`, 'err'); return; }
    djCtx();
    if (el.paused) el.play().catch(() => {}); else el.pause();
  };
  d.cueBtn = () => {
    if (!d.id) return;
    if (!el.paused) { el.pause(); el.currentTime = d.cue; } else { d.cue = djQuant(d, el.currentTime); el.currentTime = d.cue; }
  };
  d.syncBtn = () => { if (d.sync) { d.sync = false; d.nudge = 1; el.playbackRate = d.rate; djMeta(d); } else if (djSyncOn(d)) toast(`Platine ${L} synchronisée`); };
  q('.dk-play').onclick = d.toggle;
  q('.dk-cue').onclick = d.cueBtn;
  q('.dk-sync').onclick = d.syncBtn;
  q('.dk-pfl').onclick = () => {
    if (!djOut().cue) {
      toast('Choisis d’abord ta sortie casque dans Paramètres', 'err');
      show('set'); setTimeout(() => $('#djcard').scrollIntoView({ behavior: 'smooth' }), 50); return;
    }
    djCtx(); djApplyOutputs();
    d.pfl = !d.pfl; djApply(d); djMeta(d);
  };
  root.querySelectorAll('.dk-hot').forEach(b => {
    b.onclick = e => djHot(d, +b.dataset.h, e.shiftKey);
    b.oncontextmenu = e => { e.preventDefault(); djHot(d, +b.dataset.h, true); };
  });
  root.querySelectorAll('.dk-loop').forEach(b => { b.onclick = () => djLoop(d, +b.dataset.n); });
  const cv = q('.dk-wave'); let drag = false;
  const seek = e => { if (!el.duration) return; const r = cv.getBoundingClientRect(); d.loop = null; el.currentTime = Math.max(0, Math.min(1, (e.clientX - r.left) / r.width)) * el.duration; };
  cv.addEventListener('pointerdown', e => { drag = true; cv.setPointerCapture(e.pointerId); seek(e); });
  cv.addEventListener('pointermove', e => { if (drag) seek(e); });
  cv.addEventListener('pointerup', () => { drag = false; djAlign(d); djMeta(d); });
  q('.dk-stem').onclick = e => {
    const b = e.target.closest('button'); if (!b || b.disabled || !d.id || b.dataset.s === d.stem) return;
    d.stem = b.dataset.s; d.peaks = null;
    djSetSrc(d, el.currentTime, !el.paused);
    djMeta(d); djAnalyse(d);
  };
  const tempo = q('.dk-tempo');
  const setTempo = v => {   // réglage manuel : désactive SYNC
    if (d.sync) { d.sync = false; djMeta(d); }
    d.rate = 1 + v / 100; d.nudge = 1; el.playbackRate = d.rate; el.defaultPlaybackRate = d.rate;
    djSetTempoUI(d);
  };
  tempo.oninput = () => setTempo(+tempo.value);
  tempo.ondblclick = () => setTempo(0);
  root.querySelectorAll('.dk-eq').forEach(r => {
    const b = r.dataset.b, out = q(`output[data-o="${b}"]`);
    const set = v => { r.value = v; d.eq[b] = +v; out.textContent = +v <= -26 ? 'coupé' : `${v > 0 ? '+' : ''}${(+v).toFixed(1).replace('.0', '').replace('.', ',')} dB`; djApply(d); };
    r.oninput = () => set(r.value); r.ondblclick = () => set(0);
  });
  const filt = q('.dk-filt'), fout = q('output[data-o="filt"]');
  const setFilt = v => {
    filt.value = v; d.filt = +v; djApply(d);
    const hz = v < 0 ? 20000 * Math.pow(200 / 20000, -v / 100) : 20 * Math.pow(5000 / 20, v / 100);
    fout.textContent = +v === 0 ? '—' : `${v < 0 ? 'PB' : 'PH'} ${hz >= 1000 ? fr1(hz / 1000) + ' k' : Math.round(hz) + ' '}Hz`;
  };
  filt.oninput = () => setFilt(+filt.value); filt.ondblclick = () => setFilt(0);
  root.querySelectorAll('.dk-fx').forEach(r => {
    const k = r.dataset.fx, out = q(`output[data-o="${k}"]`);
    const set = v => { r.value = v; d[k] = v / 100; out.textContent = +v ? v + ' %' : '—'; djApply(d); };
    r.oninput = () => set(+r.value); r.ondblclick = () => set(0);
  });
  const vol = q('.dk-vol');
  vol.oninput = () => { d.vol = vol.value / 100; q('output[data-o="vol"]').textContent = vol.value + ' %'; djApply(d); };
});
$('#xf').oninput = e => { djStopMix(); DJ.xf = e.target.value / 1000; djApplyXf(); djMixBtn(); };
$('#xf').ondblclick = () => { djStopMix(); DJ.xf = 0.5; $('#xf').value = 500; djApplyXf(); djMixBtn(); };
$('#automix').onclick = djAutoMix;
$('#recbtn').onclick = djRecToggle;
$('#keysbtn').innerHTML = IC.keys + '<span>Raccourcis</span>';
$('#keysbtn').onclick = () => $('#keyhelp').classList.toggle('show');
$('#keyhelp').onclick = e => { if (e.target === $('#keyhelp') || e.target.closest('.kclose')) $('#keyhelp').classList.remove('show'); };
DJ.len = LSJ.get('mixlen', 8);
const djLen = () => document.querySelectorAll('#mixlen button').forEach(b => b.classList.toggle('on', +b.dataset.l === DJ.len));
$('#mixlen').onclick = e => { const b = e.target.closest('button'); if (!b) return; DJ.len = +b.dataset.l; LSJ.set('mixlen', DJ.len); djLen(); };
djLen(); djMixBtn(); djRecBtn(); requestAnimationFrame(djDraw);

/* ---------- Raccourcis clavier de l'onglet Mix ----------
   Platine A : A lecture · Z CUE · E SYNC · 1 2 3 4 hot cues     Platine B : P lecture · O CUE · I SYNC · 7 8 9 0 hot cues
   Espace : enchaîner · ← → : crossfader · Maj + chiffre : effacer un hot cue */
document.addEventListener('keydown', e => {
  if ($('#v-dj').hidden || e.ctrlKey || e.altKey || e.metaKey || e.target.matches('input:not([type=range]), textarea, select')) return;
  const k = e.key.toLowerCase(), [A_, B_] = DJ.d;
  const map = { a: A_.toggle, z: A_.cueBtn, e: A_.syncBtn, p: B_.toggle, o: B_.cueBtn, i: B_.syncBtn };
  const hot = { Digit1: [0, 0], Digit2: [0, 1], Digit3: [0, 2], Digit4: [0, 3], Digit7: [1, 0], Digit8: [1, 1], Digit9: [1, 2], Digit0: [1, 3] }[e.code];
  if (map[k]) { e.preventDefault(); map[k](); }
  else if (hot) { e.preventDefault(); djHot(DJ.d[hot[0]], hot[1], e.shiftKey); }
  else if (e.code === 'Space') { e.preventDefault(); djAutoMix(); }
  else if (e.code === 'ArrowLeft' || e.code === 'ArrowRight') {
    e.preventDefault(); djStopMix();
    DJ.xf = Math.max(0, Math.min(1, DJ.xf + (e.code === 'ArrowLeft' ? -0.05 : 0.05)));
    $('#xf').value = Math.round(DJ.xf * 1000); djApplyXf(); djMixBtn();
  }
});

/* ---------- Paramètres : sorties salle et casque ---------- */
async function djListOutputs(){
  const sm = $('#outMain'), sc = $('#outCue'), sp = $('#outPlayer'); if (!sm) return;
  let devs = [];
  try { devs = (await navigator.mediaDevices.enumerateDevices()).filter(x => x.kind === 'audiooutput' && x.deviceId !== 'default' && x.deviceId !== 'communications'); } catch {}
  const o = djOut(), named = devs.some(x => x.label);
  const opts = devs.map((x, n) => `<option value="${esc(x.deviceId)}">${esc(x.label || `Sortie audio ${n + 1}`)}</option>`).join('');
  sm.innerHTML = `<option value="">Sortie par défaut de Windows</option>` + opts;
  sp.innerHTML = sm.innerHTML;
  sp.value = devs.some(x => x.deviceId === o.player) ? o.player : '';
  sc.innerHTML = `<option value="">Aucune (pré-écoute désactivée)</option>` + opts;
  sm.value = devs.some(x => x.deviceId === o.main) ? o.main : '';
  sc.value = devs.some(x => x.deviceId === o.cue) ? o.cue : '';
  $('#outNames').hidden = named || !devs.length;
  $('#outHint').textContent = !devs.length ? 'Aucune sortie audio détectée.' : named ? '' : 'Clique sur « Afficher les noms » pour reconnaître tes appareils.';
}
const djSaveOut = () => { LSJ.set('djout', { main: $('#outMain').value, cue: $('#outCue').value, player: $('#outPlayer').value }); djApplyOutputs(); applyPlayerOut(); toast('Sorties audio enregistrées'); };
$('#outPlayer').onchange = djSaveOut;
applyPlayerOut();
$('#outMain').onchange = djSaveOut;
$('#outCue').onchange = () => { djSaveOut(); if (!$('#outCue').value) DJ.d.forEach(d => { d.pfl = false; djApply(d); djMeta(d); }); };
$('#outNames').onclick = async () => {
  try { const s = await navigator.mediaDevices.getUserMedia({ audio: true }); s.getTracks().forEach(t => t.stop()); }
  catch { toast('Autorisation refusée : les sorties restent sans nom', 'err'); }
  djListOutputs();
};
try { navigator.mediaDevices.addEventListener('devicechange', djListOutputs); } catch {}
djListOutputs();

/* ===================== Liste de soirée + Auto-DJ ===================== */
const SET = { ids: LSJ.get('djset', []), played: new Set(), now: null };
const setSave = () => LSJ.set('djset', SET.ids);
function setAdd(id){
  if (SET.ids.includes(id)) { SET.ids = SET.ids.filter(x => x !== id); toast('Retiré de la liste de soirée'); }
  else { SET.ids.push(id); toast('Ajouté à la liste de soirée'); }
  setSave(); djRenderSet(); djRenderLib(true);
}
const setValid = () => { const ok = new Set((state.history || []).filter(x => x.exists).map(x => x.id)); SET.ids = SET.ids.filter(id => ok.has(id)); };

// Morceau suivant : la liste de soirée d'abord, puis le morceau de la bibliothèque le plus compatible (tempo + tonalité)
function autoNextId(curId){
  setValid();
  const i = SET.ids.indexOf(curId);
  const fromSet = i >= 0 ? SET.ids.slice(i + 1).find(id => !SET.played.has(id)) : SET.ids.find(id => !SET.played.has(id) && id !== curId);
  if (fromSet) return fromSet;
  // choix automatique mémorisé, pour ne pas changer d'avis à chaque instant
  if (SET.pick && SET.pick.for === curId && !SET.played.has(SET.pick.id) && byId(SET.pick.id)) return SET.pick.id;
  const cur = djInfo(curId), cand = (state.history || []).filter(x => x.exists && x.id !== curId && !SET.played.has(x.id) && x.uploader !== 'Mix YT MP3');
  if (!cand.length) return null;
  const score = x => {
    const inf = djInfo(x.id); let sc = Math.random() * 0.3;
    if (cur && cur.bpm && inf && inf.bpm) { let r = inf.bpm / cur.bpm; [2, 0.5].forEach(m => { if (Math.abs(r * m - 1) < Math.abs(r - 1)) r *= m; }); sc += Math.max(0, 1 - Math.abs(r - 1) / 0.08); }
    if (cur && inf && djKeyOk(cur.key, inf.key)) sc += 0.8;
    return sc;
  };
  const pick = cand.map(x => [x.id, score(x)]).sort((a, b) => b[1] - a[1])[0][0];
  SET.pick = { for: curId, id: pick };
  return pick;
}
const startPoint = d => d.hot[0] !== null ? d.hot[0] : (d.bpm ? d.b0 : 0);

DJ.auto = false;
function autoBtn(){
  const b = $('#autodj'); if (!b) return;
  b.innerHTML = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2v4M12 18v4M4.9 4.9l2.8 2.8M16.3 16.3l2.8 2.8M2 12h4M18 12h4M4.9 19.1l2.8-2.8M16.3 7.7l2.8-2.8"/></svg><span>Auto-DJ${DJ.auto ? ' activé' : ''}</span>`;
  b.classList.toggle('on', DJ.auto);
}
function autoToggle(){
  DJ.auto = !DJ.auto; autoBtn();
  if (DJ.auto) { djCtx(); djPauseMain(); toast('Auto-DJ activé : la soirée s’enchaîne toute seule'); autoTick(); }
  else toast('Auto-DJ désactivé : tu reprends la main');
  djRenderSet();
}
function autoTick(){
  if (!DJ.auto || DJ.mix || !state) return;
  const playing = DJ.d.filter(d => !d.el.paused && d.id);
  if (!playing.length) {
    // Morceau en cours mis en pause : on attend (sauf si c'est nous qui sommes en train de le lancer)
    const held = DJ.d.find(x => x.id && x.id === SET.now && !x.el.ended);
    if (held) { if (DJ.autoPending) held.el.play().catch(() => {}); return; }
    // Démarrage : morceau suivant sur la platine A, crossfader côté A
    const d = DJ.d[0];
    const id = d.id && !SET.played.has(d.id) ? d.id : autoNextId(SET.now);
    if (!id) { DJ.auto = false; autoBtn(); toast('Plus de morceau à enchaîner : Auto-DJ arrêté'); return; }
    if (d.id !== id) djLoad(0, id, 'orig', true);
    DJ.xf = 0; $('#xf').value = 0; djApplyXf(); djMixBtn();
    const go = () => { d.el.currentTime = startPoint(d); d.el.play().catch(() => {}); };
    if (d.el.readyState >= 1) go(); else d.el.addEventListener('loadedmetadata', go, { once: true });
    SET.now = id; SET.played.add(id); DJ.autoPending = true; djRenderSet();
    return;
  }
  const cur = playing.length === 1 ? playing[0] : (DJ.xf < 0.5 ? DJ.d[0] : DJ.d[1]), nxt = DJ.d[1 - cur.i];
  if (SET.now !== cur.id) { SET.now = cur.id; SET.played.add(cur.id); djRenderSet(); }
  const nextId = autoNextId(cur.id);
  if (!nextId) return;
  if (nxt.id !== nextId && nxt.el.paused) { djLoad(nxt.i, nextId, 'orig', true); return; }   // préchargement
  // Hors enchaînement : retour progressif au tempo d'origine du morceau en cours
  if (!cur.sync && Math.abs(cur.rate - 1) > 0.001 && cur.el.duration - cur.el.currentTime > 40) {
    cur.rate += Math.sign(1 - cur.rate) * Math.min(0.0005, Math.abs(1 - cur.rate));
    cur.el.playbackRate = cur.rate * cur.nudge; djSetTempoUI(cur);
  }
  const remain = (cur.el.duration - cur.el.currentTime) / (cur.el.playbackRate || 1);
  if (cur.el.duration && remain <= DJ.len + 1.5 && nxt.id === nextId && nxt.el.readyState >= 2) {
    nxt.loop = null;
    nxt.el.currentTime = startPoint(nxt);
    if (nxt.bpm && cur.bpm) djSyncOn(nxt, true);
    djAutoMix();
  }
}
setInterval(() => { try { autoTick(); } catch {} }, 400);
// Fin d'un enchaînement automatique : la platine qui reste devient libre (plus de SYNC)
const _djStopMix = djStopMix;
djStopMix = function(){
  const was = !!DJ.mix; _djStopMix();
  if (was && DJ.auto) DJ.d.forEach(d => { if (d.sync && DJ.d[1 - d.i].el.paused) { d.sync = false; d.nudge = 1; d.el.playbackRate = d.rate; djMeta(d); } });
};

// Affichage de la liste (glisser-déposer pour réordonner)
let setKey = '', dragFrom = null;
function djRenderSet(){
  if (!state || $('#v-dj').hidden) return;
  setValid();
  const info = LSJ.get('djinfo', {}), nextId = SET.now ? autoNextId(SET.now) : null;
  const key = JSON.stringify([SET.ids, SET.now, [...SET.played], nextId, DJ.auto, info]);
  if (key === setKey) return; setKey = key;
  $('#setcount').textContent = SET.ids.length ? `${SET.ids.length} titre${SET.ids.length > 1 ? 's' : ''}` : '';
  const nx = nextId && byId(nextId), cu = SET.now && byId(SET.now);
  $('#setnow').innerHTML = DJ.auto
    ? (cu ? `En cours : <b>${esc(cu.title)}</b>${nx ? ` · ensuite : <b>${esc(nx.title)}</b>` : ''}` : 'Auto-DJ prêt…')
    : 'Active <b>Auto-DJ</b> pour enchaîner la liste toute seule.';
  $('#setlist').innerHTML = SET.ids.length ? SET.ids.map((id, i) => {
    const x = byId(id); if (!x) return '';
    const inf = info[id] || {};
    const cls = id === SET.now ? 'now' : id === nextId ? 'next' : SET.played.has(id) ? 'done' : '';
    return `<div class="setitem ${cls}" draggable="true" data-i="${i}">
      <span class="num">${id === SET.now ? '▶' : i + 1}</span>
      ${thumb(x.vid, '', false, x.thumb)}
      <div class="meta"><div class="t">${esc(x.title)}</div><div class="s">${esc(x.uploader)}${inf.bpm ? ` · ${fr1(inf.bpm)} BPM` : ''}${inf.key && inf.key.cam ? ` · ${inf.key.cam}` : ''}</div></div>
      <button class="ib" data-setrm="${i}" title="Retirer de la liste">${I.x}</button></div>`;
  }).join('') : `<div class="setempty">Ajoute des morceaux avec le bouton <b>+</b> de la bibliothèque.<br>Sans liste, l'Auto-DJ choisit lui-même des morceaux compatibles.</div>`;
}
$('#setlist').addEventListener('click', e => {
  const b = e.target.closest('[data-setrm]'); if (!b) return;
  SET.ids.splice(+b.dataset.setrm, 1); setSave(); djRenderSet(); djRenderLib(true);
});
$('#setlist').addEventListener('dragstart', e => { const it = e.target.closest('.setitem'); if (!it) return; dragFrom = +it.dataset.i; it.classList.add('drag'); e.dataTransfer.effectAllowed = 'move'; e.dataTransfer.setData('text/plain', 'set'); });
$('#setlist').addEventListener('dragend', e => { const it = e.target.closest('.setitem'); if (it) it.classList.remove('drag'); });
$('#setlist').addEventListener('dragover', e => { const it = e.target.closest('.setitem'); if (dragFrom === null || !it) return; e.preventDefault(); e.stopPropagation(); document.querySelectorAll('.setitem.over').forEach(x => x.classList.remove('over')); it.classList.add('over'); });
$('#setlist').addEventListener('drop', e => {
  const it = e.target.closest('.setitem'); if (dragFrom === null || !it) return;
  e.preventDefault(); e.stopPropagation();
  const to = +it.dataset.i, [m] = SET.ids.splice(dragFrom, 1); SET.ids.splice(to, 0, m);
  dragFrom = null; setSave(); setKey = ''; djRenderSet();
});
$('#setsort').onclick = () => {
  const info = LSJ.get('djinfo', {});
  SET.ids.sort((a, b) => ((info[a] || {}).bpm || 999) - ((info[b] || {}).bpm || 999));
  setSave(); setKey = ''; djRenderSet(); toast('Liste triée par tempo croissant');
};
$('#setclear').onclick = () => { if (!SET.ids.length || !confirm('Vider la liste de soirée ?')) return; SET.ids = []; SET.played.clear(); setSave(); djRenderSet(); djRenderLib(true); };
$('#autodj').onclick = autoToggle;
autoBtn();

/* ---------- Analyse de fond : tempo et tonalité de toute la bibliothèque (onglet Mix ouvert) ---------- */
let anaBusy = false;
async function djAnalyseLibrary(){
  if (anaBusy || $('#v-dj').hidden || !state) return;
  const todo = (state.history || []).filter(x => x.exists && x.uploader !== 'Mix YT MP3' && !LSJ.get('anaskip', {})[x.id] && !((djInfo(x.id) || {}).v === 2));
  $('#anacount').textContent = todo.length ? `analyse du tempo et de la tonalité… (${todo.length} restant${todo.length > 1 ? 's' : ''})` : '';
  if (!todo.length) return;
  anaBusy = true;
  const x = todo[0];
  try {
    const r = await djDecode(url(x.id, 'orig'));
    if (r) djAnalyseMono(x.id, r.mono, r.sr);
    else { const sk = LSJ.get('anaskip', {}); sk[x.id] = 1; LSJ.set('anaskip', sk); }   // fichier trop long : ignoré
  } catch { const sk = LSJ.get('anaskip', {}); sk[x.id] = 1; LSJ.set('anaskip', sk); }
  anaBusy = false;
  djRenderLib(true); djRenderSet(); DJ.d.forEach(djMeta);
}
setInterval(djAnalyseLibrary, 1500);

/* ---------- Bibliothèque de l'onglet Mix ---------- */
let djLibKey = '';
function djRenderLib(force){
  if ($('#v-dj').hidden || !state) return;
  const f = ($('#djq').value || '').toLowerCase(), info = LSJ.get('djinfo', {});
  const rows = (state.history || []).filter(x => x.exists && (!f || (x.title + ' ' + x.uploader).toLowerCase().includes(f)));
  const key = JSON.stringify(rows.map(x => [x.id, x.voix, x.instru])) + f + DJ.d.map(d => d.id).join() + JSON.stringify(info) + SET.ids.join();
  if (!force && key === djLibKey) return; djLibKey = key;
  $('#djlib').innerHTML = rows.length ? rows.map(x => `<div class="item djrow">${thumb(x.vid, x.duration, false, x.thumb)}
      <div class="meta"><div class="t">${esc(x.title)}</div><div class="s">${esc(x.uploader)}${info[x.id] && info[x.id].bpm ? `<span class="tag">${fr1(info[x.id].bpm)} BPM</span>` : ''}${info[x.id] && info[x.id].key && info[x.id].key.cam ? `<span class="tag key" title="${esc(info[x.id].key.name)}">${info[x.id].key.cam}</span>` : ''}${x.voix || x.instru ? '<span class="tag">Voix / Instru</span>' : ''}</div></div>
      <div class="acts"><button class="ab plus ${SET.ids.includes(x.id) ? 'on' : ''}" data-setadd="${x.id}" title="${SET.ids.includes(x.id) ? 'Retirer de' : 'Ajouter à'} la liste de soirée">${SET.ids.includes(x.id) ? '✓' : '+'}</button><button class="ab a ${DJ.d[0].id === x.id ? 'on' : ''}" data-load="0" data-id="${x.id}" title="Charger sur la platine A">A</button><button class="ab b ${DJ.d[1].id === x.id ? 'on' : ''}" data-load="1" data-id="${x.id}" title="Charger sur la platine B">B</button></div></div>`).join('')
    : `<div class="empty">${I.note}<div>${f ? 'Aucun résultat' : 'Télécharge des morceaux pour les mixer ici'}</div></div>`;
}
$('#djq').oninput = () => djRenderLib(true);
$('#djlib').onclick = e => {
  const s = e.target.closest('[data-setadd]'); if (s) { setAdd(s.dataset.setadd); return; }
  const b = e.target.closest('[data-load]'); if (b) djLoad(+b.dataset.load, b.dataset.id);
};

/* --- Onglets --- */
function show(tab){
  document.querySelectorAll('.tabs button').forEach(b => b.classList.toggle('on', b.dataset.tab === tab));
  $('#v-main').hidden = tab !== 'main';
  $('#v-set').hidden = tab !== 'set';
  $('#v-dj').hidden = tab !== 'dj';
  document.body.classList.toggle('dj-mode', tab === 'dj');
  if (tab === 'dj') { djRenderLib(true); setKey = ''; djRenderSet(); }
}
document.querySelector('.tabs').onclick = e => { const b = e.target.closest('button'); if (b) show(b.dataset.tab); };

/* --- Paramètres --- */
async function saveSettings(body, okMsg){
  try {
    const s = await api('/api/settings', body);
    if (s.error){ toast(s.error, 'err'); return; }
    render(s); if (okMsg) toast(okMsg, 'ok');
  } catch(e){ toast(e.message, 'err'); }
}
$('#saveDir').onclick = () => saveSettings({outDir: $('#dir').value}, 'Dossier enregistré');
$('#dir').onkeydown = e => { if (e.key === 'Enter') $('#saveDir').click(); };
$('#resetDir').onclick = () => saveSettings({reset: true}, 'Dossier par défaut rétabli');
$('#openDir').onclick = () => api('/api/folder', {});
$('#pick').onclick = async () => {
  const before = state && state.settings.outDir;
  try { const s = await api('/api/pickfolder', {}); render(s); if (s.settings.outDir !== before) toast('Dossier enregistré', 'ok'); }
  catch(e){ toast(e.message, 'err'); }
};
$('#qmode').onclick = e => {
  const b = e.target.closest('button'); if (!b) return;
  saveSettings({quality: b.dataset.m}, b.dataset.m === 'auto' ? 'Qualité automatique activée' : `Qualité fixée à ${b.dataset.m} kbps`);
};
const OPT_LABEL = {trim:'Ne garder que la musique', normalize:'Volume homogène', clean:'Noms et pochettes propres'};
document.querySelectorAll('.opt[data-src]').forEach(o => o.onclick = () => {
  const on = !o.classList.contains('on');
  const list = [...document.querySelectorAll('.opt[data-src]')].filter(x => x === o ? on : x.classList.contains('on')).map(x => x.dataset.src);
  if (!list.length) { toast('Garde au moins une source active', 'err'); return; }
  o.classList.toggle('on', on);
  saveSettings({sources: list}, `${o.querySelector('b').textContent} : ${on ? 'activé' : 'désactivé'}`);
});
document.querySelectorAll('.opt[data-opt]').forEach(o => o.onclick = () => {
  const k = o.dataset.opt, on = !o.classList.contains('on');
  o.classList.toggle('on', on);
  saveSettings({[k]: on}, `${OPT_LABEL[k]} : ${on ? 'activé' : 'désactivé'}`);
});
$('#ck').onclick = e => {
  const b = e.target.closest('button'); if (!b) return;
  saveSettings({cookies: b.dataset.c}, b.dataset.c === 'firefox' ? 'Session Firefox activée' : 'Connexion désactivée');
};

/* --- Actions --- */
$('#folder').onclick = () => api('/api/folder', {});
$('#q').oninput = e => { filter = e.target.value.toLowerCase(); libKey = ''; render(state); };
document.body.addEventListener('click', async e => {
  if (e.target.closest('[data-goto]')) { show('set'); return; }
  const b = e.target.closest('[data-act]'); if (!b) return;
  e.stopPropagation();
  const act = b.dataset.act, id = b.dataset.id;
  // Lecture dans le lecteur intégré
  if (act === 'play') { playFrom(id, 'orig'); return; }
  if (act === 'playstem') { playFrom(id, b.dataset.stem); return; }
  if (act === 'setup') toast('Mise à jour en cours…');
  if (act === 'separate' && state && state.separation && state.separation.state !== 'pret'){
    show('set'); setTimeout(() => $('#sepcard').scrollIntoView({behavior:'smooth'}), 50);
    toast('Installe d\'abord le module de séparation'); return;
  }
  if (act === 'sepinstall') toast('Installation du module lancée');
  if (act === 'gpuinstall') toast('Téléchargement de la version carte graphique lancé');
  if (act === 'checkupdate') { updKey = ''; }
  if (act === 'delete' && !confirm('Envoyer ce MP3 à la corbeille ?')) return;
  if (act === 'split') {
    const x = byId(id), n = x && x.chapters >= 2 ? `${x.chapters} morceaux` : 'morceaux (selon les chapitres de la vidéo)';
    if (!confirm(`Découper « ${x ? x.title : ''} » en ${n} ?\n\nLe fichier d'origine reste intact : les morceaux sont créés dans un dossier à part.`)) return;
  }
  try { const s = await api('/api/' + act, {id, stem: b.dataset.stem}); if (s && s.setup) render(s); }
  catch(err){ toast(err.message, 'err'); }
});

/* --- Rendu --- */
const label = {attente:'En attente', analyse:'Analyse de la source', telechargement:'Téléchargement', conversion:'Conversion MP3', erreur:'Erreur'};
function render(s){
  if (!s) return;
  state = s;

  // Installation
  const ov = $('#ov');
  if (s.setup === 'installation'){
    ov.classList.add('show');
    $('#ovbox').innerHTML = `<div class="spin"></div><h3>Préparation du premier lancement</h3><p>Installation des outils de conversion (environ 200 Mo, une seule fois).</p><p style="margin-top:10px;color:var(--text)">${s.setupMb ? s.setupMb + ' Mo téléchargés' : 'Démarrage…'}</p>`;
  } else if (s.setup === 'erreur'){
    ov.classList.add('show');
    $('#ovbox').innerHTML = `<h3>Installation impossible</h3><p>${esc(s.setupError || 'Vérifie ta connexion Internet.')}</p><button class="go" data-act="setup">${I.retry}Réessayer</button>`;
  } else if (!updating) ov.classList.remove('show');

  renderUpdate(s);
  maybeOfferUpdate(s);
  if (s.appVersion) renderAbout(s.appVersion);
  renderSepCard(s.separation || {});
  renderPl(s.playlist || {}); renderFollows(s); renderNews(s.news || []); renderExport(s.export || {});
  renderSearch(s.search);
  djRenderLib(false); djRenderSet();

  // Paramètres
  const st = s.settings || {};
  if (document.activeElement !== $('#dir')) $('#dir').value = st.outDir || '';
  $('#resetDir').hidden = !st.outDir || st.outDir === st.defaultDir;
  document.querySelectorAll('#ck button').forEach(b => b.classList.toggle('on', b.dataset.c === st.cookies));
  document.querySelectorAll('.opt[data-opt]').forEach(o => o.classList.toggle('on', !!st[o.dataset.opt]));
  document.querySelectorAll('.opt[data-src]').forEach(o => o.classList.toggle('on', (st.sources || []).includes(o.dataset.src)));
  document.querySelectorAll('#qmode button').forEach(b => b.classList.toggle('on', b.dataset.m === st.quality));
  $('#qinfo span').textContent = (st.quality === 'auto' ? 'Qualité adaptée à la source' : `Qualité fixée à ${st.quality} kbps`)
    + (st.trim ? ' · musique seule' : '') + (st.normalize ? ' · volume homogène' : '');
  $('#ver').textContent = s.setup === 'maj' ? 'Mise à jour en cours…'
    : `yt-dlp ${s.version || ''} — mis à jour automatiquement à chaque lancement.`;

  // File d'attente
  const q = s.queue || [];
  $('#qsec').hidden = !q.length;
  $('#qcount').textContent = q.length ? q.length : '';
  $('#queue').innerHTML = q.map(it => {
    const id = it.vid || ytId(it.url);
    const err = it.status === 'erreur';
    const pct = it.status === 'telechargement' ? ` · ${String(it.progress).replace('.', ',')} %` : '';
    const hint = err && it.blocked && st.cookies !== 'firefox' ? `<button class="lnk" style="color:var(--a1);margin-left:8px" data-goto="set">Activer la session Firefox</button>` : '';
    const sub = err ? `<span class="st err">${esc(it.error)}</span>${hint}`
              : `${esc(it.uploader || it.url)}${qtag(it)}${it.attempt ? `<span class="tag">Tentative ${it.attempt + 1}/${it.tries}</span>` : ''}`;
    const ind = it.status === 'conversion' || it.status === 'analyse' || (it.status === 'telechargement' && !it.progress);
    const bar = (it.status === 'telechargement' || it.status === 'conversion' || it.status === 'analyse')
      ? `<div class="bar ${ind ? 'ind' : ''}"><i style="width:${it.progress}%"></i></div>` : '';
    const acts = err
      ? `<button class="ib" data-act="retry" data-id="${it.id}" title="Réessayer">${I.retry}</button><button class="ib" data-act="dismiss" data-id="${it.id}" title="Retirer">${I.x}</button>`
      : `<button class="ib del" data-act="cancel" data-id="${it.id}" title="Annuler">${I.x}</button>`;
    return `<div class="item">${thumb(id, it.duration, false, it.thumb)}<div class="meta"><div class="t">${esc(it.title || (it.status === 'attente' ? 'Dans la file d\'attente' : 'Analyse en cours…'))}</div><div class="s">${sub}</div>${bar}</div>${err ? '' : `<span class="st">${label[it.status]}${pct}</span>`}<div class="acts">${acts}</div></div>`;
  }).join('');

  // Bibliothèque
  const h = s.history || [];
  const total = h.reduce((a, x) => a + (x.exists ? x.size : 0), 0);
  $('#stats').textContent = h.length ? `${h.length} titre${h.length > 1 ? 's' : ''} · ${mb(total)}` : 'Bibliothèque vide';
  $('#hcount').textContent = h.length || '';
  const key = JSON.stringify(h) + filter + '|' + (P.id || '') + (P.playing ? 1 : 0);
  if (key === libKey) return;
  libKey = key;
  const rows = h.filter(x => !filter || (x.title + ' ' + x.uploader).toLowerCase().includes(filter));
  $('#lib').innerHTML = rows.length ? rows.map(x => `
    <div class="item ${x.exists ? '' : 'missing'} ${P.id === x.id ? 'playing' : ''}" ${x.exists ? `data-act="play" data-id="${x.id}" style="cursor:pointer"` : ''}>
      ${thumb(x.vid, x.duration, x.exists, x.thumb).replace('</div>', P.id === x.id ? `</div><div class="eq ${P.playing ? '' : 'paused'}"><i></i><i></i><i></i></div>` : '</div>')}
      <div class="meta"><div class="t">${esc(x.title)}</div>
        <div class="s">${esc(x.uploader)}<span class="dot">•</span>${x.exists ? mb(x.size) : 'Fichier introuvable'}<span class="dot">•</span>${esc(x.date)}${qtag(x)}${x.splitDir ? '<span class="tag">Découpée</span>' : ''}${x.part ? `<span class="tag">Piste ${x.part}</span>` : ''}</div>${sepHtml(x)}${splitHtml(x)}</div>
      <div class="acts">
        ${canSplit(x) && !x.split ? `<button class="ib" data-act="split" data-id="${x.id}" title="Découper cette mixtape en morceaux (l'original reste intact)">${I.cut}</button>` : ''}
        ${x.exists && !x.sep && !(x.voix && x.instru) ? `<button class="ib" data-act="separate" data-id="${x.id}" title="Séparer voix / instrumental">${I.split}</button>` : ''}
        ${x.exists ? `<button class="ib" data-act="reveal" data-id="${x.id}" title="Afficher dans le dossier">${I.reveal}</button>` : ''}
        <button class="ib del" data-act="${x.exists ? 'delete' : 'forget'}" data-id="${x.id}" title="${x.exists ? 'Supprimer' : 'Retirer de la liste'}">${x.exists ? I.trash : I.x}</button>
      </div>
    </div>`).join('')
    : `<div class="empty">${I.note}<div>${filter ? 'Aucun résultat' : 'Tes MP3 apparaîtront ici'}</div></div>`;
}

/* --- Playlists YouTube --- */
let plOpen = false, plKey = '';
function renderPl(p){
  const box = $('#plbox2');
  $('#pldlg').classList.toggle('show', plOpen && p.status && p.status !== 'vide');
  if (!plOpen || !p.status || p.status === 'vide') return;
  const k = JSON.stringify(p); if (k === plKey) return; plKey = k;
  if (p.status === 'lecture') { box.innerHTML = `<div class="spin"></div><h3>Lecture de la playlist…</h3><p>YT MP3 récupère la liste des titres.</p><div class="dlg-btns"><button class="btn-ghost" id="plno">Annuler</button></div>`; return; }
  if (p.status === 'erreur') {
    box.innerHTML = `<h3 style="margin-top:0">Playlist illisible</h3><p>Cette playlist est privée, vide ou introuvable.${p.single ? ' Tu peux quand même télécharger le titre seul.' : ''}</p>
      <div class="dlg-btns"><button class="btn-ghost" id="plno">Fermer</button>${p.single ? '<button class="go" data-pl="one">Ce titre seulement</button>' : ''}</div>`;
    return;
  }
  const canFollow = !p.radio && p.listId;
  box.innerHTML = `<div class="dlg-ic">${I.note}</div><h3>${esc(p.title)}</h3>
    <p>${p.count} titre${p.count > 1 ? 's' : ''}${p.radio ? ' · mix généré par YouTube (limité aux 25 premiers)' : ''}</p>
    <div class="plsample">${(p.sample || []).map(t => `<i>${esc(t)}</i>`).join('')}${p.count > 5 ? `<i>… et ${p.count - 5} autre${p.count - 5 > 1 ? 's' : ''}</i>` : ''}</div>
    ${canFollow ? (p.followed ? `<p style="margin-top:12px;color:var(--ok)">✓ Tu suis déjà cette playlist.</p>` :
      `<label class="chk"><input type="checkbox" id="plfollow"><span>Suivre cette playlist<small>(les prochains titres ajoutés seront téléchargés tout seuls)</small></span></label>`) : ''}
    <div class="dlg-choice">
      <button class="go" data-pl="all">Télécharger toute la playlist (${p.count})</button>
      ${p.single ? '<button class="btn-ghost" data-pl="one">Ce titre seulement</button>' : ''}
      ${canFollow && !p.followed ? '<button class="btn-ghost" data-pl="follow">Suivre sans télécharger l\'existant</button>' : ''}
      <button class="lnk" id="plno" style="align-self:center;margin-top:4px">Annuler</button>
    </div>`;
}
$('#pldlg').addEventListener('click', async e => {
  if (e.target.closest('#plno')) { plOpen = false; $('#pldlg').classList.remove('show'); try { render(await api('/api/plclose', {})); } catch {} return; }
  const b = e.target.closest('[data-pl]'); if (!b) return;
  const p = state.playlist || {}, f = $('#plfollow');
  const body = b.dataset.pl === 'all' ? { all: true, follow: !!(f && f.checked) } : b.dataset.pl === 'follow' ? { all: false, follow: true } : { all: false, follow: false };
  plOpen = false; $('#pldlg').classList.remove('show');
  try {
    render(await api('/api/addplaylist', body));
    toast(body.all ? `${p.count} titres ajoutés à la file` : body.follow ? `Playlist « ${p.title} » suivie` : 'Ajouté à la file');
    if (body.all && body.follow) toast(`Playlist « ${p.title} » suivie`, 'ok');
  } catch(err){ toast(err.message, 'err'); }
});
let fwKey = '';
function renderFollows(s){
  const f = s.follows || [], k = JSON.stringify(f) + s.followBusy; if (k === fwKey) return; fwKey = k;
  $('#plbox').innerHTML = !f.length ? `<p style="margin:12px 0 0;color:var(--muted)">Aucune playlist suivie pour l'instant.</p>` :
    f.map(x => `<div class="fwrow"><div class="ft"><b>${esc(x.title)}</b><span>${x.count} titre${x.count > 1 ? 's' : ''} connus · vérifiée le ${esc(x.last || '—')}</span></div>
      <button class="lnk" data-unfollow="${esc(x.listId)}">Ne plus suivre</button></div>`).join('') +
    `<div class="row" style="margin-top:12px"><button class="btn-ghost" id="fwcheck" ${s.followBusy ? 'disabled' : ''}>${s.followBusy ? 'Vérification…' : 'Vérifier maintenant'}</button></div>`;
}
$('#plbox').addEventListener('click', async e => {
  const u = e.target.closest('[data-unfollow]');
  if (u) { if (!confirm('Ne plus suivre cette playlist ? Les titres déjà téléchargés restent dans ta bibliothèque.')) return; try { render(await api('/api/unfollow', {listId: u.dataset.unfollow})); toast('Playlist retirée'); } catch(err){ toast(err.message, 'err'); } return; }
  if (e.target.closest('#fwcheck')) { try { render(await api('/api/followcheck', {})); toast('Vérification des playlists lancée'); } catch(err){ toast(err.message, 'err'); } }
});
let newsSeen = null;
function renderNews(n){
  const last = n.length ? n[n.length - 1].n : 0;
  if (newsSeen !== null) for (const x of n) if (x.n > newsSeen) toast(x.text, 'ok');
  newsSeen = Math.max(newsSeen || 0, last);
}

/* --- Découpage d'une mixtape (uniquement sur demande) --- */
const secsOf = d => String(d || '').split(':').reduce((a, v) => a * 60 + (+v || 0), 0);
const canSplit = x => x.exists && x.vid && !x.fromMix && !x.splitDir && (x.chapters >= 2 || (x.chapters == null && secsOf(x.duration) >= 600));
function splitHtml(x){
  const sp = x.split;
  if (sp) {
    if (sp.status === 'erreur') return `<div class="sepline err">${esc(sp.error)}<button class="lnk" data-act="splitcancel" data-id="${x.id}">OK</button></div>`;
    const txt = sp.status === 'attente' ? 'Découpage en attente…' : sp.status === 'analyse' ? 'Lecture des chapitres…'
      : sp.status === 'telechargement' ? `Préparation des ${sp.total} morceaux… ${sp.progress} %` : `Morceau ${Math.min(sp.done + 1, sp.total)} sur ${sp.total}`;
    const pct = sp.status === 'decoupe' ? Math.round(sp.done * 100 / sp.total) : sp.status === 'telechargement' ? sp.progress : 0;
    return `<div class="sepline">${txt}<div class="bar ${pct ? '' : 'ind'}"><i style="width:${pct}%"></i></div><button class="lnk" data-act="splitcancel" data-id="${x.id}">Annuler</button></div>`;
  }
  return '';
}

/* --- Export clé USB --- */
let exSel = [];
const exItems = () => (state.history || []).filter(x => x.exists);
function exRender(){
  const items = exItems(), sel = new Set(exSel);
  const ordered = [...exSel.map(id => items.find(x => x.id === id)).filter(Boolean), ...items.filter(x => !sel.has(x.id))];
  $('#exlist').innerHTML = ordered.map(x => `<label><input type="checkbox" data-exid="${x.id}" ${sel.has(x.id) ? 'checked' : ''}><span>${sel.has(x.id) ? `<em>${exSel.indexOf(x.id) + 1}.</em> ` : ''}${esc(x.title)} <em>· ${esc(x.uploader)}</em></span><em>${mb(x.size)}</em></label>`).join('')
    || '<div class="empty" style="padding:20px">Bibliothèque vide</div>';
  const tot = exSel.reduce((a, id) => a + ((items.find(x => x.id === id) || {}).size || 0), 0);
  $('#exsum').textContent = `${exSel.length} titre${exSel.length > 1 ? 's' : ''} sélectionné${exSel.length > 1 ? 's' : ''} · ${mb(tot)}`;
}
$('#usbbtn').innerHTML = I.usb + 'Clé USB';
$('#usbbtn').onclick = () => {
  exSel = []; try { const d = localStorage.getItem('exdir'); if (d) $('#exdir').value = d; } catch {}
  exRender(); renderExport(state.export || {}, true); $('#expdlg').classList.add('show');
};
$('#exlist').addEventListener('change', e => {
  const c = e.target.closest('[data-exid]'); if (!c) return;
  exSel = c.checked ? [...exSel, c.dataset.exid] : exSel.filter(x => x !== c.dataset.exid); exRender();
});
document.querySelector('.expre').addEventListener('click', e => {
  const b = e.target.closest('[data-ex]'); if (!b) return;
  const items = exItems();
  exSel = b.dataset.ex === 'all' ? items.map(x => x.id) : b.dataset.ex === 'set' ? SET.ids.filter(id => items.some(x => x.id === id)) : [];
  if (b.dataset.ex === 'set' && !exSel.length) toast('Ta liste de soirée est vide (onglet Mix)', 'err');
  exRender();
});
$('#expick').onclick = async () => { try { const r = await api('/api/pickdir', {}); if (r.dir) $('#exdir').value = r.dir; } catch(err){ toast(err.message, 'err'); } };
$('#exclose').onclick = async () => { $('#expdlg').classList.remove('show'); if (state.export && /fini|erreur/.test(state.export.status)) try { render(await api('/api/exportdone', {})); } catch {} };
$('#exgo').onclick = async () => {
  const dest = $('#exdir').value.trim().replace(/^"|"$/g, '');
  if (!exSel.length) return toast('Coche au moins un titre', 'err');
  if (!dest) return toast('Choisis la clé USB ou le dossier de destination', 'err');
  try { localStorage.setItem('exdir', dest); } catch {}
  try { const r = await api('/api/export', { ids: exSel, dest, numbered: $('#exnum').checked, ascii: $('#exascii').checked }); if (r.error) toast(r.error, 'err'); else render(r); }
  catch(err){ toast(err.message, 'err'); }
};
function renderExport(x, force){
  const st = x.status || 'vide', busy = st === 'copie';
  $('#exgo').disabled = busy; $('#exgo').textContent = busy ? 'Copie en cours…' : 'Copier';
  $('#exprog').innerHTML = st === 'vide' ? '' : st === 'copie'
    ? `<div class="sepline" style="margin-top:14px">Copie ${x.done} / ${x.total}<div class="bar"><i style="width:${Math.round(x.done * 100 / Math.max(1, x.total))}%"></i></div></div>`
    : st === 'fini' ? `<p style="margin-top:14px;color:var(--ok)">✓ ${x.total} titre${x.total > 1 ? 's copiés' : ' copié'}. Tu peux retirer la clé en toute sécurité depuis la barre des tâches.</p>`
    : `<p style="margin-top:14px;color:var(--err)">${esc(x.error)}</p>`;
}

/* --- Notifications de fin --- */
let known = null;
function notifyDone(s){
  const ids = new Set((s.history || []).map(x => x.id));
  if (known) for (const x of s.history || []) if (!known.has(x.id) && !x.fromMix) toast('✓ ' + x.title, 'ok');
  known = ids;
}

/* --- Connexion au moteur : détection d'arrêt et relance --- */
let down = false;
function setDown(v){
  if (v && updatePlanned && !updating) { showUpdating(state && state.update ? state.update.latest : ''); return; }
  if (updating) return;
  if (v === down) return;
  down = v;
  $('#down').classList.toggle('show', v);
  if (!v) toast('YT MP3 est de nouveau connecté', 'ok');
}
$('#relaunch').onclick = () => {
  $('#downMsg').textContent = 'Relance en cours… Si Windows demande l\'autorisation d\'ouvrir YT MP3, accepte.';
  location.href = 'ytmp3://relancer';
};
async function poll(){
  try { const s = await api('/api/state'); setDown(false); notifyDone(s); render(s); } catch {}
  setTimeout(poll, down ? 1500 : 900);
}
poll();
window.addEventListener('pagehide', () => { try { navigator.sendBeacon('/api/bye'); } catch {} });
</script>
</body>
</html>
'@

# =====================================================================
#  Installation / mise à jour des outils (en arrière-plan)
# =====================================================================
$script:setupJob   = $null
$script:setupError = ''

function Start-Setup {
    $script:setupError = ''
    $script:setupJob = Start-Job -ArgumentList $Bin -ScriptBlock {
        param($Bin)
        $ErrorActionPreference = 'Continue'
        function Get-Zip($url, $name, $exe) {
            $zip = Join-Path $Bin "$name.zip"
            $tmp = Join-Path $Bin "$name-tmp"
            & curl.exe -L --fail -s -o $zip $url
            if ($LASTEXITCODE -ne 0) { throw "Téléchargement de $name impossible." }
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
            [void](New-Item -ItemType Directory -Path $tmp)
            & tar.exe -xf $zip -C $tmp
            if ($LASTEXITCODE -ne 0) { throw "Extraction de $name impossible." }
            Get-ChildItem -LiteralPath $tmp -Recurse -Filter $exe | Move-Item -Destination $Bin -Force
            Remove-Item -LiteralPath $tmp -Recurse -Force
            Remove-Item -LiteralPath $zip -Force
        }

        $y = Join-Path $Bin 'yt-dlp.exe'
        # Version "nightly" : la plus réactive face aux changements de YouTube
        if (Test-Path -LiteralPath $y) { & $y --update-to nightly | Out-Null }
        else {
            & curl.exe -L --fail -s -o "$y.part" 'https://github.com/yt-dlp/yt-dlp-nightly-builds/releases/latest/download/yt-dlp.exe'
            if ($LASTEXITCODE -ne 0) { throw 'Téléchargement de yt-dlp impossible.' }
            Move-Item -LiteralPath "$y.part" -Destination $y -Force
        }
        if (-not (Test-Path -LiteralPath (Join-Path $Bin 'deno.exe'))) {
            Get-Zip 'https://github.com/denoland/deno/releases/latest/download/deno-x86_64-pc-windows-msvc.zip' 'deno' 'deno.exe'
        }
        if (-not (Test-Path -LiteralPath (Join-Path $Bin 'ffmpeg.exe'))) {
            Get-Zip 'https://github.com/yt-dlp/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip' 'ffmpeg' 'ff*.exe'
        }
        try { (& $y --version | Select-Object -First 1) | Set-Content -LiteralPath (Join-Path $Bin 'data\version.txt') -Encoding UTF8 } catch {}
    }
}

function Get-Version {
    if (Test-Path -LiteralPath $VersionFile) { try { $v = (Get-Content -LiteralPath $VersionFile -Raw).Trim(); if ($v -match '^\d{4}\.') { return $v } } catch {} }
    return ''
}

function Get-SetupState {
    $tools = (Test-Path -LiteralPath $YtDlp) -and (Test-Path -LiteralPath $Ffmpeg) -and (Test-Path -LiteralPath $Deno)
    $job = $script:setupJob
    if ($job -and $job.State -eq 'Running') { if ($tools) { return 'maj' } else { return 'installation' } }
    if ($tools) { return 'pret' }
    if ($job -and $job.State -eq 'Failed' -and -not $script:setupError) {
        try { $script:setupError = $job.ChildJobs[0].JobStateInfo.Reason.Message } catch {}
        if (-not $script:setupError) { $script:setupError = 'Vérifie ta connexion Internet.' }
    }
    return 'erreur'
}

function Get-SetupMb {
    $total = 0
    foreach ($f in @("$YtDlp.part", (Join-Path $Bin 'deno.zip'), (Join-Path $Bin 'ffmpeg.zip'))) {
        if (Test-Path -LiteralPath $f) { $total += (Get-Item -LiteralPath $f).Length }
    }
    foreach ($f in @($YtDlp, $Deno, $Ffmpeg, (Join-Path $Bin 'ffprobe.exe'))) {
        if (Test-Path -LiteralPath $f) { $total += (Get-Item -LiteralPath $f).Length }
    }
    return [math]::Round($total / 1MB)
}

# =====================================================================
#  Historique
# =====================================================================
$history = New-Object System.Collections.ArrayList
if (Test-Path -LiteralPath $HistFile) {
    try {
        $arr = Get-Content -LiteralPath $HistFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($h in @($arr)) { if ($h) { [void]$history.Add($h) } }
    } catch {}
}
function Save-History {
    ConvertTo-Json -InputObject @($history) -Depth 4 | Set-Content -LiteralPath $HistFile -Encoding UTF8
}
function Find-Hist($id) { foreach ($h in $history) { if ($h.id -eq $id) { return $h } }; return $null }
function Get-HistPath($h) {
    if ($h.path) { return [string]$h.path }
    return (Join-Path $DefaultOut $h.file)   # anciennes entrées
}

# =====================================================================
#  File d'attente et téléchargements
# =====================================================================
$queue = New-Object System.Collections.ArrayList
$script:proc    = $null
$script:current = $null
$script:logFile = $null
$Inv = [Globalization.CultureInfo]::InvariantCulture
# Tentative 1 : clients par défaut, puis clients alternatifs si YouTube bloque (403)
$Clients = @('', 'youtube:player_client=tv,web_embedded', 'youtube:player_client=android_vr,web_safari')

function Find-Queue($id) { foreach ($q in $queue) { if ($q.id -eq $id) { return $q } }; return $null }
function Quote([string]$s) { '"' + ($s -replace '"', '\"') + '"' }

function Read-Shared([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    try {
        $fs = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
        $txt = $sr.ReadToEnd()
        $sr.Close()
        return ($txt -split "`r?`n")
    } catch { return @() }
}

# Débit MP3 minimal pour conserver toute la qualité de la source (au-delà, le fichier grossit pour rien)
function Get-Target([string]$abr, [string]$codec) {
    $a = 0.0
    if (-not [double]::TryParse($abr, [Globalization.NumberStyles]::Float, $Inv, [ref]$a) -or $a -le 0) { return 192 }
    $factor = 1.15                                   # AAC -> MP3
    if ($codec -match 'opus|vorbis') { $factor = 1.35 } # Opus est plus efficace que le MP3
    $need = $a * $factor
    foreach ($b in @(128, 160, 192, 256, 320)) { if ($b -ge $need) { return $b } }
    return 320
}
# Nettoyage « Meryl - Zoukamine Freestyle (Clip Officiel) [4K] » -> artiste + titre propres
$Junk = '(?i)\s*[\(\[\{][^\)\]\}]*\b(clip|officiel|officielle|official|vid[eé]o|audio|lyrics?|paroles|visuali[sz]er|hd|hq|4k|8k|1080p|720p|remaster(ed)?|explicit|music video|full album|mv)\b[^\)\]\}]*[\)\]\}]'
# Mention finale, avec ou sans séparateur : « … - Clip Officiel », « … " CLIP OFFICIEL », « … | Lyrics »
$JunkTail = '(?i)[\s\|/\p{Pd}]*\b(clip officiel|clip vid[eé]o officiel(le)?|official (music )?video|official clip|vid[eé]o officielle|audio officiel|official audio|lyrics?|paroles|visuali[sz]er)\s*$'
# Tous les tirets possibles (-, ‐, ‑, –, —, −…) comme séparateur « Artiste - Titre »
$Dash = '[\p{Pd}\u2212]'
function Clear-Text([string]$t) {
    $t = $t -replace $Junk, '' -replace $JunkTail, '' -replace '\s{2,}', ' '
    return $t.Trim().Trim('-', '|', '–', '—', ' ')
}
function Get-CleanMeta([string]$title, [string]$uploader, [string]$artist, [string]$track) {
    if ($artist -eq 'NA') { $artist = '' }
    if ($track -eq 'NA') { $track = '' }
    $artist = ($artist -split ',')[0].Trim()
    if ($artist -and $track) { return @($artist, (Clear-Text $track)) }
    $t = Clear-Text $title
    # « Artiste 1 - Artiste 2 - Artiste 3 " Titre " » : titre entre guillemets, artistes avant
    $q = [regex]::Match($t, '^(?<a>[^"“«]+?)\s*["“«]\s*(?<t>[^"”»]+?)\s*["”»]\s*$')
    if ($q.Success) {
        $arts = ($q.Groups['a'].Value -split "\s+$Dash\s+|\s*&\s*|\s+x\s+|,\s*" | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ', '
        if ($arts) { return @($arts, $q.Groups['t'].Value.Trim()) }
    }
    $m = [regex]::Match($t, "^(?<a>.+?)\s+$Dash\s+(?<t>.+)$")
    if ($m.Success) { return @($m.Groups['a'].Value.Trim(), $m.Groups['t'].Value.Trim().Trim('"', '“', '”', '«', '»', ' ')) }
    $u = $uploader -replace '(?i)\s*-\s*topic$', '' -replace '(?i)vevo$', '' -replace '(?i)\s+(officiel|officielle|official|music|musique)$', ''
    if ($artist) { $u = $artist }
    return @($u.Trim(), $t)
}
function Get-SafeName([string]$n) {
    $n = $n -replace '[<>:"/\\|?*\x00-\x1f]', '' -replace '\s{2,}', ' '
    $n = $n.Trim().TrimEnd('.', ' ')
    if ($n.Length -gt 150) { $n = $n.Substring(0, 150).Trim() }
    return $n
}
# Valeur littérale pour --parse-metadata (« @@ valeur:@@ (?P<meta_x>.+) »)
function Get-MetaArg([string]$v, [string]$field) {
    $v = $v -replace '%', '%%' -replace ':', '\:'
    return ('@@ ' + $v + ':@@ (?P<meta_' + $field + '>.+)')
}

function Get-CodecName([string]$c) {
    if ($c -match 'opus') { return 'Opus' }
    if ($c -match 'mp4a|aac') { return 'AAC' }
    if ($c -match 'vorbis') { return 'Vorbis' }
    if ($c -match 'mp3') { return 'MP3' }
    return ''
}

function Start-Next {
    if ($script:proc) { return }
    if ((Get-SetupState) -ne 'pret') { return }
    $item = $null
    foreach ($q in $queue) { if ($q.status -eq 'attente') { $item = $q; break } }
    if (-not $item) { return }

    $script:logFile = Join-Path $Data ('job-' + $item.id + '.log')
    $a = @('--encoding', 'utf-8', '--no-playlist', '-f', 'bestaudio/best')

    if (-not $item.analysed) {
        # Étape 1 : analyse de la piste audio source (sans téléchargement)
        $item.status = 'analyse'
        $item.phase = 'probe'
        $a += @('--simulate', '--print', '[A]%(abr)s|%(acodec)s|%(duration)s|%(artist)s|%(track)s|%(id)s|%(uploader)s|%(duration_string)s|%(thumbnail)s|%(title)s', '--print', '[C]%(chapters)j')
    } else {
        # Étape 2 : téléchargement et conversion
        $item.status = 'telechargement'
        $item.phase = 'download'
        $item.progress = 0
        $a += @(
            '--newline', '--progress', '--no-simulate', '--windows-filenames',
            '--retries', '5', '--fragment-retries', '5', '--force-overwrites',
            '--ffmpeg-location', $Bin,
            '-x', '--audio-format', 'mp3', '--audio-quality', ('{0}K' -f $item.quality),
            '--embed-thumbnail', '--embed-metadata', '--convert-thumbnails', 'jpg',
            '--progress-template', 'download:[P]%(progress.downloaded_bytes)s/%(progress.total_bytes,progress.total_bytes_estimate)s',
            '--print', 'before_dl:[I]%(id)s|%(uploader)s|%(duration_string)s|%(title)s',
            '--print', 'after_move:[F]%(filepath)s'
        )
        # Nom de fichier et tags propres + pochette carrée
        $outName = '%(title)s'
        $item.cleaned = [bool]($script:settings.clean -and $item.cleanTitle)
        if ($item.cleaned) {
            $a += @('--parse-metadata', (Get-MetaArg $item.cleanTitle 'title'))
            $base = $item.cleanTitle
            if ($item.cleanArtist) {
                $a += @('--parse-metadata', (Get-MetaArg $item.cleanArtist 'artist'))
                $base = $item.cleanArtist + ' - ' + $item.cleanTitle
            }
            $safe = Get-SafeName $base
            if ($safe) { $outName = $safe -replace '%', '%%' }
            $a += @('--postprocessor-args', 'ThumbnailsConvertor:-qmin 1 -q:v 1 -vf crop="''if(gt(ih,iw),iw,ih)'':''if(gt(iw,ih),ih,iw)''"')
        }
        $a += @('-o', (Join-Path (Get-Out) ($outName + '.%(ext)s')))

        # Ne garder que la musique : passages non musicaux (SponsorBlock) + silences de début/fin
        $af = @()
        $item.trimmed = [bool]$script:settings.trim
        if ($item.trimmed) {
            $a += @('--sponsorblock-remove', 'music_offtopic')
            $sil = 'silenceremove=start_periods=1:start_threshold=-50dB:start_silence=0.3'
            # La coupe de fin passe par une inversion du son en mémoire : réservée aux titres de moins de 15 min
            if ($item.seconds -gt 0 -and $item.seconds -le 900) { $af += "$sil,areverse,$sil,areverse" } else { $af += $sil }
        }
        $item.normalized = [bool]$script:settings.normalize
        if ($item.normalized) { $af += 'loudnorm=I=-14:TP=-1.5:LRA=11' }
        if ($af.Count) { $a += @('--postprocessor-args', ('ExtractAudio:-af ' + ($af -join ',') + ' -ar 44100')) }
    }
    # En cas de blocage YouTube, chaque nouvelle tentative passe par d'autres clients
    $client = $Clients[[math]::Min($item.attempt, $Clients.Count - 1)]
    if ($client) { $a += @('--extractor-args', $client) }
    if ($script:settings.cookies -eq 'firefox') { $a += @('--cookies-from-browser', 'firefox') }
    $a += $item.url
    $argLine = ($a | ForEach-Object { Quote $_ }) -join ' '
    $script:proc = Start-Process -FilePath $YtDlp -ArgumentList $argLine -NoNewWindow -PassThru `
        -RedirectStandardOutput $script:logFile -RedirectStandardError ($script:logFile + '.err')
    $null = $script:proc.Handle   # nécessaire pour lire ExitCode ensuite
    $script:current = $item
}

function Remove-JobLogs {
    foreach ($f in @($script:logFile, ($script:logFile + '.err'))) {
        try { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } catch {}
    }
}

function Update-Job {
    if (-not $script:proc) { Start-Next; return }
    $item = $script:current

    foreach ($l in (Read-Shared $script:logFile)) {
        if ($l.StartsWith('[A]')) {
            $p = $l.Substring(3) -split '\|', 10
            if ($p.Count -eq 10) {
                $item.srcAbrRaw = $p[0]; $item.srcCodecRaw = $p[1]
                $sec = 0.0
                if ([double]::TryParse($p[2], [Globalization.NumberStyles]::Float, $Inv, [ref]$sec)) { $item.seconds = [int]$sec }
                $item.rawArtist = $p[3]; $item.rawTrack = $p[4]
                $item.vid = $p[5]; $item.uploader = $p[6]; $item.duration = $p[7]; $item.title = $p[9]
                if ($p[8] -ne 'NA') { $item.thumb = $p[8] }
            }
        } elseif ($l.StartsWith('[C]')) {
            $item.chapters = ([regex]::Matches($l, '"start_time"')).Count
        } elseif ($l.StartsWith('[I]')) {
            $p = $l.Substring(3) -split '\|', 4
            if ($p.Count -eq 4 -and -not $item.title) { $item.vid = $p[0]; $item.uploader = $p[1]; $item.duration = $p[2]; $item.title = $p[3] }
        } elseif ($l.StartsWith('[P]')) {
            $n = $l.Substring(3) -split '/'
            $d = 0.0; $t = 0.0
            if ($n.Count -gt 1 -and
                [double]::TryParse($n[0], [Globalization.NumberStyles]::Float, $Inv, [ref]$d) -and
                [double]::TryParse($n[1], [Globalization.NumberStyles]::Float, $Inv, [ref]$t) -and $t -gt 0) {
                $item.progress = [math]::Min(100, [math]::Round($d * 100 / $t))
            }
        } elseif ($l.StartsWith('[F]')) {
            $item.file = $l.Substring(3).Trim()
        }
    }
    if ($item.status -eq 'telechargement' -and $item.progress -ge 100) { $item.status = 'conversion' }

    if (-not $script:proc.HasExited) { return }
    $code = $script:proc.ExitCode

    if ($item.phase -eq 'probe') {
        # Fin de l'analyse : on fixe le débit utile, puis on enchaîne sur le téléchargement.
        # Si l'analyse échoue, le téléchargement donnera l'erreur réelle (avec ses nouvelles tentatives).
        if ($item.status -ne 'annule') {
            $abr = 0.0
            if ([double]::TryParse([string]$item.srcAbrRaw, [Globalization.NumberStyles]::Float, $Inv, [ref]$abr) -and $abr -gt 0) {
                $item.srcAbr = [int][math]::Round($abr)
            }
            $item.srcCodec = Get-CodecName $item.srcCodecRaw
            if ($item.auto) { $item.quality = Get-Target $item.srcAbrRaw $item.srcCodecRaw }
            if ($script:settings.clean -and $item.title) {
                $cm = Get-CleanMeta $item.title $item.uploader $item.rawArtist $item.rawTrack
                $item.cleanArtist = $cm[0]; $item.cleanTitle = $cm[1]
                if ($item.cleanTitle) { $item.title = $item.cleanTitle; if ($item.cleanArtist) { $item.uploader = $item.cleanArtist } }
            }
            $item.analysed = $true
            $item.status = 'attente'
        }
    } elseif ($item.status -ne 'annule') {
        if ($code -eq 0 -and $item.file -and (Test-Path -LiteralPath $item.file)) {
            $fi = Get-Item -LiteralPath $item.file
            $h = [PSCustomObject]@{
                id = $item.id; vid = $item.vid; title = $item.title; uploader = $item.uploader
                duration = $item.duration; file = $fi.Name; path = $fi.FullName; size = $fi.Length; quality = $item.quality
                srcAbr = $item.srcAbr; srcCodec = $item.srcCodec; thumb = $item.thumb; normalized = $item.normalized; trimmed = $item.trimmed; cleaned = $item.cleaned
                chapters = $item.chapters; date = (Get-Date).ToString('dd/MM/yyyy HH:mm')
            }
            # Un même titre retéléchargé remplace l'ancienne entrée (même fichier)
            foreach ($old in @($history | Where-Object { (Get-HistPath $_) -eq $fi.FullName })) { $history.Remove($old) }
            [void]$history.Insert(0, $h)
            Save-History
            $queue.Remove($item)
        } else {
            $err = Read-Shared ($script:logFile + '.err') | Where-Object { $_ -match 'ERROR' } | Select-Object -Last 1
            if (-not $err) { $err = "Échec du téléchargement (code $code)" }
            $err = ($err -replace '^.*?ERROR:\s*', '' -replace '^\[[^\]]+\]\s*[\w-]+:\s*', '')
            $blocked = $err -match '403|Forbidden|Sign in|bot|PO Token|format is not available'
            if ($blocked -and $item.attempt -lt ($Clients.Count - 1)) {
                $item.attempt++
                $item.status = 'attente'   # relancée aussitôt avec d'autres clients
                $item.progress = 0
            } else {
                $item.status = 'erreur'
                $item.error = $err
                $item.blocked = $blocked
            }
        }
    }
    Remove-JobLogs
    $script:proc = $null
    $script:current = $null
    Start-Next
}

# =====================================================================
#  Recherche multi-sources (YouTube Music, YouTube, SoundCloud), lancées en parallèle
# =====================================================================
$script:search = @{ status = 'vide'; q = ''; count = 8; results = @(); sources = @{} }
$script:searchProcs = @{}
$script:searchRaw = @{}

function Stop-Searches {
    foreach ($pr in $script:searchProcs.Values) { if ($pr -and -not $pr.HasExited) { try { $pr.Kill() } catch {} } }
    $script:searchProcs = @{}
    $script:searchRaw = @{}
}

function Start-Search([string]$q, [int]$count = 8) {
    Stop-Searches
    $q = $q.Trim()
    if (-not $q) { $script:search = @{ status = 'vide'; q = ''; count = 8; results = @(); sources = @{} }; return }
    $script:search = @{ status = 'recherche'; q = $q; count = $count; results = @(); sources = @{} }
    if ((Get-SetupState) -eq 'installation' -or -not (Test-Path -LiteralPath $YtDlp)) { $script:search.status = 'erreur'; return }
    $tpl = '[S]%(id)s|%(duration_string)s|%(artists.0,artist,channel,uploader)s|%(webpage_url,url)s|%(thumbnails.-1.url,thumbnail)s|%(title)s'
    foreach ($src in $SourceNames.Keys) {
        if (@($script:settings.sources) -notcontains $src) { continue }
        $a = @('--encoding', 'utf-8', '--flat-playlist', '--no-warnings', '--print', $tpl)
        switch ($src) {
            'youtube'    { $a += ('ytsearch' + $count + ':' + $q) }
            'soundcloud' { $a += ('scsearch' + $count + ':' + $q) }
            'ytmusic'    { $a += @('--playlist-end', [string]$count, ('https://music.youtube.com/search?q=' + [uri]::EscapeDataString($q) + '#songs')) }
        }
        if ($script:settings.cookies -eq 'firefox' -and $src -ne 'soundcloud') { $a += @('--cookies-from-browser', 'firefox') }
        $script:search.sources[$src] = 'recherche'
        $script:searchProcs[$src] = Start-Proc $YtDlp $a (Join-Path $Data "recherche-$src.log")
    }
    if (-not $script:searchProcs.Count) { $script:search.status = 'aucun' }
}

# Clé de comparaison « artiste titre » pour repérer un même morceau sur deux sources
function Get-SongKey([string]$artist, [string]$title) {
    $cm = Get-CleanMeta $title $artist '' ''
    return (($cm[0] + ' ' + $cm[1]).ToLower() -replace '[^\p{L}\p{N}]', '')
}

function Merge-Search {
    $out = New-Object System.Collections.ArrayList
    $seenIds = @{}; $seenKeys = @{}
    foreach ($src in $SourceNames.Keys) {
        foreach ($r in @($script:searchRaw[$src])) {
            if (-not $r) { continue }
            $isYt = $src -ne 'soundcloud'
            # Un même morceau sur YouTube Music et YouTube est marqué « doublon » : masqué dans « Tout »
            # (version YouTube Music privilégiée), mais toujours visible dans l'onglet de sa source
            $dup = ($isYt -and $seenIds.ContainsKey($r.id)) -or ($src -eq 'youtube' -and $r.key -and $seenKeys.ContainsKey($r.key))
            if ($isYt) { $seenIds[$r.id] = $true }
            if ($src -eq 'ytmusic' -and $r.key) { $seenKeys[$r.key] = $true }
            $r | Add-Member -NotePropertyName dup -NotePropertyValue $dup -Force
            [void]$out.Add($r)
        }
    }
    $script:search.results = @($out)
}

function Update-Search {
    if (-not $script:searchProcs.Count) { return }
    $changed = $false
    foreach ($src in @($script:searchProcs.Keys)) {
        $pr = $script:searchProcs[$src]
        if (-not $pr.HasExited) { continue }
        $res = @()
        foreach ($l in (Read-Shared (Join-Path $Data "recherche-$src.log"))) {
            if (-not $l.StartsWith('[S]')) { continue }
            $p = $l.Substring(3) -split '\|', 6
            if ($p.Count -ne 6 -or $p[0] -eq 'NA' -or $p[5] -eq 'NA') { continue }
            $f = @($p | ForEach-Object { if ($_ -eq 'NA') { '' } else { $_ } })
            $url = $f[3]
            if ($src -ne 'soundcloud') {
                if ($f[0] -notmatch '^[\w-]{11}$') { continue }
                $url = 'https://www.youtube.com/watch?v=' + $f[0]
            } elseif ($url -notmatch '^https://soundcloud\.com/') { continue }
            $res += [PSCustomObject]@{
                src = $src; id = $f[0]; duration = $f[1]; channel = $f[2]; url = $url; thumb = $f[4]; title = $f[5]
                key = (Get-SongKey $f[2] $f[5])
            }
        }
        $script:searchRaw[$src] = $res
        $script:search.sources[$src] = $(if ($res.Count) { 'ok' } elseif ($pr.ExitCode -eq 0) { 'aucun' } else { 'erreur' })
        $script:searchProcs.Remove($src)
        $changed = $true
    }
    if (-not $changed) { return }
    Merge-Search   # les résultats s'affichent au fur et à mesure que chaque source répond
    if (-not $script:searchProcs.Count) {
        $st = @($script:search.sources.Values)
        $script:search.status = $(if (@($script:search.results | Where-Object { -not $_.dup }).Count) { 'ok' } elseif ($st -contains 'erreur' -and $st -notcontains 'aucun') { 'erreur' } else { 'aucun' })
    }
}

# =====================================================================
#  Séparation voix / instrumental (Demucs, module optionnel)
# =====================================================================
$script:sepJob = $null
$script:sepInstallError = ''
$sepQueue = New-Object System.Collections.ArrayList
$script:sepProc = $null
$script:sepCur = $null

function Start-SepInstall {
    $script:sepInstallError = ''
    $script:sepJob = Start-Job -ArgumentList $Bin, [bool]$script:gpuName, $TorchCuda -ScriptBlock {
        param($Bin, $gpu, $cudaIdx)
        $ErrorActionPreference = 'Continue'
        $env:TORCH_HOME = Join-Path $Bin 'modeles'
        $py = Join-Path $Bin 'python'
        $pyexe = Join-Path $py 'python.exe'
        $log = Join-Path $Bin 'data\separation-install.log'
        $stepFile = Join-Path $Bin 'data\separation-etape.txt'
        function Step($t) { Set-Content -LiteralPath $stepFile -Value $t -Encoding UTF8 }
        function Check($msg) {
            if ($LASTEXITCODE -ne 0) {
                # Remonte la dernière erreur de pip pour l'afficher dans l'application
                $last = Get-Content -LiteralPath $log -Tail 60 -ErrorAction SilentlyContinue |
                    Where-Object { $_ -match 'ERROR|Error:' } | Select-Object -Last 1
                if ($last) { $last = ' : ' + ($last -replace '^.*?(ERROR:?\s*)', '').Trim() }
                throw "$msg$last (détails : outils\data\separation-install.log)"
            }
        }

        if (-not (Test-Path -LiteralPath $pyexe)) {
            Step 'Téléchargement de Python…'
            $zip = Join-Path $Bin 'python.zip'
            & curl.exe -L --fail -s -o $zip 'https://www.python.org/ftp/python/3.12.10/python-3.12.10-embed-amd64.zip'
            Check 'Téléchargement de Python impossible'
            [void](New-Item -ItemType Directory -Path $py -Force)
            & tar.exe -xf $zip -C $py
            Check 'Extraction de Python impossible'
            Remove-Item -LiteralPath $zip -Force
            # Python « embarqué » : il faut activer site-packages pour pouvoir installer des modules
            $pth = Get-ChildItem -LiteralPath $py -Filter 'python*._pth' | Select-Object -First 1
            if ($pth) { (Get-Content -LiteralPath $pth.FullName) -replace '^#\s*import site', 'import site' | Set-Content -LiteralPath $pth.FullName -Encoding ASCII }
        }
        & $pyexe -m pip --version *> $null
        if ($LASTEXITCODE -ne 0) {
            Step 'Installation de pip…'
            $gp = Join-Path $py 'get-pip.py'
            & curl.exe -L --fail -s -o $gp 'https://bootstrap.pypa.io/get-pip.py'
            Check 'Téléchargement de pip impossible'
            & $pyexe $gp --no-warn-script-location *>> $log
            Check 'Installation de pip impossible'
        }
        # --only-binary : uniquement des paquets prêts à l'emploi (le Python embarqué ne sait pas compiler)
        $pipArgs = @('-m', 'pip', 'install', '--no-warn-script-location', '--disable-pip-version-check', '--only-binary=:all:')
        if ($gpu) {
            Step 'Installation de PyTorch pour carte NVIDIA (le plus long, environ 2,5 Go)…'
            & $pyexe @pipArgs torch==2.5.1 --index-url $cudaIdx *>> $log
            Check 'Installation de PyTorch impossible'
        } else {
            Step 'Installation de PyTorch (le plus long, environ 250 Mo)…'
            & $pyexe @pipArgs torch==2.5.1 *>> $log
            Check 'Installation de PyTorch impossible'
        }
        Step 'Installation de Demucs…'
        & $pyexe @pipArgs demucs==4.1.0 numpy *>> $log
        Check 'Installation de Demucs impossible'
        Step 'Téléchargement du modèle de séparation…'
        & $pyexe -c "from demucs.pretrained import get_model; get_model('htdemucs')" *>> $log
        Check 'Téléchargement du modèle impossible'
        if ($gpu) {
            $r = & $pyexe -c "import torch; print('OK|' + torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'NON')" 2>> $log
            if ("$r" -like 'OK|*') { Set-Content -LiteralPath (Join-Path $py 'gpu-ok.txt') -Value ("$r".Substring(3)) -Encoding UTF8 }
        }
        Set-Content -LiteralPath (Join-Path $py 'demucs-ok.txt') -Value 'ok'
    }
}

# Passage d'un module déjà installé (version processeur) à la version carte graphique NVIDIA
$script:gpuJob = $null
$script:gpuError = ''
function Start-GpuInstall {
    $script:gpuError = ''
    $script:gpuJob = Start-Job -ArgumentList $Bin, $TorchCuda -ScriptBlock {
        param($Bin, $cudaIdx)
        $ErrorActionPreference = 'Continue'
        $pyexe = Join-Path $Bin 'python\python.exe'
        $log = Join-Path $Bin 'data\gpu-install.log'
        & $pyexe -m pip install --no-warn-script-location --disable-pip-version-check --only-binary=:all: --force-reinstall --no-deps torch==2.5.1 --index-url $cudaIdx *> $log
        if ($LASTEXITCODE -ne 0) {
            $last = Get-Content -LiteralPath $log -Tail 40 -ErrorAction SilentlyContinue | Where-Object { $_ -match 'ERROR' } | Select-Object -Last 1
            throw ('Téléchargement de PyTorch pour NVIDIA impossible' + $(if ($last) { ' : ' + ($last -replace '^.*?ERROR:?\s*', '').Trim() } else { '' }))
        }
        & $pyexe -m pip install --no-warn-script-location --disable-pip-version-check --only-binary=:all: torch==2.5.1 --index-url $cudaIdx --extra-index-url https://pypi.org/simple *>> $log
        $r = & $pyexe -c "import torch; print('OK|' + torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'NON')" 2>> $log
        if ("$r" -notlike 'OK|*') { throw 'Ta carte NVIDIA n''est pas reconnue : mets à jour son pilote (GeForce Experience ou nvidia.com/drivers), redémarre le PC puis réessaie.' }
        Set-Content -LiteralPath (Join-Path $Bin 'python\gpu-ok.txt') -Value ("$r".Substring(3)) -Encoding UTF8
    }
}
function Get-GpuState {
    if ($script:gpuJob -and $script:gpuJob.State -eq 'Running') { return 'installation' }
    if (Test-Path -LiteralPath $GpuMarker) { return 'pret' }
    if ($script:gpuJob -and $script:gpuJob.State -eq 'Failed') {
        if (-not $script:gpuError) { try { $script:gpuError = $script:gpuJob.ChildJobs[0].JobStateInfo.Reason.Message } catch {}; if (-not $script:gpuError) { $script:gpuError = 'Installation interrompue.' } }
        return 'erreur'
    }
    if ($script:gpuName) { return 'dispo' }
    return 'aucune'
}
function Get-GpuName { if (Test-Path -LiteralPath $GpuMarker) { try { $n = (Get-Content -LiteralPath $GpuMarker -Raw -Encoding UTF8).Trim(); if ($n) { return $n } } catch {} }; return $script:gpuName }

function Get-SepState {
    $job = $script:sepJob
    if ($job -and $job.State -eq 'Running') { return 'installation' }
    if (Test-Path -LiteralPath $SepMarker) { return 'pret' }
    if ($job -and $job.State -eq 'Failed') {
        if (-not $script:sepInstallError) {
            try { $script:sepInstallError = $job.ChildJobs[0].JobStateInfo.Reason.Message } catch {}
            if (-not $script:sepInstallError) { $script:sepInstallError = 'Installation interrompue.' }
        }
        return 'erreur'
    }
    return 'absent'
}
function Get-SepStep { if (Test-Path -LiteralPath $SepStepFile) { try { return (Get-Content -LiteralPath $SepStepFile -Raw -Encoding UTF8).Trim() } catch {} }; return '' }
function Find-Sep($id) { foreach ($q in $sepQueue) { if ($q.id -eq $id) { return $q } }; return $null }

function Start-Proc([string]$exe, [string[]]$a, [string]$log) {
    $argLine = ($a | ForEach-Object { Quote $_ }) -join ' '
    $pr = Start-Process -FilePath $exe -ArgumentList $argLine -NoNewWindow -PassThru `
        -RedirectStandardOutput $log -RedirectStandardError ($log + '.err')
    $null = $pr.Handle
    return $pr
}

# Encode une piste séparée en MP3 en reprenant les tags et la pochette de l'original
function Start-StemEncode($it, [string]$wav, [string]$out, [string]$label) {
    $h = Find-Hist $it.id
    $a = @('-y', '-loglevel', 'error', '-i', $wav, '-i', (Get-HistPath $h), '-map', '0:a', '-map', '1:v?',
        '-c:a', 'libmp3lame', '-b:a', ('{0}k' -f [int]$h.quality), '-c:v', 'copy', '-map_metadata', '1', '-id3v2_version', '3',
        '-metadata', ('title=' + $h.title + ' (' + $label + ')'), $out)
    $script:sepProc = Start-Proc $Ffmpeg $a (Join-Path $it.tmp 'ffmpeg.log')
}

function Start-NextSep {
    if ($script:sepProc -or (Get-SepState) -ne 'pret' -or (Get-GpuState) -eq 'installation') { return }
    $it = $null
    foreach ($q in $sepQueue) { if ($q.status -eq 'attente') { $it = $q; break } }
    if (-not $it) { return }
    $h = Find-Hist $it.id
    if (-not $h -or -not (Test-Path -LiteralPath (Get-HistPath $h))) { $it.status = 'erreur'; $it.error = 'Fichier introuvable'; return }
    $it.tmp = Join-Path $Data ('sep-' + $it.id)
    if (Test-Path -LiteralPath $it.tmp) { Remove-Item -LiteralPath $it.tmp -Recurse -Force }
    [void](New-Item -ItemType Directory -Path $it.tmp)
    $it.status = 'separation'; $it.phase = 'demucs'; $it.progress = 0
    if (-not $it.started) { $it.started = Get-Date }
    $it.gpu = [bool]((Get-GpuState) -eq 'pret' -and -not $it.cpuOnly)
    $a = @('-m', 'demucs', '--two-stems', 'vocals', '-n', 'htdemucs', '-o', $it.tmp, '--filename', '{stem}.{ext}')
    # Carte graphique : ~10 à 20 fois plus rapide. Sinon, recouvrement réduit (≈ 15 % plus rapide, différence inaudible).
    if ($it.gpu) { $a += @('-d', 'cuda') } else { $a += @('-d', 'cpu', '--overlap', '0.1') }
    $a += (Get-HistPath $h)
    $script:sepProc = Start-Proc $PyExe $a (Join-Path $it.tmp 'demucs.log')
    $script:sepCur = $it
}

function Update-Sep {
    if (-not $script:sepProc) { Start-NextSep; return }
    $it = $script:sepCur
    if ($it.phase -eq 'demucs') {
        # Progression de Demucs (barre tqdm sur la sortie d'erreur : « 45%| »)
        $txt = (Read-Shared (Join-Path $it.tmp 'demucs.log.err')) -join "`n"
        $m = [regex]::Matches($txt, '(\d{1,3})%\|')
        if ($m.Count) { $it.progress = [int]$m[$m.Count - 1].Groups[1].Value }
    }
    if (-not $script:sepProc.HasExited) { return }
    $code = $script:sepProc.ExitCode
    $script:sepProc = $null
    if ($it.status -eq 'annule') { $script:sepCur = $null; Remove-Item -LiteralPath $it.tmp -Recurse -Force -ErrorAction SilentlyContinue; Start-NextSep; return }

    $h = Find-Hist $it.id
    $orig = Get-HistPath $h
    $base = Join-Path ([IO.Path]::GetDirectoryName($orig)) ([IO.Path]::GetFileNameWithoutExtension($orig))
    $voix = $base + ' (Voix).mp3'
    $instru = $base + ' (Instrumental).mp3'
    $wavDir = Join-Path $it.tmp 'htdemucs'

    $fail = $null
    if ($code -ne 0 -and $it.phase -eq 'demucs' -and $it.gpu) {
        # Problème sur la carte graphique (mémoire insuffisante, pilote…) : on refait ce titre sur le processeur
        $it.cpuOnly = $true; $it.status = 'attente'; $it.progress = 0
        Remove-Item -LiteralPath $it.tmp -Recurse -Force -ErrorAction SilentlyContinue
        $script:sepCur = $null; Start-NextSep; return
    }
    if ($code -ne 0) {
        $logName = if ($it.phase -eq 'demucs') { 'demucs.log.err' } else { 'ffmpeg.log.err' }
        $err = (Read-Shared (Join-Path $it.tmp $logName)) | Where-Object { $_ -match 'Error|error' } | Select-Object -Last 1
        $fail = if ($err) { $err.Trim() } else { "La séparation a échoué (code $code)" }
    } elseif ($it.phase -eq 'demucs') {
        if (-not (Test-Path -LiteralPath (Join-Path $wavDir 'vocals.wav'))) { $fail = 'Demucs n''a produit aucun fichier' }
        else { $it.status = 'encodage'; $it.phase = 'voix'; Start-StemEncode $it (Join-Path $wavDir 'vocals.wav') $voix 'Voix'; return }
    } elseif ($it.phase -eq 'voix') {
        $it.phase = 'instru'; Start-StemEncode $it (Join-Path $wavDir 'no_vocals.wav') $instru 'Instrumental'; return
    } else {
        $h | Add-Member -NotePropertyName voix -NotePropertyValue $voix -Force
        $h | Add-Member -NotePropertyName instru -NotePropertyValue $instru -Force
        Save-History
        $sepQueue.Remove($it)
        $secs = [int]((Get-Date) - $it.started).TotalSeconds
        $dur = $(if ($secs -ge 60) { '{0} min {1:00} s' -f [math]::Floor($secs / 60), ($secs % 60) } else { "$secs s" })
        Add-News ("« $($h.title) » séparé en $dur" + $(if ($it.gpu) { ' (carte graphique)' } elseif ($it.cpuOnly) { ' (processeur : la carte graphique a échoué sur ce titre)' } else { '' }))
    }
    if ($fail) { $it.status = 'erreur'; $it.error = $fail }
    Remove-Item -LiteralPath $it.tmp -Recurse -Force -ErrorAction SilentlyContinue
    $script:sepCur = $null
    Start-NextSep
}

# =====================================================================
#  Mises à jour de YT MP3 depuis GitHub
#  Un fichier récupéré par PowerShell n'a pas la marque « téléchargé d'Internet » : aucune alerte Windows.
# =====================================================================
$script:upd = @{ state = 'inconnu'; latest = ''; error = ''; notes = @() }   # inconnu | verif | ajour | dispo | erreur
$script:lastUpdCheck = [datetime]::MinValue
$script:updateWhenIdle = $false   # « installer à la fin des téléchargements »
$UpdateEvery = 1800               # vérification toutes les 30 min tant que l'application est ouverte
if ($env:YTMP3_UPDATE_EVERY_SEC) { $UpdateEvery = [int]$env:YTMP3_UPDATE_EVERY_SEC }
function Test-Busy { return [bool]($script:proc -or $script:sepProc -or $script:splitCur -or $script:expJob -or @($queue | Where-Object { $_.status -eq 'attente' }).Count) }
$script:updJob = $null
$script:restartAfter = $false
$CanSelfUpdate = [bool]($Installed -and $SelfPath)

function ConvertTo-Ver([string]$v) {
    $p = @(($v.Trim() -split '\.') | Where-Object { $_ -match '^\d+$' })
    while ($p.Count -lt 3) { $p += '0' }
    return [version]($p[0..2] -join '.')
}
# Récupère un fichier du dépôt : texte (DownloadString) ou fichier (si $Dest). API d'abord, sinon raw.
function Get-RepoFile([string]$name, [string]$dest) {
    foreach ($src in @('api', 'raw')) {
        if ($src -eq 'api' -and -not $UpdateApi) { continue }
        try {
            $wc = New-WebClient
            $wc.Encoding = [Text.Encoding]::UTF8
            if ($src -eq 'api') { $wc.Headers['Accept'] = 'application/vnd.github.raw'; $u = "$UpdateApi/$($name)?ref=main" }
            else { $u = "$UpdateBase/$($name)?t=" + [DateTime]::UtcNow.Ticks }
            if ($dest) { $wc.DownloadFile($u, $dest); return $true }
            return $wc.DownloadString($u)
        } catch { if ($src -eq 'raw') { throw } }
    }
}

function New-WebClient {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
    $wc = New-Object Net.WebClient
    $wc.Headers['Cache-Control'] = 'no-cache'
    $wc.Headers['User-Agent'] = "YT-MP3/$AppVersion"
    return $wc
}

# $Manual : vérification demandée par l'utilisateur (affiche « Recherche… »). Les vérifications
# automatiques se font en silence et ne changent l'affichage que si une nouvelle version apparaît.
function Start-UpdateCheck([switch]$Manual) {
    if ($script:updJob -and $script:updJob.State -eq 'Running') { return }
    $script:lastUpdCheck = Get-Date
    if ($Manual -or $script:upd.state -eq 'inconnu') { $script:upd.state = 'verif'; $script:upd.error = '' }
    $script:updJob = Start-Job -ArgumentList $UpdateBase, $UpdateApi, $AppVersion -ScriptBlock {
        param($base, $api, $ver)
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
        function Get-Txt([string]$name) {
            foreach ($src in @('api', 'raw')) {
                if ($src -eq 'api' -and -not $api) { continue }
                try {
                    $wc = New-Object Net.WebClient
                    $wc.Encoding = [Text.Encoding]::UTF8
                    $wc.Headers['Cache-Control'] = 'no-cache'
                    $wc.Headers['User-Agent'] = "YT-MP3/$ver"
                    if ($src -eq 'api') { $wc.Headers['Accept'] = 'application/vnd.github.raw'; return $wc.DownloadString("$api/$($name)?ref=main") }
                    return $wc.DownloadString("$base/$($name)?t=" + [DateTime]::UtcNow.Ticks)
                } catch { if ($src -eq 'raw') { throw } }
            }
        }
        $v = (Get-Txt 'version.txt').Trim()
        $n = ''
        try { $n = Get-Txt 'notes.txt' } catch {}   # nouveautés : facultatif
        [PSCustomObject]@{ v = $v; notes = $n }
    }
}

function Update-UpdateCheck {
    $j = $script:updJob
    if (-not $j -or $j.State -eq 'Running') { return }
    try {
        $v = ''; $n = ''
        if ($j.State -eq 'Completed') {
            $r = @(Receive-Job $j -ErrorAction Stop) | Select-Object -Last 1
            if ($r) { $v = [string]$r.v; $n = [string]$r.notes }
        }
        if ($v -match '^\d+(\.\d+){0,3}$') {
            $script:upd.latest = $v
            $script:upd.error = ''
            $script:upd.state = $(if ((ConvertTo-Ver $v) -gt (ConvertTo-Ver $AppVersion)) { 'dispo' } else { 'ajour' })
            $script:upd.notes = @($n -split "`r?`n" | ForEach-Object { $_.Trim().TrimStart('-', '*', '•').Trim() } | Where-Object { $_ -and $_ -notmatch '^#' } | Select-Object -First 8)
        } elseif ($script:upd.state -ne 'dispo') {
            $script:upd.state = 'erreur'
            $script:upd.error = 'Impossible de joindre le site des mises à jour (connexion Internet ?)'
        }
    } catch {
        if ($script:upd.state -ne 'dispo') { $script:upd.state = 'erreur' }
        $script:upd.error = 'Impossible de joindre GitHub pour vérifier les mises à jour (connexion Internet ?). Réessaie plus tard.'
    }
    Remove-Job $j -Force -ErrorAction SilentlyContinue
    $script:updJob = $null
}

# Télécharge la nouvelle version, la contrôle, puis remplace l'ancienne. Renvoie un message d'erreur, ou '' si tout va bien.
function Invoke-SelfUpdate {
    if (-not $CanSelfUpdate) { return 'La mise à jour automatique fonctionne avec la version installée de YT MP3.' }
    if (Test-Busy) {
        return 'Attends la fin des téléchargements et séparations en cours, puis relance la mise à jour.'
    }
    $tmp = $SelfPath + '.new'
    try {
        [void](Get-RepoFile 'yt-mp3.ps1' $tmp)
        # Contrôles : c'est bien YT MP3, dans une version plus récente, et le script est valide
        $txt = [IO.File]::ReadAllText($tmp, [Text.Encoding]::UTF8)
        $m = [regex]::Match($txt, "(?m)^\`$AppVersion = '([0-9.]+)'")
        if (-not $m.Success) { throw 'Le fichier reçu n''est pas YT MP3.' }
        if ((ConvertTo-Ver $m.Groups[1].Value) -le (ConvertTo-Ver $AppVersion)) { throw 'Aucune version plus récente sur GitHub.' }
        $errs = $null
        [void][Management.Automation.Language.Parser]::ParseFile($tmp, [ref]$null, [ref]$errs)
        if ($errs -and $errs.Count) { throw 'le fichier reçu est incomplet ou abîmé, ta version actuelle est conservée. Réessaie dans quelques minutes.' }
        foreach ($f in @('app.ico', 'desinstaller.ps1')) {   # fichiers annexes : facultatifs
            try { [void](Get-RepoFile $f (Join-Path $Root "$f.new")); Move-Item -LiteralPath (Join-Path $Root "$f.new") -Destination (Join-Path $Root $f) -Force } catch {}
        }
        Copy-Item -LiteralPath $SelfPath -Destination ($SelfPath + '.precedent') -Force
        Move-Item -LiteralPath $tmp -Destination $SelfPath -Force
        $newVer = $m.Groups[1].Value
        try { Set-Content -LiteralPath (Join-Path $Root 'installe.txt') -Value $newVer } catch {}
        try { Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\YTMP3' -Name DisplayVersion -Value $newVer -ErrorAction Stop } catch {}
        $script:restartAfter = $true
        return ''
    } catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        $msg = $_.Exception.Message
        if ($_.Exception -is [Net.WebException] -or $msg -match 'DownloadFile|connexion|resolve|refused') { $msg = 'impossible de joindre GitHub (connexion Internet ?).' }
        return "Mise à jour impossible : $msg"
    }
}

function Restart-Self {
    $exe = (Get-Process -Id $PID).Path
    $a = "-NoProfile -ExecutionPolicy Bypass -File `"$SelfPath`" silencieux"
    try { Start-Process -FilePath $exe -ArgumentList ("-WindowStyle Hidden " + $a) -WindowStyle Hidden -ErrorAction Stop }
    catch { Start-Process -FilePath $exe -ArgumentList $a }
}

# =====================================================================
#  Enregistrement d'un mix (onglet Mix) : WebM/Opus reçu de la fenêtre -> MP3 dans la bibliothèque
# =====================================================================
$recQueue = New-Object System.Collections.ArrayList

function Save-Recording($ctx) {
    if ($ctx.Length -lt 1000) { return 'Enregistrement vide' }
    $id = [guid]::NewGuid().ToString('N').Substring(0, 10)
    $now = Get-Date
    $title = 'Mix du ' + $now.ToString('dd/MM/yyyy') + ' à ' + $now.ToString('HH\hmm')
    $src = Join-Path $Data "rec-$id.webm"
    $fs = [IO.File]::Create($src)
    try { $fs.Write($ctx.Bytes, 0, [int]$ctx.Length) } finally { $fs.Close() }
    $name = Get-SafeName ('Mix ' + $now.ToString('yyyy-MM-dd HH\hmm'))
    $out = Join-Path (Get-Out) ($name + '.mp3')
    $k = 2; while (Test-Path -LiteralPath $out) { $out = Join-Path (Get-Out) ("$name ($k).mp3"); $k++ }
    $a = @('-y', '-loglevel', 'error', '-i', $src, '-vn', '-c:a', 'libmp3lame', '-b:a', '256k',
        '-metadata', "title=$title", '-metadata', 'artist=Mix YT MP3', '-id3v2_version', '3', $out)
    $pr = Start-Proc $Ffmpeg $a (Join-Path $Data "rec-$id.log")
    [void]$recQueue.Add([PSCustomObject]@{ id = $id; proc = $pr; src = $src; out = $out; title = $title })
    return ''
}

function Update-Recordings {
    foreach ($r in @($recQueue)) {
        if (-not $r.proc.HasExited) { continue }
        if ($r.proc.ExitCode -eq 0 -and (Test-Path -LiteralPath $r.out)) {
            $fi = Get-Item -LiteralPath $r.out
            $dur = ''
            try {
                $probe = Join-Path $Bin 'ffprobe.exe'
                if (Test-Path -LiteralPath $probe) {
                    $sec = [double]::Parse((& $probe -v error -show_entries format=duration -of csv=p=0 $r.out | Select-Object -First 1), $Inv)
                    $dur = '{0}:{1:00}' -f [math]::Floor($sec / 60), [math]::Floor($sec % 60)
                    if ($sec -ge 3600) { $dur = '{0}:{1:00}:{2:00}' -f [math]::Floor($sec / 3600), [math]::Floor(($sec % 3600) / 60), [math]::Floor($sec % 60) }
                }
            } catch {}
            [void]$history.Insert(0, [PSCustomObject]@{
                id = $r.id; vid = ''; title = $r.title; uploader = 'Mix YT MP3'; duration = $dur; file = $fi.Name; path = $fi.FullName
                size = $fi.Length; quality = 256; srcAbr = 0; srcCodec = ''; thumb = ''; normalized = $false; trimmed = $false; cleaned = $false
                date = (Get-Date).ToString('dd/MM/yyyy HH:mm')
            })
            Save-History
        }
        foreach ($f in @($r.src, (Join-Path $Data "rec-$($r.id).log"), (Join-Path $Data "rec-$($r.id).log.err"))) {
            Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        }
        $recQueue.Remove($r)
    }
}

# =====================================================================
#  Playlists YouTube : lecture d'une playlist, téléchargement complet, suivi des nouveaux titres
# =====================================================================
$FollowFile = Join-Path $Data 'playlists.json'
$script:follows = New-Object System.Collections.ArrayList
if (Test-Path -LiteralPath $FollowFile) {
    try { foreach ($f in @(Get-Content -LiteralPath $FollowFile -Raw -Encoding UTF8 | ConvertFrom-Json)) { if ($f) { [void]$script:follows.Add($f) } } } catch {}
}
function Save-Follows { ConvertTo-Json -InputObject @($script:follows) -Depth 6 | Set-Content -LiteralPath $FollowFile -Encoding UTF8 }
$script:pl = @{ status = 'vide' }
$script:plProc = $null
$script:news = New-Object System.Collections.ArrayList   # messages à afficher dans la fenêtre
$script:newsN = 0
function Add-News([string]$t) { $script:newsN++; [void]$script:news.Add(@{ n = $script:newsN; text = $t }); while ($script:news.Count -gt 6) { $script:news.RemoveAt(0) } }

function Get-ListId([string]$u) { $m = [regex]::Match($u, '[?&]list=([\w-]+)'); if ($m.Success) { return $m.Groups[1].Value }; return '' }

function Start-PlaylistRead([string]$u, [string]$purpose) {
    $lid = Get-ListId $u
    $radio = $lid -match '^(RD|UL)'   # mix / radio générés par YouTube : sans fin, on se limite à 25 titres
    $a = @('--encoding', 'utf-8', '--flat-playlist', '--yes-playlist', '--no-warnings', '-I', $(if ($radio) { '1:25' } else { '1:500' }),
        '--print', 'playlist:[T]%(title)s', '--print', '[E]%(id)s|%(title)s')
    if ($script:settings.cookies -eq 'firefox') { $a += @('--cookies-from-browser', 'firefox') }
    $a += $(if ($lid) { "https://www.youtube.com/playlist?list=$lid" } else { $u })
    if ($radio -and $u -match '[?&]v=') { $a[-1] = $u }
    return @{ proc = (Start-Proc $YtDlp $a (Join-Path $Data "pl-$purpose.log")); lid = $lid; radio = $radio; log = (Join-Path $Data "pl-$purpose.log") }
}
function Read-PlaylistLog([string]$log) {
    $title = ''; $ids = New-Object System.Collections.ArrayList; $names = New-Object System.Collections.ArrayList
    foreach ($l in (Read-Shared $log)) {
        if ($l.StartsWith('[T]') -and -not $title) { $title = $l.Substring(3).Trim() }
        elseif ($l.StartsWith('[E]')) {
            $p = $l.Substring(3) -split '\|', 2
            if ($p[0] -match '^[\w-]{11}$' -and -not $ids.Contains($p[0])) { [void]$ids.Add($p[0]); [void]$names.Add($(if ($p.Count -gt 1) { $p[1] } else { '' })) }
        }
    }
    if ($title -eq 'NA') { $title = '' }
    return @{ title = $title; ids = @($ids); names = @($names) }
}

function Start-PlInfo([string]$u) {
    if ($script:plProc -and -not $script:plProc.proc.HasExited) { try { $script:plProc.proc.Kill() } catch {} }
    $script:plProc = Start-PlaylistRead $u 'info'
    $script:pl = @{ status = 'lecture'; url = $u; listId = $script:plProc.lid; radio = [bool]$script:plProc.radio; single = [bool]($u -match '[?&]v=[\w-]{11}') }
}
function Update-PlInfo {
    if (-not $script:plProc -or -not $script:plProc.proc.HasExited) { return }
    $r = Read-PlaylistLog $script:plProc.log
    $script:pl.title = $(if ($r.title) { $r.title } elseif ($script:pl.radio) { 'Mix YouTube' } else { 'Playlist' })
    $script:pl.ids = $r.ids; $script:pl.count = $r.ids.Count
    $script:pl.sample = @($r.names | Select-Object -First 5)
    $script:pl.followed = [bool](@($script:follows | Where-Object { $_.listId -eq $script:pl.listId }).Count)
    $script:pl.status = $(if ($r.ids.Count) { 'ok' } else { 'erreur' })
    $script:plProc = $null
}

# Suivi : vérifie une playlist à la fois, au démarrage puis toutes les 6 h
$script:followQueue = New-Object System.Collections.ArrayList
$script:followRun = $null
$script:lastFollowCheck = (Get-Date).AddHours(-5.9)   # première vérification ~5 min après le lancement
function Start-FollowCheck { foreach ($f in $script:follows) { if (-not $script:followQueue.Contains($f.listId)) { [void]$script:followQueue.Add($f.listId) } }; $script:lastFollowCheck = Get-Date }
function Update-Follows {
    if (-not $script:follows.Count) { return }
    if (((Get-Date) - $script:lastFollowCheck).TotalHours -ge 6) { Start-FollowCheck }
    if ($script:followRun) {
        if (-not $script:followRun.proc.HasExited) { return }
        $f = @($script:follows | Where-Object { $_.listId -eq $script:followRun.lid })[0]
        $r = Read-PlaylistLog $script:followRun.log
        if ($f -and $r.ids.Count) {
            $seen = @($f.seen)
            $new = @($r.ids | Where-Object { $seen -notcontains $_ })
            if ($new.Count) {
                Add-Urls @($new | ForEach-Object { "https://www.youtube.com/watch?v=$_" })
                $f.seen = @($seen + $new)
                Add-News ("$($new.Count) nouveau" + $(if ($new.Count -gt 1) { 'x titres' } else { ' titre' }) + " de « $($f.title) » ajouté" + $(if ($new.Count -gt 1) { 's' } else { '' }) + ' à la file')
            }
            $f.last = (Get-Date).ToString('dd/MM HH:mm')
            Save-Follows
        }
        Remove-Item -LiteralPath $script:followRun.log, ($script:followRun.log + '.err') -Force -ErrorAction SilentlyContinue
        $script:followRun = $null
    }
    if ($script:followQueue.Count -and (Get-SetupState) -eq 'pret') {
        $lid = $script:followQueue[0]; $script:followQueue.RemoveAt(0)
        $f = @($script:follows | Where-Object { $_.listId -eq $lid })[0]
        if ($f) { $script:followRun = Start-PlaylistRead $f.url ('suivi-' + $lid) }
    }
}

# =====================================================================
#  Découpage d'une mixtape en morceaux (uniquement à la demande) — l'original n'est jamais modifié
# =====================================================================
$splitQueue = New-Object System.Collections.ArrayList
$script:splitCur = $null
function Find-Split($id) { foreach ($q in $splitQueue) { if ($q.id -eq $id) { return $q } }; return $null }
function Get-Seconds([string]$d) { $s = 0; foreach ($p in ($d -split ':')) { $s = $s * 60 + [int]$p }; return $s }

function Start-NextSplit {
    if ($script:splitCur -or $script:proc -or (Get-SetupState) -ne 'pret') { return }
    $it = $null; foreach ($q in $splitQueue) { if ($q.status -eq 'attente') { $it = $q; break } }
    if (-not $it) { return }
    $h = Find-Hist $it.id
    if (-not $h -or -not $h.vid) { $it.status = 'erreur'; $it.error = 'Seules les vidéos YouTube peuvent être découpées'; return }
    $it.tmp = Join-Path $Data ('split-' + $it.id)
    if (Test-Path -LiteralPath $it.tmp) { Remove-Item -LiteralPath $it.tmp -Recurse -Force }
    [void](New-Item -ItemType Directory -Path $it.tmp)
    $u = 'https://www.youtube.com/watch?v=' + $h.vid
    $it.status = 'analyse'
    $a = @('--encoding', 'utf-8', '--no-playlist', '--skip-download', '--print', '[C]%(chapters)j', $u)
    if ($script:settings.cookies -eq 'firefox') { $a += @('--cookies-from-browser', 'firefox') }
    $it.proc = Start-Proc $YtDlp $a (Join-Path $it.tmp 'info.log')
    $script:splitCur = $it
}

function Update-Split {
    if (-not $script:splitCur) { Start-NextSplit; return }
    $it = $script:splitCur; $h = Find-Hist $it.id
    $fail = { param($m) $it.status = 'erreur'; $it.error = $m; Remove-Item -LiteralPath $it.tmp -Recurse -Force -ErrorAction SilentlyContinue; $script:splitCur = $null }
    if ($it.status -eq 'analyse') {
        if (-not $it.proc.HasExited) { return }
        $line = (Read-Shared (Join-Path $it.tmp 'info.log')) | Where-Object { $_.StartsWith('[C]') } | Select-Object -First 1
        $ch = @()
        if ($line -and $line -notmatch '^\[C\](null|NA)\s*$') { try { $ch = @($line.Substring(3) | ConvertFrom-Json) } catch {} }
        if ($ch.Count -lt 2) { & $fail 'Cette vidéo n''a pas de chapitres : découpage impossible'; return }
        $it.chapters = $ch; $it.total = $ch.Count
        $h | Add-Member -NotePropertyName chapters -NotePropertyValue $ch.Count -Force; Save-History
        # Téléchargement de la version complète puis découpe par chapitres (yt-dlp), dans un dossier temporaire
        $it.status = 'telechargement'; $it.progress = 0
        $a = @('--encoding', 'utf-8', '--newline', '--progress', '--no-playlist', '-f', 'bestaudio/best', '--ffmpeg-location', $Bin,
            '-x', '--audio-format', 'mp3', '--audio-quality', ('{0}K' -f [int]$h.quality), '--split-chapters',
            '--progress-template', 'download:[P]%(progress.downloaded_bytes)s/%(progress.total_bytes,progress.total_bytes_estimate)s',
            '-o', (Join-Path $it.tmp 'complet.%(ext)s'), '-o', ('chapter:' + (Join-Path $it.tmp '%(section_number)03d.%(ext)s')))
        if ($script:settings.normalize) { $a += @('--postprocessor-args', 'ExtractAudio:-af loudnorm=I=-14:TP=-1.5:LRA=11 -ar 44100') }
        if ($script:settings.cookies -eq 'firefox') { $a += @('--cookies-from-browser', 'firefox') }
        $a += ('https://www.youtube.com/watch?v=' + $h.vid)
        $it.proc = Start-Proc $YtDlp $a (Join-Path $it.tmp 'dl.log')
        return
    }
    if ($it.status -eq 'telechargement') {
        foreach ($l in (Read-Shared (Join-Path $it.tmp 'dl.log'))) {
            if ($l.StartsWith('[P]')) { $n = $l.Substring(3) -split '/'; $d = 0.0; $t = 0.0
                if ($n.Count -gt 1 -and [double]::TryParse($n[0], [Globalization.NumberStyles]::Float, $Inv, [ref]$d) -and [double]::TryParse($n[1], [Globalization.NumberStyles]::Float, $Inv, [ref]$t) -and $t -gt 0) { $it.progress = [math]::Min(100, [math]::Round($d * 100 / $t)) } }
        }
        if (-not $it.proc.HasExited) { return }
        $files = @(Get-ChildItem -LiteralPath $it.tmp -Filter '???.mp3' | Sort-Object Name)
        if ($it.proc.ExitCode -ne 0 -or $files.Count -lt 2) {
            $err = (Read-Shared (Join-Path $it.tmp 'dl.log.err')) | Where-Object { $_ -match 'ERROR' } | Select-Object -Last 1
            & $fail $(if ($err) { ($err -replace '^.*?ERROR:\s*', '') } else { 'Le découpage a échoué' }); return
        }
        $it.files = $files; $it.done = 0; $it.status = 'decoupe'
        $base = [IO.Path]::GetDirectoryName((Get-HistPath $h))
        $it.dest = Join-Path $base (Get-SafeName ($h.title + ' (découpé)'))
        if (-not (Test-Path -LiteralPath $it.dest)) { [void](New-Item -ItemType Directory -Path $it.dest) }
        $it.cover = Join-Path $it.tmp 'cover.jpg'
        & $Ffmpeg -y -loglevel error -i (Get-HistPath $h) -an -c:v copy $it.cover 2>$null
        if (-not (Test-Path -LiteralPath $it.cover)) { $it.cover = $null }
        return
    }
    if ($it.status -eq 'decoupe') {
        # Un morceau par passage de boucle : titre, artiste, album, numéro de piste et pochette
        $i = $it.done
        if ($i -lt $it.files.Count) {
            $c = $it.chapters[[math]::Min($i, $it.chapters.Count - 1)]
            $cm = Get-CleanMeta ([string]$c.title) $h.uploader '' ''
            if (-not $cm[1]) { $cm = @($h.uploader, "Partie $($i + 1)") }
            $name = Get-SafeName ('{0:00} - {1} - {2}' -f ($i + 1), $cm[0], $cm[1])
            $out = Join-Path $it.dest ($name + '.mp3')
            $a = @('-y', '-loglevel', 'error', '-i', $it.files[$i].FullName)
            if ($it.cover) { $a += @('-i', $it.cover, '-map', '0:a', '-map', '1:v') } else { $a += @('-map', '0:a') }
            $a += @('-c', 'copy', '-id3v2_version', '3', '-map_metadata', '-1',
                '-metadata', "title=$($cm[1])", '-metadata', "artist=$($cm[0])", '-metadata', "album=$($h.title)", '-metadata', ("track={0}/{1}" -f ($i + 1), $it.files.Count), $out)
            & $Ffmpeg @a 2>$null
            if (Test-Path -LiteralPath $out) {
                $fi = Get-Item -LiteralPath $out
                $secs = [double]$c.end_time - [double]$c.start_time
                [void]$history.Insert(0, [PSCustomObject]@{
                    id = [guid]::NewGuid().ToString('N').Substring(0, 10); vid = $h.vid; title = $cm[1]; uploader = $cm[0]
                    duration = ('{0}:{1:00}' -f [math]::Floor($secs / 60), [math]::Floor($secs % 60)); file = $fi.Name; path = $fi.FullName
                    size = $fi.Length; quality = $h.quality; srcAbr = $h.srcAbr; srcCodec = $h.srcCodec; thumb = $h.thumb
                    normalized = [bool]$script:settings.normalize; trimmed = $false; cleaned = $true; fromMix = $h.title; part = $i + 1
                    date = (Get-Date).ToString('dd/MM/yyyy HH:mm')
                })
            }
            $it.done++
            return
        }
        Save-History
        Add-News ("« $($h.title) » découpé en $($it.done) morceaux")
        $h | Add-Member -NotePropertyName splitDir -NotePropertyValue $it.dest -Force; Save-History
        Remove-Item -LiteralPath $it.tmp -Recurse -Force -ErrorAction SilentlyContinue
        $splitQueue.Remove($it); $script:splitCur = $null
    }
}

# =====================================================================
#  Export vers une clé USB / un dossier (copie en arrière-plan)
# =====================================================================
$script:exp = @{ status = 'vide' }
$script:expJob = $null
function Start-Export($ids, [string]$dest, [bool]$numbered, [bool]$ascii) {
    if (-not (Test-Path -LiteralPath $dest)) { return 'Dossier de destination introuvable' }
    $list = @(); $n = 0; $total = [int64]0
    foreach ($id in $ids) {
        $h = Find-Hist ([string]$id); if (-not $h) { continue }
        $p = Get-HistPath $h; if (-not (Test-Path -LiteralPath $p)) { continue }
        $n++; $total += (Get-Item -LiteralPath $p).Length
        $list += , @($p, [string]$n)
    }
    if (-not $list.Count) { return 'Aucun titre à copier' }
    try {
        $drv = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot((Resolve-Path -LiteralPath $dest).Path))
        if ($drv.AvailableFreeSpace -lt $total + 1MB) { return ('Pas assez de place : il faut {0} Mo, il reste {1} Mo' -f [math]::Ceiling($total / 1MB), [math]::Floor($drv.AvailableFreeSpace / 1MB)) }
    } catch {}
    $prog = Join-Path $Data 'export.progress'
    Set-Content -LiteralPath $prog -Value '0'
    $script:exp = @{ status = 'copie'; done = 0; total = $list.Count; dest = $dest; error = '' }
    $script:expJob = Start-Job -ArgumentList $list, $dest, $numbered, $ascii, $prog -ScriptBlock {
        param($list, $dest, $numbered, $ascii, $prog)
        $width = [math]::Max(2, ([string]$list.Count).Length)
        $i = 0
        foreach ($e in $list) {
            $src = $e[0]; $i++
            $name = [IO.Path]::GetFileNameWithoutExtension($src)
            if ($ascii) {   # vieux autoradios : sans accents ni caractères spéciaux
                $name = -join ($name.Normalize([Text.NormalizationForm]::FormD).ToCharArray() | Where-Object { [Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne 'NonSpacingMark' })
                $name = ($name -replace '[^\x20-\x7E]', '_') -replace '_{2,}', '_'
            }
            if ($numbered) { $name = ([string]$i).PadLeft($width, '0') + ' - ' + ($name -replace '^\d{1,3} - ', '') }
            $name = $name -replace '[<>:"/\\|?*]', '' 
            if ($name.Length -gt 120) { $name = $name.Substring(0, 120).Trim() }
            [IO.File]::Copy($src, (Join-Path $dest ($name + '.mp3')), $true)
            Set-Content -LiteralPath $prog -Value $i
        }
    }
    return ''
}
function Update-Export {
    $j = $script:expJob; if (-not $j) { return }
    try { $script:exp.done = [int](Get-Content -LiteralPath (Join-Path $Data 'export.progress') -Raw) } catch {}
    if ($j.State -eq 'Running') { return }
    if ($j.State -eq 'Completed') { $script:exp.status = 'fini'; $script:exp.done = $script:exp.total; Add-News ("$($script:exp.total) titre" + $(if ($script:exp.total -gt 1) { 's copiés' } else { ' copié' }) + " dans $($script:exp.dest)") }
    else {
        $script:exp.status = 'erreur'
        try { $script:exp.error = $j.ChildJobs[0].JobStateInfo.Reason.Message } catch {}
        if (-not $script:exp.error) { $script:exp.error = 'Copie interrompue (clé retirée ?)' }
    }
    Remove-Job $j -Force -ErrorAction SilentlyContinue; $script:expJob = $null
}

function Add-Urls($urls) {
    $auto = $script:settings.quality -eq 'auto'
    $quality = 192
    if (-not $auto) { $quality = [int]$script:settings.quality }
    foreach ($u in @($urls)) {
        $u = ([string]$u).Trim()
        if ($u -match '^https?://[^\s"]+$') {
            [void]$queue.Add([PSCustomObject]@{
                id = [guid]::NewGuid().ToString('N').Substring(0, 10); url = $u; quality = $quality
                status = 'attente'; progress = 0; title = ''; uploader = ''; duration = ''; vid = ''; file = ''; error = ''
                attempt = 0; blocked = $false; auto = $auto; analysed = $false; phase = ''
                srcAbrRaw = ''; srcCodecRaw = ''; srcAbr = 0; srcCodec = ''; normalized = $false
                thumb = ''; seconds = 0; rawArtist = ''; rawTrack = ''; cleanArtist = ''; cleanTitle = ''; cleaned = $false; trimmed = $false; chapters = $null
            })
        }
    }
    Start-Next
}

function Stop-Current {
    if ($script:proc -and -not $script:proc.HasExited) {
        try { & taskkill.exe /PID $script:proc.Id /T /F | Out-Null } catch { try { $script:proc.Kill() } catch {} }
    }
}

# =====================================================================
#  Serveur HTTP local
# =====================================================================
$Latin1 = [Text.Encoding]::GetEncoding(28591)

# Lit une requête HTTP/1.1 complète (en-têtes + corps) depuis la connexion
function Read-HttpRequest($client) {
    $client.ReceiveTimeout = 5000
    $client.SendTimeout = 5000   # un lecteur qui ne lit plus ne doit jamais bloquer le serveur
    $ns = $client.GetStream()
    $ms = New-Object IO.MemoryStream
    $buf = New-Object byte[] 16384
    $headEnd = -1
    while ($headEnd -lt 0) {
        $n = $ns.Read($buf, 0, $buf.Length)
        if ($n -le 0) { return $null }
        $ms.Write($buf, 0, $n)
        $headEnd = $Latin1.GetString($ms.ToArray()).IndexOf("`r`n`r`n")
        if ($ms.Length -gt 1MB) { return $null }
    }
    $all = $ms.ToArray()
    $lines = $Latin1.GetString($all, 0, $headEnd) -split "`r`n"
    $first = $lines[0] -split ' '
    if ($first.Count -lt 2) { return $null }
    $headers = @{}
    foreach ($l in ($lines | Select-Object -Skip 1)) {
        $i = $l.IndexOf(':')
        if ($i -gt 0) { $headers[$l.Substring(0, $i).Trim().ToLower()] = $l.Substring($i + 1).Trim() }
    }
    $len = 0
    if ($headers['content-length']) { $len = [int64]$headers['content-length'] }
    if ($len -gt 600MB) { return $null }
    $bodyStart = $headEnd + 4
    $bytes = New-Object byte[] $len
    $have = [math]::Min($len, $all.Length - $bodyStart)
    if ($have -gt 0) { [Array]::Copy($all, $bodyStart, $bytes, 0, $have) }
    if ($len -gt 1MB) { $client.ReceiveTimeout = 30000 }
    while ($have -lt $len) {
        $n = $ns.Read($bytes, $have, [int][math]::Min(1MB, $len - $have))
        if ($n -le 0) { break }
        $have += $n
    }
    $body = ''
    if ($len -gt 0 -and $len -le 1MB) { $body = [Text.Encoding]::UTF8.GetString($bytes, 0, $have) }
    $parts = $first[1] -split '\?', 2
    return @{
        Method = $first[0].ToUpper()
        Path   = $parts[0]
        Query  = $(if ($parts.Count -gt 1) { $parts[1] } else { '' })
        Origin = $headers['origin']
        Range  = $headers['range']
        Body   = $body
        Bytes  = $bytes
        Length = $have
        Stream = $ns
    }
}

function Send($ctx, [int]$code, [string]$body, [string]$type) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($body)
    $reason = @{ 200 = 'OK'; 403 = 'Forbidden'; 404 = 'Not Found'; 500 = 'Internal Server Error' }[$code]
    $head = "HTTP/1.1 $code $reason`r`nContent-Type: $type`r`nContent-Length: $($bytes.Length)`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n"
    $hb = $Latin1.GetBytes($head)
    $ctx.Stream.Write($hb, 0, $hb.Length)
    $ctx.Stream.Write($bytes, 0, $bytes.Length)
    $ctx.Stream.Flush()
}
# Diffuse un fichier audio par morceaux (requêtes « Range ») : permet au lecteur d'avancer/reculer,
# et chaque réponse est plafonnée à 2 Mo pour que le serveur reste réactif pendant la lecture
function Send-File($ctx, [string]$path, [string]$type) {
    $fs = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $total = $fs.Length
        $start = [int64]0; $end = $total - 1
        if ($ctx.Range -match 'bytes=(\d*)-(\d*)') {
            if ($Matches[1]) {
                $start = [int64]$Matches[1]
                if ($Matches[2]) { $end = [math]::Min([int64]$Matches[2], $total - 1) }
            } elseif ($Matches[2]) {
                $start = [math]::Max([int64]0, $total - [int64]$Matches[2])   # « bytes=-500 » : les 500 derniers octets
            }
        }
        if ($total -eq 0 -or $start -ge $total) {
            $hb = $Latin1.GetBytes("HTTP/1.1 416 Range Not Satisfiable`r`nContent-Range: bytes */$total`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")
            $ctx.Stream.Write($hb, 0, $hb.Length); return
        }
        $max = 2MB
        if (($end - $start + 1) -gt $max) { $end = $start + $max - 1 }
        $len = $end - $start + 1
        $head = "HTTP/1.1 206 Partial Content`r`nContent-Type: $type`r`nAccept-Ranges: bytes`r`n" +
                "Content-Range: bytes $start-$end/$total`r`nContent-Length: $len`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n"
        $hb = $Latin1.GetBytes($head)
        $ctx.Stream.Write($hb, 0, $hb.Length)
        [void]$fs.Seek($start, [IO.SeekOrigin]::Begin)
        $buf = New-Object byte[] 65536
        $left = $len
        while ($left -gt 0) {
            $n = $fs.Read($buf, 0, [int][math]::Min($buf.Length, $left))
            if ($n -le 0) { break }
            $ctx.Stream.Write($buf, 0, $n)
            $left -= $n
        }
        $ctx.Stream.Flush()
    } finally { $fs.Close() }
}

function Send-Json($ctx, $obj) { Send $ctx 200 (ConvertTo-Json -InputObject $obj -Depth 5 -Compress) 'application/json; charset=utf-8' }

function Get-State {
    $hist = @($history | ForEach-Object {
        [PSCustomObject]@{
            id = $_.id; vid = $_.vid; thumb = $_.thumb; title = $_.title; uploader = $_.uploader; duration = $_.duration
            size = $_.size; quality = $_.quality; date = $_.date; srcAbr = $_.srcAbr; srcCodec = $_.srcCodec; normalized = [bool]$_.normalized; trimmed = [bool]$_.trimmed; cleaned = [bool]$_.cleaned
            exists = (Test-Path -LiteralPath (Get-HistPath $_))
            voix = [bool]($_.voix -and (Test-Path -LiteralPath $_.voix))
            instru = [bool]($_.instru -and (Test-Path -LiteralPath $_.instru))
            sep = $(if ($sq = Find-Sep $_.id) { @{ status = $sq.status; progress = $sq.progress; error = $sq.error } } else { $null })
            chapters = $_.chapters; fromMix = $_.fromMix; part = $_.part
            splitDir = $(if ($_.splitDir -and (Test-Path -LiteralPath $_.splitDir)) { $_.splitDir } else { '' })
            split = $(if ($sp = Find-Split $_.id) { @{ status = $sp.status; progress = $sp.progress; done = $sp.done; total = $sp.total; error = $sp.error } } else { $null })
        }
    })
    $q = @($queue | ForEach-Object {
        [PSCustomObject]@{
            id = $_.id; url = $_.url; quality = $_.quality; status = $_.status; progress = $_.progress
            title = $_.title; uploader = $_.uploader; duration = $_.duration; vid = $_.vid; thumb = $_.thumb; error = $_.error
            attempt = $_.attempt; tries = $Clients.Count; blocked = $_.blocked
            auto = $_.auto; analysed = $_.analysed; srcAbr = $_.srcAbr; srcCodec = $_.srcCodec
        }
    })
    $setup = Get-SetupState
    $mb = 0
    if ($setup -eq 'installation') { $mb = Get-SetupMb }
    return @{
        setup = $setup; setupError = $script:setupError; setupMb = $mb; queue = $q; history = $hist
        settings = @{ outDir = (Get-Out); cookies = $script:settings.cookies; quality = $script:settings.quality; normalize = $script:settings.normalize; trim = $script:settings.trim; clean = $script:settings.clean; sources = @($script:settings.sources); defaultDir = $DefaultOut }
        version = (Get-Version); appVersion = $AppVersion; installed = $Installed
        update = @{
            state = $script:upd.state; latest = $script:upd.latest; error = $script:upd.error; canApply = $CanSelfUpdate
            notes = @($script:upd.notes); busy = (Test-Busy); planned = $script:updateWhenIdle
        }
        playlist = @{ status = $script:pl.status; title = $script:pl.title; count = $script:pl.count; single = $script:pl.single; radio = $script:pl.radio; followed = $script:pl.followed; sample = @($script:pl.sample); listId = $script:pl.listId }
        follows = @($script:follows | ForEach-Object { @{ listId = $_.listId; title = $_.title; count = @($_.seen).Count; last = $_.last } })
        followBusy = [bool]($script:followRun -or $script:followQueue.Count)
        news = @($script:news)
        export = $script:exp
        separation = @{ state = (Get-SepState); step = (Get-SepStep); error = $script:sepInstallError
            gpu = (Get-GpuState); gpuName = (Get-GpuName); gpuError = $script:gpuError }
        search = @{
            status = $script:search.status; q = $script:search.q; count = $script:search.count
            sources = $script:search.sources; results = @($script:search.results)
        }
    }
}

function Invoke-Request($ctx) {
    $path = $ctx.Path
    $origin = $ctx.Origin
    if ($origin -and $origin.TrimEnd('/') -ne $Url.TrimEnd('/')) { Send $ctx 403 '{}' 'application/json'; return }

    if ($ctx.Method -eq 'GET') {
        if ($path -eq '/' -or $path -eq '/index.html') { Send $ctx 200 $Html 'text/html; charset=utf-8'; return }
        if ($path -match '^/media/([A-Za-z0-9]+)/(orig|voix|instru)\.mp3$') {
            $h = Find-Hist $Matches[1]
            $f = $null
            if ($h) {
                switch ($Matches[2]) { 'orig' { $f = Get-HistPath $h } 'voix' { $f = $h.voix } 'instru' { $f = $h.instru } }
            }
            if ($f -and (Test-Path -LiteralPath $f)) { Send-File $ctx $f 'audio/mpeg' } else { Send $ctx 404 'Introuvable' 'text/plain; charset=utf-8' }
            return
        }
        if ($path -eq '/api/state') {
            $script:lastSeen = Get-Date
            $script:byeAt = $null
            Send-Json $ctx (Get-State); return
        }
        Send $ctx 404 'Introuvable' 'text/plain; charset=utf-8'; return
    }

    $body = $null
    try {
        $raw = $ctx.Body
        if ($raw -and $raw.Trim().StartsWith('{')) { $body = $raw | ConvertFrom-Json }
    } catch {}
    $id = $null
    if ($body -and $body.id) { $id = [string]$body.id }

    switch ($path) {
        '/api/add' {
            Add-Urls @($body.urls)
        }
        '/api/cancel' {
            $it = Find-Queue $id
            if ($it) {
                if ($it -eq $script:current) { $it.status = 'annule'; Stop-Current }
                $queue.Remove($it)
            }
        }
        '/api/dismiss' { $it = Find-Queue $id; if ($it) { $queue.Remove($it) } }
        '/api/retry'   {
            $it = Find-Queue $id
            if ($it) { $it.status = 'attente'; $it.error = ''; $it.progress = 0; $it.attempt = 0; $it.blocked = $false; $it.analysed = $false; $it.cleanTitle = ''; $it.cleanArtist = ''; $it.title = ''; Start-Next }
        }
        '/api/play'    {
            $h = Find-Hist $id
            if ($h) { $p = Get-HistPath $h; if (Test-Path -LiteralPath $p) { Invoke-Item -LiteralPath $p } }
        }
        '/api/reveal'  {
            $h = Find-Hist $id
            if ($h) { $p = Get-HistPath $h; if (Test-Path -LiteralPath $p) { Start-Process explorer.exe -ArgumentList "/select,`"$p`"" } }
        }
        '/api/delete'  {
            $h = Find-Hist $id
            if ($h) {
                $p = Get-HistPath $h
                Add-Type -AssemblyName Microsoft.VisualBasic
                foreach ($f in @($p, $h.voix, $h.instru)) {
                    if ($f -and (Test-Path -LiteralPath $f)) {
                        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($f, 'OnlyErrorDialogs', 'SendToRecycleBin')
                    }
                }
                $history.Remove($h); Save-History
            }
        }
        '/api/forget'  { $h = Find-Hist $id; if ($h) { $history.Remove($h); Save-History } }
        '/api/recording' {
            $err = Save-Recording $ctx
            if ($err) { Send-Json $ctx @{ error = $err }; return }
            Send-Json $ctx @{ ok = $true }; return
        }
        '/api/checkupdate' { Start-UpdateCheck -Manual }
        '/api/cancelupdate' { $script:updateWhenIdle = $false }
        '/api/update' {
            if ($body -and $body.whenIdle -and (Test-Busy)) {
                $script:updateWhenIdle = $true
                Send-Json $ctx @{ ok = $true; planned = $true }; return
            }
            $err = Invoke-SelfUpdate
            if ($err) { Send-Json $ctx @{ error = $err }; return }
            Send-Json $ctx @{ ok = $true; restarting = $true }; return
        }
        '/api/gpuinstall' { if ((Get-GpuState) -in @('dispo', 'erreur') -and (Get-SepState) -eq 'pret' -and -not $script:sepProc) { Start-GpuInstall } }
        '/api/sepinstall' { if ((Get-SepState) -ne 'installation') { Start-SepInstall } }
        '/api/separate' {
            if ((Find-Hist $id) -and -not (Find-Sep $id)) {
                [void]$sepQueue.Add([PSCustomObject]@{ id = $id; status = 'attente'; progress = 0; error = ''; phase = ''; tmp = ''; started = $null; gpu = $false; cpuOnly = $false })
                Start-NextSep
            }
        }
        '/api/sepcancel' {
            $sq = Find-Sep $id
            if ($sq) {
                if ($sq -eq $script:sepCur -and $script:sepProc -and -not $script:sepProc.HasExited) {
                    $sq.status = 'annule'
                    try { & taskkill.exe /PID $script:sepProc.Id /T /F | Out-Null } catch { try { $script:sepProc.Kill() } catch {} }
                }
                $sepQueue.Remove($sq)
            }
        }
        '/api/playstem' {
            $h = Find-Hist $id
            $stem = [string]$body.stem
            if ($h -and ($stem -eq 'voix' -or $stem -eq 'instru') -and $h.$stem -and (Test-Path -LiteralPath $h.$stem)) { Invoke-Item -LiteralPath $h.$stem }
        }
        '/api/search'  {
            $n = 8
            if ($body.more -and $script:search.q -eq ([string]$body.q).Trim()) { $n = [math]::Min(40, [int]$script:search.count + 8) }
            Start-Search ([string]$body.q) $n
        }
        '/api/folder'  { Start-Process explorer.exe -ArgumentList "`"$(Get-Out)`"" }
        '/api/settings' {
            if ($body.cookies -eq 'firefox' -or $body.cookies -eq 'aucun') { $script:settings.cookies = [string]$body.cookies }
            if (@('auto', '192', '320') -contains [string]$body.quality) { $script:settings.quality = [string]$body.quality }
            if ($null -ne $body.normalize) { $script:settings.normalize = [bool]$body.normalize }
            if ($null -ne $body.trim) { $script:settings.trim = [bool]$body.trim }
            if ($null -ne $body.clean) { $script:settings.clean = [bool]$body.clean }
            if ($null -ne $body.sources) { $script:settings.sources = @(@($body.sources) | Where-Object { $SourceNames.Contains([string]$_) }) }
            if ($body.outDir) {
                $d = ([string]$body.outDir).Trim().Trim('"')
                if (-not [IO.Path]::IsPathRooted($d)) {
                    Send-Json $ctx @{ error = 'Indique un chemin complet, par exemple D:\Musique' }; return
                }
                try { if (-not (Test-Path -LiteralPath $d)) { [void](New-Item -ItemType Directory -Path $d -Force) } }
                catch { Send-Json $ctx @{ error = "Impossible de créer ce dossier : $($_.Exception.Message)" }; return }
                $script:settings.outDir = $d
            }
            if ($body.reset) { $script:settings.outDir = $DefaultOut }
            Save-Settings
        }
        '/api/pickfolder' {
            Add-Type -AssemblyName System.Windows.Forms
            $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
            $dlg.Description = 'Choisis le dossier où enregistrer les MP3'
            $dlg.ShowNewFolderButton = $true
            $dlg.SelectedPath = (Get-Out)
            $owner = New-Object System.Windows.Forms.Form
            $owner.TopMost = $true
            if ($dlg.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) {
                $script:settings.outDir = $dlg.SelectedPath
                Save-Settings
            }
            $owner.Dispose()
        }
        '/api/plinfo' { Start-PlInfo ([string]$body.url) }
        '/api/plclose' { if ($script:plProc) { try { $script:plProc.proc.Kill() } catch {}; $script:plProc = $null }; $script:pl = @{ status = 'vide' } }
        '/api/addplaylist' {
            if ($script:pl.status -eq 'ok') {
                $ids = @($script:pl.ids)
                if ($body.all) { Add-Urls @($ids | ForEach-Object { "https://www.youtube.com/watch?v=$_" }) }
                elseif ($script:pl.single) { Add-Urls @($script:pl.url) }
                if ($body.follow -and $script:pl.listId -and -not $script:pl.radio -and -not $script:pl.followed) {
                    [void]$script:follows.Add([PSCustomObject]@{ listId = $script:pl.listId; url = "https://www.youtube.com/playlist?list=$($script:pl.listId)"; title = $script:pl.title; seen = $ids; last = (Get-Date).ToString('dd/MM HH:mm') })
                    Save-Follows
                }
                $script:pl = @{ status = 'vide' }
            }
        }
        '/api/unfollow' { foreach ($f in @($script:follows | Where-Object { $_.listId -eq [string]$body.listId })) { $script:follows.Remove($f) }; Save-Follows }
        '/api/followcheck' { Start-FollowCheck }
        '/api/split' {
            $h = Find-Hist $id
            if ($h -and -not (Find-Split $id)) { [void]$splitQueue.Add(@{ id = $id; status = 'attente'; progress = 0; done = 0; total = 0; error = '' }); Start-NextSplit }
        }
        '/api/splitcancel' {
            $sp = Find-Split $id
            if ($sp) {
                if ($sp -eq $script:splitCur) { try { if (-not $sp.proc.HasExited) { $sp.proc.Kill() } } catch {}; Start-Sleep -Milliseconds 300; Remove-Item -LiteralPath $sp.tmp -Recurse -Force -ErrorAction SilentlyContinue; $script:splitCur = $null }
                $splitQueue.Remove($sp)
            }
        }
        '/api/pickdir' {
            Add-Type -AssemblyName System.Windows.Forms
            $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
            $dlg.Description = 'Choisis la clé USB ou le dossier où copier les titres'
            $dlg.ShowNewFolderButton = $true
            $owner = New-Object System.Windows.Forms.Form; $owner.TopMost = $true
            $dir = ''
            if ($dlg.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) { $dir = $dlg.SelectedPath }
            $owner.Dispose()
            Send-Json $ctx @{ dir = $dir }; return
        }
        '/api/export' {
            if ($script:expJob) { Send-Json $ctx @{ error = 'Une copie est déjà en cours' }; return }
            $err = Start-Export @($body.ids) ([string]$body.dest) ([bool]$body.numbered) ([bool]$body.ascii)
            if ($err) { Send-Json $ctx @{ error = $err }; return }
        }
        '/api/exportdone' { if (-not $script:expJob) { $script:exp = @{ status = 'vide' } } }
        '/api/setup'   { if (-not ($script:setupJob -and $script:setupJob.State -eq 'Running')) { Start-Setup } }
        '/api/bye'     { $script:byeAt = Get-Date; Send $ctx 200 '{}' 'application/json'; return }
        default        { Send $ctx 404 '{}' 'application/json'; return }
    }
    Send-Json $ctx (Get-State)
}

# =====================================================================
#  Boucle principale
# =====================================================================
$script:lastSeen = Get-Date
$script:byeAt = $null
Start-Setup
Start-UpdateCheck
Open-Window

$tick = [Diagnostics.Stopwatch]::StartNew()
$lastLoop = Get-Date
while ($true) {
    try {
        # Traite toutes les connexions en attente, sinon petite pause
        if ($listener.Pending()) {
            $client = $listener.AcceptTcpClient()
            try {
                $ctx = Read-HttpRequest $client
                if ($ctx) {
                    try { Invoke-Request $ctx }
                    catch { try { Send $ctx 500 (ConvertTo-Json @{ error = $_.Exception.Message } -Compress) 'application/json' } catch {} }
                }
            } catch {}
            finally { try { $client.Close() } catch {} }
            if ($script:restartAfter) { break }
            continue
        }
        Start-Sleep -Milliseconds 60

        # Sortie de veille : l'horloge a sauté. On laisse à la fenêtre le temps de se manifester
        # au lieu de croire qu'elle a été fermée (cause de l'erreur « Failed to fetch » au réveil).
        $now = Get-Date
        if (($now - $lastLoop).TotalSeconds -gt 20) { $script:lastSeen = $now; $script:byeAt = $null }
        $lastLoop = $now

        if ($tick.ElapsedMilliseconds -lt 400) { continue }
        $tick.Restart()
        try { Update-Job } catch {}
        try { Update-Search } catch {}
        try { Update-Sep } catch {}
        try { Update-UpdateCheck } catch {}
        try { Update-Recordings } catch {}
        try { Update-PlInfo } catch {}
        try { Update-Follows } catch {}
        try { Update-Split } catch {}
        try { Update-Export } catch {}
        if ($CanSelfUpdate -and ($now - $script:lastUpdCheck).TotalSeconds -gt $UpdateEvery) { try { Start-UpdateCheck } catch {} }
        # Mise à jour programmée « à la fin des téléchargements » : on l'installe dès que tout est terminé
        if ($script:updateWhenIdle -and -not (Test-Busy)) {
            $script:updateWhenIdle = $false
            $err = Invoke-SelfUpdate
            if ($err) { $script:upd.error = $err } elseif ($script:restartAfter) { break }
        }

        # Fermeture automatique quand la fenêtre est fermée et qu'il n'y a plus rien à faire
        $pending = @($queue | Where-Object { $_.status -eq 'attente' }).Count -gt 0 -and (Get-SetupState) -ne 'erreur'
        if (-not $script:proc -and -not $pending -and -not $script:sepProc -and -not $script:searchProcs.Count -and -not $recQueue.Count -and -not $script:splitCur -and -not $script:expJob) {
            if ($script:byeAt -and ($now - $script:byeAt).TotalSeconds -gt 5) { break }
            if (($now - $script:lastSeen).TotalSeconds -gt $IdleSeconds) { break }
        }
    } catch {
        Start-Sleep -Milliseconds 200   # une erreur imprévue ne doit jamais arrêter le moteur
    }
}
try { $listener.Stop() } catch {}
if ($script:restartAfter) { Restart-Self }   # relance la nouvelle version ; la fenêtre ouverte se reconnecte toute seule
exit
