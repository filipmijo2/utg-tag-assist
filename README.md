# UTG Tag Assist

Für **Untitled Tag Game** (PlaceId 14044547200).

## Laden

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/filipmijo2/utg-tag-assist/main/tag_gui.lua"))()
```

## Bedienung

| Element | Wirkung |
|---|---|
| **Autopilot (alles)** | Weglaufen, Fangen/Reichweite, Auto-Tag, Parkour, Blick=Laufrichtung, Wegfindung |
| **AYIP: aus / 1 / 2 / 3** | Juke-Stufen. Aus = ruhig. Höher = mehr und schärfere Haken |
| **Finten-Abstand** | Slider 8–28 Studs: ab welchem Abstand gefintet wird |
| **3rd Person [T]** | Kamera hinter den Charakter, Mausrad = Abstand |
| **Finten-Sound** | Spielt 0,1 s nach jeder gelungenen Finte einen Sound — nur lokal, kein Voicechat |
| RightControl | GUI aus-/einblenden |

## Was drin ist

- Nähe-Speedboost beim Weglaufen, Reichweiten-/Trefferkegel-Rampe beim Fangen
- Autopilot: Flucht, Jagd, Streifen, Wandverfolgung bei Sackgassen, Routenplanung
- Parkour: Wallride-Kletterketten, Leitern, Ziplines, Jumppads, SwingBars, Rails
- Landerollen (C), Tempo-Slides, Höhen-Sucher (Bäume/Vorsprünge/Bälle)
- AYIP-Manöver: 180°-Burner, Double-Back, Squeeze, Bamboozle, Roll-Cut, Corner-Peel
- Fail-Log mit 6 s Vorlauf in `utg_tag_log.txt`

`utg_tag_autoexec.lua` optional in den autoexec-Ordner legen: startet automatisch, aber nur in diesem Spiel.

## Finten-Sound

Läuft ohne Einrichtung: 12 mitgelieferte Sounds aus dem Spiel selbst
(`NoTagBackBreak`, `bonk`, `TrickBoom`, `Woohoo`, `crit`, `buda`,
`YellowFlash`, `win2`, `zoom`, `waaoom`, `Fatality`, `Pichuun`). Die laden
bei jedem Spieler.

Eigene Sounds, beides beliebig lang und alle 5 s automatisch übernommen:

* **Asset-IDs** — eine Nummer je Zeile in `utg_sounds.txt` im Executor-Ordner.
  Sobald dort eine Nummer steht, gelten nur noch die eigenen.
* **Eigene Dateien** — `.mp3` `.ogg` `.wav` `.flac` in den Ordner `utg_sounds`
  im Executor-Ordner legen.

Gespielt wird ein zufälliger Eintrag, 0,1 s nach der Finte, und nur wenn man
dabei nicht gefangen wurde. Der Sound läuft ausschließlich lokal — kein
Mikrofon, keine Übertragung an andere Spieler.

## Diagnose

`ENV.diag()` gibt eine Auswertung aus und schreibt sie nach `utg_diag.txt`:
Trefferquote je Fortbewegungsart (gehen, Durchgang, Sprung, Leiter, Schiene,
Zipline, Trampolin), wie viel Prozent jedes berechneten Weges tatsächlich
abgefahren wurde, und warum Wege enden. `ENV.diagReset()` setzt zurück.

## Finten-Sound im Voicechat (optional)

Roblox überträgt im Voicechat **nur das Mikrofon**. Ein Sound, den das Spiel
selbst abspielt, bleibt immer lokal — daran lässt sich von innen nichts
ändern. Damit andere ihn hören, muss er über ein virtuelles Mikrofon laufen.
Dafür liegt `utg_vc_player.py` bei:

```
tag_gui.lua  --(schreibt utg_vc_play.txt)-->  utg_vc_player.py
utg_vc_player.py  --(spielt Datei)-->  Voicemeeter Input / CABLE Input
Voicemeeter / VB-CABLE  --(als Mikrofon)-->  Roblox  -->  alle hören es
```

**Einmalig einrichten**

1. `pip install sounddevice soundfile`
2. Echte Audiodateien (`.wav .mp3 .ogg .flac`) in den Ordner `utg_sounds` im
   Executor-Verzeichnis legen. Roblox-Asset-IDs helfen hier **nicht** — für
   den Voicechat braucht es Dateien auf der Platte.
3. `utg_vc_start.bat` starten (oder `python -u utg_vc_player.py`). Das
   Programm sucht sich Voicemeeter bzw. VB-CABLE selbst und prüft über die
   Voicemeeter-Fernsteuerung, ob der Weg zum virtuellen Mikrofon (B1) offen
   ist — falls nicht, schaltet es ihn ein.
4. In Roblox: Einstellungen → Audio → Eingabegerät auf `Voicemeeter Out B1`
   (bzw. `CABLE Output`) stellen.

Im Statusfeld des Tools steht dann `VC: an`, solange das Programm läuft.
Fenster zu = wieder nur lokaler Sound, sonst ändert sich nichts.

`python utg_vc_player.py --list` zeigt alle Ausgabegeräte,
`--test` spielt sofort einen Sound zur Kontrolle. Gerät und Lautstärke lassen
sich in `utg_vc_config.json` festnageln.
