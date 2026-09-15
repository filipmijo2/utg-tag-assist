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
| RightControl | GUI aus-/einblenden |

## Was drin ist

- Nähe-Speedboost beim Weglaufen, Reichweiten-/Trefferkegel-Rampe beim Fangen
- Autopilot: Flucht, Jagd, Streifen, Wandverfolgung bei Sackgassen, Routenplanung
- Parkour: Wallride-Kletterketten, Leitern, Ziplines, Jumppads, SwingBars, Rails
- Landerollen (C), Tempo-Slides, Höhen-Sucher (Bäume/Vorsprünge/Bälle)
- AYIP-Manöver: 180°-Burner, Double-Back, Squeeze, Bamboozle, Roll-Cut, Corner-Peel
- Fail-Log mit 6 s Vorlauf in `utg_tag_log.txt`

`utg_tag_autoexec.lua` optional in den autoexec-Ordner legen: startet automatisch, aber nur in diesem Spiel.
