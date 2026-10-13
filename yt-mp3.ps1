# =====================================================================
#  YT MP3 v2.1 - convertisseur YouTube vers MP3 (usage personnel)
#  Moteur : yt-dlp + ffmpeg + deno, installés automatiquement dans .\outils
# =====================================================================

$ErrorActionPreference = 'Stop'
$AppVersion = '2.1'   # à incrémenter à chaque évolution (voir CHANGELOG dans l'interface)
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
      <label class="search"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/></svg><input id="q" placeholder="Rechercher…"></label>
    </div>
    <div class="list lib" id="lib"></div>
  </section>
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
function renderSepCard(sp){
  const key = JSON.stringify(sp); if (key === sepKey) return; sepKey = key;
  const box = $('#sepbox');
  if (sp.state === 'pret') box.innerHTML = `<div class="sepst ok-txt">✓ Module installé. Utilise le bouton ${I.split} sur un titre de la bibliothèque.</div>`;
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
  a.addEventListener('play', () => { if (n === deck) { P.playing = true; updateMeta(); } });
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
  nv.textContent = `Mise à jour v${u.latest}`;
  const key = JSON.stringify(u); if (key === updKey) return; updKey = key;
  let html;
  if (u.state === 'verif') html = `<div class="updst"><div class="spin"></div>Recherche d'une mise à jour…</div>`;
  else if (u.state === 'dispo') html = `<div class="updst">Nouvelle version disponible : <b>v${esc(u.latest)}</b> (tu as v${esc(s.appVersion)})</div>`
      + (u.canApply ? `<button class="go sm" id="doUpdate">Installer la mise à jour</button>`
                    : `<p class="st err" style="white-space:normal">Installe YT MP3 avec la commande d'installation pour profiter des mises à jour automatiques.</p>`);
  else if (u.state === 'ajour') html = `<div class="updst ok-txt">✓ Tu as la dernière version (v${esc(s.appVersion)}).</div><button class="btn-ghost" data-act="checkupdate">Vérifier à nouveau</button>`;
  else if (u.state === 'erreur') html = `<p class="st err" style="white-space:normal;margin-bottom:12px">${esc(u.error)}</p><button class="btn-ghost" data-act="checkupdate">Réessayer</button>`;
  else html = `<button class="btn-ghost" data-act="checkupdate">Rechercher une mise à jour</button>`;
  $('#updbox').innerHTML = html;
  const b = $('#doUpdate');
  if (b) b.onclick = async () => {
    b.disabled = true; b.textContent = 'Téléchargement…';
    try {
      const r = await api('/api/update', {});
      if (r.error) { toast(r.error, 'err'); b.disabled = false; b.textContent = 'Installer la mise à jour'; return; }
      updating = true;
      $('#ov').classList.add('show');
      $('#ovbox').innerHTML = `<div class="spin"></div><h3>Mise à jour vers v${esc(u.latest)}</h3><p>YT MP3 redémarre, la fenêtre va se recharger toute seule…</p>`;
    } catch(e){ toast(e.message, 'err'); b.disabled = false; b.textContent = 'Installer la mise à jour'; }
  };
}
$('#newver').onclick = () => { show('set'); setTimeout(() => $('#updcard').scrollIntoView({behavior:'smooth'}), 50); };

/* --- Onglets --- */
function show(tab){
  document.querySelectorAll('.tabs button').forEach(b => b.classList.toggle('on', b.dataset.tab === tab));
  $('#v-main').hidden = tab !== 'main';
  $('#v-set').hidden = tab !== 'set';
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
  if (act === 'checkupdate') { updKey = ''; }
  if (act === 'delete' && !confirm('Envoyer ce MP3 à la corbeille ?')) return;
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
  if (s.appVersion) renderAbout(s.appVersion);
  renderSepCard(s.separation || {});
  renderSearch(s.search);

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
        <div class="s">${esc(x.uploader)}<span class="dot">•</span>${x.exists ? mb(x.size) : 'Fichier introuvable'}<span class="dot">•</span>${esc(x.date)}${qtag(x)}</div>${sepHtml(x)}</div>
      <div class="acts">
        ${x.exists && !x.sep && !(x.voix && x.instru) ? `<button class="ib" data-act="separate" data-id="${x.id}" title="Séparer voix / instrumental">${I.split}</button>` : ''}
        ${x.exists ? `<button class="ib" data-act="reveal" data-id="${x.id}" title="Afficher dans le dossier">${I.reveal}</button>` : ''}
        <button class="ib del" data-act="${x.exists ? 'delete' : 'forget'}" data-id="${x.id}" title="${x.exists ? 'Supprimer' : 'Retirer de la liste'}">${x.exists ? I.trash : I.x}</button>
      </div>
    </div>`).join('')
    : `<div class="empty">${I.note}<div>${filter ? 'Aucun résultat' : 'Tes MP3 apparaîtront ici'}</div></div>`;
}

/* --- Notifications de fin --- */
let known = null;
function notifyDone(s){
  const ids = new Set((s.history || []).map(x => x.id));
  if (known) for (const x of s.history || []) if (!known.has(x.id)) toast('✓ ' + x.title, 'ok');
  known = ids;
}

/* --- Connexion au moteur : détection d'arrêt et relance --- */
let down = false;
function setDown(v){
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
        $a += @('--simulate', '--print', '[A]%(abr)s|%(acodec)s|%(duration)s|%(artist)s|%(track)s|%(id)s|%(uploader)s|%(duration_string)s|%(thumbnail)s|%(title)s')
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
                date = (Get-Date).ToString('dd/MM/yyyy HH:mm')
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
    $script:sepJob = Start-Job -ArgumentList $Bin -ScriptBlock {
        param($Bin)
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
        Step 'Installation de PyTorch (le plus long, environ 250 Mo)…'
        & $pyexe @pipArgs torch==2.5.1 *>> $log
        Check 'Installation de PyTorch impossible'
        Step 'Installation de Demucs…'
        & $pyexe @pipArgs demucs==4.1.0 numpy *>> $log
        Check 'Installation de Demucs impossible'
        Step 'Téléchargement du modèle de séparation…'
        & $pyexe -c "from demucs.pretrained import get_model; get_model('htdemucs')" *>> $log
        Check 'Téléchargement du modèle impossible'
        Set-Content -LiteralPath (Join-Path $py 'demucs-ok.txt') -Value 'ok'
    }
}

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
    if ($script:sepProc -or (Get-SepState) -ne 'pret') { return }
    $it = $null
    foreach ($q in $sepQueue) { if ($q.status -eq 'attente') { $it = $q; break } }
    if (-not $it) { return }
    $h = Find-Hist $it.id
    if (-not $h -or -not (Test-Path -LiteralPath (Get-HistPath $h))) { $it.status = 'erreur'; $it.error = 'Fichier introuvable'; return }
    $it.tmp = Join-Path $Data ('sep-' + $it.id)
    if (Test-Path -LiteralPath $it.tmp) { Remove-Item -LiteralPath $it.tmp -Recurse -Force }
    [void](New-Item -ItemType Directory -Path $it.tmp)
    $it.status = 'separation'; $it.phase = 'demucs'; $it.progress = 0
    $a = @('-m', 'demucs', '--two-stems', 'vocals', '-n', 'htdemucs', '-o', $it.tmp, '--filename', '{stem}.{ext}', (Get-HistPath $h))
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
$script:upd = @{ state = 'inconnu'; latest = ''; error = '' }   # inconnu | verif | ajour | dispo | erreur
$script:updJob = $null
$script:restartAfter = $false
$CanSelfUpdate = [bool]($Installed -and $SelfPath)

function ConvertTo-Ver([string]$v) {
    $p = @(($v.Trim() -split '\.') | Where-Object { $_ -match '^\d+$' })
    while ($p.Count -lt 3) { $p += '0' }
    return [version]($p[0..2] -join '.')
}
function New-WebClient {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
    $wc = New-Object Net.WebClient
    $wc.Headers['Cache-Control'] = 'no-cache'
    $wc.Headers['User-Agent'] = "YT-MP3/$AppVersion"
    return $wc
}

function Start-UpdateCheck {
    if ($script:updJob -and $script:updJob.State -eq 'Running') { return }
    $script:upd.state = 'verif'; $script:upd.error = ''
    $script:updJob = Start-Job -ArgumentList $UpdateBase -ScriptBlock {
        param($base)
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
        $wc = New-Object Net.WebClient
        $wc.Headers['Cache-Control'] = 'no-cache'
        ($wc.DownloadString("$base/version.txt?t=" + [DateTime]::UtcNow.Ticks)).Trim()
    }
}

function Update-UpdateCheck {
    $j = $script:updJob
    if (-not $j -or $j.State -eq 'Running') { return }
    try {
        $v = ''
        if ($j.State -eq 'Completed') { $v = [string](@(Receive-Job $j -ErrorAction Stop) | Select-Object -Last 1) }
        if ($v -match '^\d+(\.\d+){0,3}$') {
            $script:upd.latest = $v
            $script:upd.state = $(if ((ConvertTo-Ver $v) -gt (ConvertTo-Ver $AppVersion)) { 'dispo' } else { 'ajour' })
        } else {
            $script:upd.state = 'erreur'
            $script:upd.error = 'Impossible de joindre le site des mises à jour (connexion Internet ?)'
        }
    } catch {
        $script:upd.state = 'erreur'
        $script:upd.error = 'Impossible de joindre GitHub pour vérifier les mises à jour (connexion Internet ?). Réessaie plus tard.'
    }
    Remove-Job $j -Force -ErrorAction SilentlyContinue
    $script:updJob = $null
}

# Télécharge la nouvelle version, la contrôle, puis remplace l'ancienne. Renvoie un message d'erreur, ou '' si tout va bien.
function Invoke-SelfUpdate {
    if (-not $CanSelfUpdate) { return 'La mise à jour automatique fonctionne avec la version installée de YT MP3.' }
    if ($script:proc -or $script:sepProc -or @($queue | Where-Object { $_.status -eq 'attente' }).Count) {
        return 'Attends la fin des téléchargements et séparations en cours, puis relance la mise à jour.'
    }
    $tmp = $SelfPath + '.new'
    try {
        $wc = New-WebClient
        $wc.DownloadFile("$UpdateBase/yt-mp3.ps1?t=" + [DateTime]::UtcNow.Ticks, $tmp)
        # Contrôles : c'est bien YT MP3, dans une version plus récente, et le script est valide
        $txt = [IO.File]::ReadAllText($tmp, [Text.Encoding]::UTF8)
        $m = [regex]::Match($txt, "(?m)^\`$AppVersion = '([0-9.]+)'")
        if (-not $m.Success) { throw 'Le fichier reçu n''est pas YT MP3.' }
        if ((ConvertTo-Ver $m.Groups[1].Value) -le (ConvertTo-Ver $AppVersion)) { throw 'Aucune version plus récente sur GitHub.' }
        $errs = $null
        [void][Management.Automation.Language.Parser]::ParseFile($tmp, [ref]$null, [ref]$errs)
        if ($errs -and $errs.Count) { throw 'le fichier reçu est incomplet ou abîmé, ta version actuelle est conservée. Réessaie dans quelques minutes.' }
        foreach ($f in @('app.ico', 'desinstaller.ps1')) {   # fichiers annexes : facultatifs
            try { $wc.DownloadFile("$UpdateBase/$($f)?t=" + [DateTime]::UtcNow.Ticks, (Join-Path $Root "$f.new")); Move-Item -LiteralPath (Join-Path $Root "$f.new") -Destination (Join-Path $Root $f) -Force } catch {}
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
    if ($headers['content-length']) { $len = [int]$headers['content-length'] }
    $bodyStart = $headEnd + 4
    while (($all.Length - $bodyStart) -lt $len) {
        $n = $ns.Read($buf, 0, $buf.Length)
        if ($n -le 0) { break }
        $ms.Write($buf, 0, $n)
        $all = $ms.ToArray()
    }
    $body = ''
    if ($len -gt 0) { $body = [Text.Encoding]::UTF8.GetString($all, $bodyStart, [math]::Min($len, $all.Length - $bodyStart)) }
    return @{
        Method = $first[0].ToUpper()
        Path   = ($first[1] -split '\?')[0]
        Origin = $headers['origin']
        Range  = $headers['range']
        Body   = $body
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
        update = @{ state = $script:upd.state; latest = $script:upd.latest; error = $script:upd.error; canApply = $CanSelfUpdate }
        separation = @{ state = (Get-SepState); step = (Get-SepStep); error = $script:sepInstallError }
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
            # Qualité : automatique (selon la source) ou forcée dans les paramètres
            $auto = $script:settings.quality -eq 'auto'
            $quality = 192
            if (-not $auto) { $quality = [int]$script:settings.quality }
            foreach ($u in @($body.urls)) {
                $u = ([string]$u).Trim()
                if ($u -match '^https?://[^\s"]+$') {
                    [void]$queue.Add([PSCustomObject]@{
                        id = [guid]::NewGuid().ToString('N').Substring(0, 10); url = $u; quality = $quality
                        status = 'attente'; progress = 0; title = ''; uploader = ''; duration = ''; vid = ''; file = ''; error = ''
                        attempt = 0; blocked = $false; auto = $auto; analysed = $false; phase = ''
                        srcAbrRaw = ''; srcCodecRaw = ''; srcAbr = 0; srcCodec = ''; normalized = $false
                        thumb = ''; seconds = 0; rawArtist = ''; rawTrack = ''; cleanArtist = ''; cleanTitle = ''; cleaned = $false; trimmed = $false
                    })
                }
            }
            Start-Next
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
        '/api/checkupdate' { Start-UpdateCheck }
        '/api/update' {
            $err = Invoke-SelfUpdate
            if ($err) { Send-Json $ctx @{ error = $err }; return }
            Send-Json $ctx @{ ok = $true; restarting = $true }; return
        }
        '/api/sepinstall' { if ((Get-SepState) -ne 'installation') { Start-SepInstall } }
        '/api/separate' {
            if ((Find-Hist $id) -and -not (Find-Sep $id)) {
                [void]$sepQueue.Add([PSCustomObject]@{ id = $id; status = 'attente'; progress = 0; error = ''; phase = ''; tmp = '' })
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

        # Fermeture automatique quand la fenêtre est fermée et qu'il n'y a plus rien à faire
        $pending = @($queue | Where-Object { $_.status -eq 'attente' }).Count -gt 0 -and (Get-SetupState) -ne 'erreur'
        if (-not $script:proc -and -not $pending -and -not $script:sepProc -and -not $script:searchProcs.Count) {
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
