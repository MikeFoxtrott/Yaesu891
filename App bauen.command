#!/bin/bash
# Baut die App und schreibt die Ausgabe zusätzlich nach build.log
cd "$(dirname "$0")"
./build_app.sh 2>&1 | tee build.log
echo "EXIT=${PIPESTATUS[0]}" >> build.log
