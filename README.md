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
| **Finten-Sound** | Spielt 0,25 s nach jeder gelungenen Finte einen Sound — nur lokal, kein Voicechat |
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

Gespielt wird ein zufälliger Eintrag, 0,25 s nach der Finte, und nur wenn man
dabei nicht gefangen wurde. Der Sound läuft ausschließlich lokal — kein
Mikrofon, keine Übertragung an andere Spieler.

## Diagnose

`ENV.diag()` gibt eine Auswertung aus und schreibt sie nach `utg_diag.txt`:
Trefferquote je Fortbewegungsart (gehen, Durchgang, Sprung, Leiter, Schiene,
Zipline, Trampolin), wie viel Prozent jedes berechneten Weges tatsächlich
abgefahren wurde, und warum Wege enden. `ENV.diagReset()` setzt zurück.
