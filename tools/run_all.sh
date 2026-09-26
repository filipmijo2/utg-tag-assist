#!/bin/bash
# Rundkurse fuer alle gespeicherten Karten offline berechnen
cd C:/Users/Filip/AppData/Local/Potassium/workspace
for f in utg_nav_*.json; do
  m=${f#utg_nav_}; m=${m%.json}
  timeout 400 python C:/Users/Filip/utg_repo/tools/circuits.py "$f" "utg_circ_$m.json" 2>&1 | tail -1 | sed "s/^/$m: /"
done
