# 🎵 YT MP3

Application Windows pour récupérer en **MP3 propres** des morceaux trouvés sur YouTube, YouTube Music ou SoundCloud — avec un lecteur intégré pensé pour les soirées.

## Ce qu'elle fait

- **Colle un lien ou tape « artiste titre »** : recherche en même temps sur YouTube Music, YouTube et SoundCloud.
- **Qualité adaptée à la source** : analyse la piste audio et choisit le bon débit MP3, sans gonfler les fichiers pour rien.
- **Volume homogène** : tous les morceaux au même niveau sonore (‑14 LUFS), plus besoin de toucher au volume entre deux titres.
- **Que la musique** : intros parlées, scènes de clip et silences retirés.
- **Noms et pochettes propres** : « Artiste - Titre (Clip Officiel) [4K] » devient « Artiste - Titre », pochette carrée.
- **Séparation voix / instrumental** (module optionnel) : deux MP3 en sortie, pour un karaoké ou un remix.
- **Lecteur intégré** : file de lecture, aléatoire, fondu enchaîné entre les morceaux, touches multimédia du clavier.
- **Mises à jour en un clic** depuis l'application.

## Installation

Aucun droit administrateur, aucun fichier `.exe` à télécharger.

1. Ouvre le menu **Démarrer**, tape **PowerShell** et ouvre **Windows PowerShell**.
2. Copie la ligne ci-dessous, colle-la dans la fenêtre (clic droit) et appuie sur **Entrée** :

```powershell
irm https://raw.githubusercontent.com/Guils78440/yt-mp3/main/install.ps1 | iex
```

3. YT MP3 s'ouvre tout seul. Les fois suivantes : icône **YT MP3** sur le bureau ou dans le menu Démarrer.

Le premier lancement télécharge les outils de conversion (environ 200 Mo, une seule fois). Les MP3 sont rangés dans **Musique\YT MP3** (modifiable dans Paramètres).

## Mises à jour

YT MP3 vérifie à chaque démarrage si une nouvelle version existe. Un badge **« Mise à jour »** apparaît alors en haut de la fenêtre : un clic, et l'application se met à jour et redémarre. Ta bibliothèque et tes réglages sont conservés.

## Désinstallation

**Paramètres Windows › Applications › Applications installées › YT MP3 › Désinstaller.** Tes fichiers MP3 ne sont jamais supprimés.

## Bon à savoir

- Fonctionne sous Windows 10 et 11.
- Usage strictement personnel : les conditions d'utilisation de YouTube interdisent le téléchargement en dehors de leurs propres fonctions. Ne récupère que des contenus que tu as le droit de télécharger.
- Le code est entièrement visible dans ce dépôt (`yt-mp3.ps1`) : rien n'est caché.

## Outils utilisés

[yt-dlp](https://github.com/yt-dlp/yt-dlp) · [FFmpeg](https://ffmpeg.org) · [Deno](https://deno.com) · [Demucs](https://github.com/facebookresearch/demucs) · [SponsorBlock](https://sponsor.ajay.app)
