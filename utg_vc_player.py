"""
UTG VC-Soundboard — spielt Finten-Sounds in den Roblox-Voicechat.

WARUM EIN EXTERNES PROGRAMM?
Roblox uebertraegt im Voicechat ausschliesslich das, was am ausgewaehlten
MIKROFON anliegt. Kein Skript im Spiel kann in diesen Stream schreiben --
ein Sound, den Roblox selbst abspielt, bleibt immer lokal. Der einzige Weg
nach draussen fuehrt also ueber ein virtuelles Mikrofon.

KETTE
    tag_gui.lua  --(schreibt utg_vc_play.txt)-->  dieses Programm
    dieses Programm  --(spielt die Datei)-->  Voicemeeter Input / CABLE Input
    Voicemeeter / VB-CABLE  --(als Mikrofon)-->  Roblox  -->  alle hoeren es

EINRICHTUNG (einmalig)
  1. Audiodateien (.wav .mp3 .ogg .flac) in den Ordner utg_sounds legen
     (derselbe Ordner, den das Skript im Spiel benutzt).
  2. Dieses Programm starten:  python utg_vc_player.py
     Beim ersten Start listet es die Geraete auf und legt eine Konfig an.
  3. In Roblox: Einstellungen -> Audio -> Eingabegeraet auf das virtuelle
     Geraet stellen (bei Voicemeeter: "Voicemeeter Out B1", bei VB-CABLE:
     "CABLE Output").

AUFRUFE
    python utg_vc_player.py            laeuft und wartet auf Ereignisse
    python utg_vc_player.py --list     zeigt alle Ausgabegeraete
    python utg_vc_player.py --test     spielt sofort einen Sound
"""

import json
import os
import random
import sys
import time

try:
    import numpy as np
    import sounddevice as sd
    import soundfile as sf
except ImportError:
    print("Es fehlen Pakete. Bitte einmalig ausfuehren:")
    print("   python -m pip install sounddevice soundfile")
    sys.exit(1)

# Der Executor schreibt in seinen workspace-Ordner; dort liegen auch die
# Ausloeserdatei und die Sounds.
WORKSPACE = os.path.join(os.environ.get("LOCALAPPDATA", ""), "Potassium", "workspace")
TRIGGER = os.path.join(WORKSPACE, "utg_vc_play.txt")
ALIVE = os.path.join(WORKSPACE, "utg_vc_alive.txt")
SOUNDDIR = os.path.join(WORKSPACE, "utg_sounds")
CONFIG = os.path.join(WORKSPACE, "utg_vc_config.json")

EXTS = (".wav", ".mp3", ".ogg", ".flac")

# Kein Sound laeuft laenger als das — gleiche Regel wie im Spiel.
MAX_SECONDS = 2.0

# Bevorzugte Geraete, in dieser Reihenfolge. Voicemeeter zuerst, weil es das
# Mikrofon mitmischt -- damit bleibt Sprechen moeglich, waehrend Sounds laufen.
# VAIO3 zuerst: dessen Gegenstueck heisst "Voicemeeter Out B3" und ist das
# Aufnahmegeraet, das in Roblox als Mikrofon eingestellt wird. Was hier
# hineingespielt wird, kommt dort heraus — unabhaengig davon, wohin der
# Spielton sonst geht.
PREFERRED = [
    "Voicemeeter VAIO3 Input",
    "Voicemeeter AUX Input",
    "Voicemeeter Input (VB-Audio Voicemeeter VAIO)",
    "CABLE Input (VB-Audio Virtual Cable)",
]

# Passendes Aufnahmegeraet zum Ausgabegeraet — nur fuer die Selbstpruefung.
LOOPBACK = {
    "vaio3": "Voicemeeter Out B3",
    "aux": "Voicemeeter Out B2",
    "voicemeeter input": "Voicemeeter Out B1",
    "cable input": "CABLE Output",
}


def output_devices():
    out = []
    for i, d in enumerate(sd.query_devices()):
        if d["max_output_channels"] > 0:
            out.append((i, d["name"], d["max_output_channels"]))
    return out


def list_devices():
    print("Ausgabegeraete:\n")
    for i, name, ch in output_devices():
        mark = ""
        low = name.lower()
        if "voicemeeter in" in low or "voicemeeter input" in low:
            mark = "   <- Voicemeeter (mischt dein Mikro dazu)"
        elif "cable input" in low:
            mark = "   <- VB-CABLE (ersetzt dein Mikro)"
        print(f"  {i:4d}  {name[:60]:60s} {ch}ch{mark}")


def pick_device(cfg):
    """Geraet aus der Konfig, sonst das erste bevorzugte, das es gibt."""
    devs = output_devices()
    want = cfg.get("device")
    if want is not None:
        for i, name, _ in devs:
            if str(want).lower() in name.lower() or str(want) == str(i):
                return i, name
        print(f"Geraet '{want}' nicht gefunden, suche ein passendes ...")
    for pref in PREFERRED:
        for i, name, _ in devs:
            if pref.lower() in name.lower():
                return i, name
    return None, None


def load_config():
    cfg = {"device": None, "volume": 0.9, "cooldown": 0.4}
    if os.path.isfile(CONFIG):
        try:
            with open(CONFIG, "r", encoding="utf-8") as fh:
                cfg.update(json.load(fh))
        except Exception as exc:
            print("Konfig nicht lesbar, nehme Standardwerte:", exc)
    return cfg


def save_config(cfg):
    try:
        os.makedirs(WORKSPACE, exist_ok=True)
        with open(CONFIG, "w", encoding="utf-8") as fh:
            json.dump(cfg, fh, indent=2)
    except Exception as exc:
        print("Konfig nicht schreibbar:", exc)


def sound_files():
    if not os.path.isdir(SOUNDDIR):
        return []
    return [os.path.join(SOUNDDIR, f) for f in sorted(os.listdir(SOUNDDIR))
            if f.lower().endswith(EXTS)]


def play(path, device, volume):
    """Datei auf dem gewaehlten Geraet ausgeben. Blockiert bis zum Ende."""
    data, rate = sf.read(path, dtype="float32", always_2d=True)
    # Auf Stereo bringen: virtuelle Geraete haben oft acht Kanaele, aber
    # PortAudio mappt zwei sauber auf die ersten beiden.
    if data.shape[1] == 1:
        data = np.repeat(data, 2, axis=1)
    elif data.shape[1] > 2:
        data = data[:, :2]
    # Harte Laengenbegrenzung, wie im Spiel: nie laenger als MAX_SECONDS,
    # mit kurzer Ausblende, damit es nicht knackt.
    limit = int(MAX_SECONDS * rate)
    if len(data) > limit:
        data = data[:limit].copy()
        fade = min(int(0.05 * rate), len(data))
        if fade > 0:
            data[-fade:] *= np.linspace(1.0, 0.0, fade)[:, None]
    data = np.clip(data * float(volume), -1.0, 1.0)
    try:
        sd.play(data, samplerate=rate, device=device, blocking=True)
    except Exception:
        # Manche virtuelle Geraete koennen die Abtastrate der Datei nicht;
        # dann auf 48 kHz umrechnen (linear, reicht fuer kurze Sounds voellig)
        target = 48000
        if rate != target:
            n = int(len(data) * target / rate)
            idx = np.linspace(0, len(data) - 1, n)
            data = np.stack([np.interp(idx, np.arange(len(data)), data[:, c])
                             for c in range(data.shape[1])], axis=1).astype("float32")
        sd.play(data, samplerate=target, device=device, blocking=True)


def check_voicemeeter():
    """Prueft ueber die Voicemeeter-Fernsteuerung, ob der virtuelle Eingang
    ueberhaupt auf das virtuelle Mikrofon (B1) geroutet ist — sonst spielt
    alles ins Leere. Kein Zusatzpaket noetig, ctypes reicht.
    Schaltet B1 ein, wenn es aus ist."""
    import ctypes
    dll_path = r"C:\Program Files (x86)\VB\Voicemeeter\VoicemeeterRemote64.dll"
    if not os.path.isfile(dll_path):
        return None
    try:
        dll = ctypes.WinDLL(dll_path)
        dll.VBVMR_GetParameterFloat.argtypes = [ctypes.c_char_p,
                                                ctypes.POINTER(ctypes.c_float)]
        dll.VBVMR_SetParameterFloat.argtypes = [ctypes.c_char_p, ctypes.c_float]
        if dll.VBVMR_Login() < 0:
            return None
        time.sleep(0.3)
        dll.VBVMR_IsParametersDirty()

        def get(name):
            v = ctypes.c_float()
            if dll.VBVMR_GetParameterFloat(name.encode(), ctypes.byref(v)) != 0:
                return None
            return v.value

        # Standard-Voicemeeter: Strip 2 ist der virtuelle Eingang (VAIO)
        strip = 2
        msgs = []
        if get(f"Strip[{strip}].B1") == 0.0:
            dll.VBVMR_SetParameterFloat(f"Strip[{strip}].B1".encode(),
                                        ctypes.c_float(1.0))
            msgs.append("B1 eingeschaltet (Weg zum virtuellen Mikrofon)")
        if get(f"Strip[{strip}].mute") == 1.0:
            dll.VBVMR_SetParameterFloat(f"Strip[{strip}].mute".encode(),
                                        ctypes.c_float(0.0))
            msgs.append("Stummschaltung aufgehoben")
        a1 = get(f"Strip[{strip}].A1")
        dll.VBVMR_Logout()
        return {"ok": True, "fixed": msgs, "hoerst_du_selbst": a1 == 1.0}
    except Exception:
        return None


def verify_loopback(dev_name, device, volume):
    """Spielt einen kurzen Ton und misst gleichzeitig am zugehoerigen
    Aufnahmegeraet mit. Damit steht schwarz auf weiss, ob das, was Roblox
    als Mikrofon benutzt, den Sound wirklich bekommt."""
    low = dev_name.lower()
    rec_name = None
    for key, rec in LOOPBACK.items():
        if key in low:
            rec_name = rec
            break
    if not rec_name:
        return None
    rec_idx = None
    for i, d in enumerate(sd.query_devices()):
        if d["max_input_channels"] > 0 and rec_name.lower() in d["name"].lower():
            rec_idx = i
            break
    if rec_idx is None:
        return {"rec": rec_name, "found": False}

    sr = 48000
    t = np.linspace(0, 0.4, int(sr * 0.4), endpoint=False)
    tone = (np.sin(2 * np.pi * 700 * t) * 0.5).astype("float32")
    sig = np.stack([tone, tone], axis=1)
    peak = {"v": 0.0}

    def cb(indata, frames, time_info, status):
        peak["v"] = max(peak["v"], float(np.abs(indata).max()))

    try:
        with sd.InputStream(device=rec_idx, channels=1, samplerate=sr, callback=cb):
            sd.play(sig * float(volume), samplerate=sr, device=device, blocking=True)
            time.sleep(0.25)
    except Exception as exc:
        return {"rec": rec_name, "found": True, "error": str(exc)}
    return {"rec": rec_name, "found": True, "peak": peak["v"]}


def read_trigger():
    try:
        with open(TRIGGER, "r", encoding="utf-8", errors="ignore") as fh:
            return fh.read().strip()
    except Exception:
        return None


def main():
    args = [a.lower() for a in sys.argv[1:]]
    if "--list" in args:
        list_devices()
        return

    cfg = load_config()
    dev, devname = pick_device(cfg)
    if dev is None:
        print("Kein virtuelles Ausgabegeraet gefunden.\n")
        list_devices()
        print("\nTrage die Nummer oder einen Namensteil in diese Datei ein:")
        print("  " + CONFIG)
        save_config(cfg)
        return
    if cfg.get("device") is None:
        cfg["device"] = devname
        save_config(cfg)

    vm = check_voicemeeter()
    files = sound_files()
    print("UTG VC-Soundboard")
    print(f"  Ausgabe an : {devname}")
    print(f"  Sounds     : {len(files)} Dateien in {SOUNDDIR}")
    print(f"  Ausloeser  : {TRIGGER}")
    if vm:
        for m in vm["fixed"]:
            print(f"  Voicemeeter: {m}")
        print("  Voicemeeter: Weg zum virtuellen Mikrofon ist frei"
              + ("" if vm["hoerst_du_selbst"] else
                 " (du selbst hoerst es NICHT mit — A1 ist aus)"))
    if not files:
        print("\n  KEINE DATEIEN. Lege .wav/.mp3/.ogg/.flac in den Ordner oben.")
        print("  Roblox-Asset-IDs helfen hier nicht — fuer den Voicechat")
        print("  braucht es echte Dateien auf der Platte.")
    if "--auto" in args or cfg.get("device") in (None, "auto"):
        print("Suche ein Geraet, das wirklich beim Mikrofon ankommt ...")
        print("")
        best = None
        for pref in PREFERRED:
            for i, name, _ in output_devices():
                if pref.lower() not in name.lower():
                    continue
                r = verify_loopback(name, i, cfg.get("volume", 0.9))
                if not r or not r.get("found"):
                    print(f"  {name[:45]:45s} -> kein Gegenstueck gefunden")
                    break
                if r.get("error"):
                    print(f"  {name[:45]:45s} -> {r['error'][:40]}")
                    break
                p = r.get("peak", 0.0)
                ok = p > 0.01
                print(f"  {name[:45]:45s} -> {r['rec']:22s} Pegel {p:.3f} "
                      + ("OK" if ok else "nichts"))
                if ok and best is None:
                    best = (i, name, r["rec"])
                break
        if best:
            cfg["device"] = best[1]
            save_config(cfg)
            print("")
            print(f"Gewaehlt: {best[1]}")
            print(f"In Roblox als Mikrofon einstellen: {best[2]}")
        else:
            print("")
            print("Kein Geraet kam durch. Voicemeeter laeuft? VB-CABLE installiert?")
        return

    if "--check" in args:
        r = verify_loopback(devname, dev, cfg.get("volume", 0.9))
        print("")
        if not r:
            print("Kein bekanntes Gegenstueck zu diesem Geraet — bitte selbst pruefen.")
        elif not r.get("found"):
            print(f"Aufnahmegeraet '{r['rec']}' nicht gefunden.")
        elif r.get("error"):
            print(f"Pruefung fehlgeschlagen: {r['error']}")
        else:
            p = r["peak"]
            print(f"Gegenprobe an '{r['rec']}': Pegel {p:.3f}  "
                  + ("KOMMT AN — genau dieses Geraet in Roblox als Mikrofon waehlen"
                     if p > 0.01 else "NICHTS ANGEKOMMEN"))
        return

    if "--test" in args:
        if files:
            f = random.choice(files)
            print(f"\nTestausgabe: {os.path.basename(f)}")
            play(f, dev, cfg.get("volume", 0.9))
            print("fertig.")
        return

    print("\nLaeuft. Fenster offen lassen. Beenden mit Strg+C.\n")
    last = read_trigger()
    last_play = 0.0
    while True:
        try:
            now = time.time()
            # Lebenszeichen, damit das Skript im Spiel anzeigen kann,
            # ob das Soundboard laeuft
            try:
                with open(ALIVE, "w", encoding="utf-8") as fh:
                    fh.write(str(int(now)))
            except Exception:
                pass

            cur = read_trigger()
            if cur and cur != last:
                last = cur
                if now - last_play >= cfg.get("cooldown", 0.4):
                    files = sound_files() or files
                    if files:
                        f = random.choice(files)
                        last_play = now
                        print(time.strftime("%H:%M:%S "), "->", os.path.basename(f))
                        try:
                            play(f, dev, cfg.get("volume", 0.9))
                        except Exception as exc:
                            print("   Fehler beim Abspielen:", exc)
            time.sleep(0.05)
        except KeyboardInterrupt:
            print("\nbeendet.")
            return
        except Exception as exc:
            print("Fehler:", exc)
            time.sleep(1)


if __name__ == "__main__":
    main()
