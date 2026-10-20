# Mixette

Mixeur audio par application pour la barre de menus macOS : volume, coupure, boost jusqu'à
×4 et choix de la sortie (une ou plusieurs à la fois) **pour chaque app**, plus les
sorties et entrées du système.

Aucun driver, aucune extension : uniquement les *process taps* Core Audio (macOS 14.4+).

## Installation

Télécharger `Mixette.zip` depuis la page **Releases**, décompresser, glisser `Mixette.app`
dans `/Applications`. L'app n'est pas notarisée par Apple : au premier lancement, faire
clic droit › Ouvrir (ou `xattr -dr com.apple.quarantine /Applications/Mixette.app`).

Requiert macOS 14.4 ou plus récent, Mac Apple Silicon.

## Compiler

Seuls les Command Line Tools sont nécessaires (`xcode-select --install`).

```bash
./build.sh && open build/Mixette.app      # toujours via open (TCC)
```

Pour une signature stable (l'autorisation audio survit alors aux recompilations), créer un
fichier `.signing.env`, non versionné :

```bash
SIGN_CN="Nom du certificat de signature"
KC="$HOME/Library/Keychains/mon-trousseau.keychain-db"   # facultatif
KCPASS="…"                                               # facultatif
```

Sans ce fichier, `build.sh` signe en ad hoc.

## Utilisation

Au premier réglage d'une app, macOS demande l'accès « Enregistrement audio du système ».
L'autorisation est liée au certificat (exigence désignée épinglée) : elle survit aux
recompilations.

- **Curseur** : volume de l'app (courbe perceptive, ½ ≈ −12 dB). Le fond clair du curseur
  est un VU-mètre (apps réglées seulement).
- **×1** : boost ×2, ×3, ×4 (limiteur doux), puis retour à ×1.
- **Icône d'appareil** : suivre la sortie par défaut, une seule sortie, ou plusieurs à la fois.
- **Clic droit** sur une app : réinitialiser.
- **Sortie / Entrée** : cliquer un appareil le rend « par défaut » ; volume et mute matériels.

## Fonctionnement

```
processus de l'app ─► tap (muet tant qu'il est lu) ─► entrée d'un agrégat privé
                                                         │ IOProc temps réel : × gain, limiteur
                                   sortie de l'agrégat ◄─┘ = appareil(s) choisi(s)
```

- Un tap n'est posé **que** sur une app dont le réglage diffère du système. Les autres ne
  passent pas par Mixette (aucune latence ajoutée).
- Tap et agrégat sont **privés** : si Mixette quitte ou plante, ils disparaissent et l'app
  retrouve son son d'origine.
- Changement de sortie : fondu enchaîné de 120 ms entre l'ancien et le nouveau tap.
- Une app = tous ses processus audio, regroupés par PID « responsable » (Safari joue depuis
  `com.apple.WebKit.GPU`, Discord depuis ses helpers).

| Fichier | Rôle |
|---|---|
| `Sources/Core/TapController.swift` | tap + agrégat + IOProc, rendu temps réel (rampe, limiteur, répartition L/R) |
| `Sources/Core/Mixer.swift` | modèle, réconciliation apps × réglages → taps, fondu, autorisation |
| `Sources/Core/Processes.swift` | processus audio → apps (regroupement, filtrage des démons) |
| `Sources/Core/Devices.swift` | appareils, défaut, volume/mute matériels, écouteurs |
| `Sources/Core/Permission.swift` | SPI TCC `kTCCServiceAudioCapture` |
| `Sources/Core/Settings.swift` | réglages par app, JSON dans `~/Library/Application Support/Mixette/` |
| `Sources/App/*` | UI SwiftUI (`MenuBarExtra`), mode `--snapshot` |
| `Tools/probe` | sonde Core Audio : processus, appareils, ordre des flux d'un agrégat (`--agg`) |
| `Tools/make_icon.swift` | génère `Resources/AppIcon.icns` |

## Diagnostic

```bash
/usr/bin/log stream --predicate 'subsystem == "com.polat.mixette"'
```

Sous zsh, `log` tout court est une commande interne du shell : il faut `/usr/bin/log`.
Deux secondes après chaque activation, une ligne
`cycles=… entrées=… crête-tap=… crête-sortie=… gain=…→…` permet de vérifier que le son
traverse le tap.

Vérification visuelle sans enregistrement d'écran :

```bash
build/Mixette.app/Contents/MacOS/Mixette --snapshot /tmp/snap   # panel-light.png, panel-dark.png
```

Le bandeau d'autorisation y apparaît toujours, parce que TCC évalue le terminal qui lance le
binaire. C'est normal.

## Limites connues

- Les ~150 premières ms d'un **nouveau** processus passent avant que le tap soit posé.
- Multi-sorties et casques Bluetooth (coupure des micros des sous-appareils) : implémentés,
  non testés sur cette machine (une seule sortie disponible).
- Pas de réglage du volume des sons système, pas de surveillance de tap figé.
