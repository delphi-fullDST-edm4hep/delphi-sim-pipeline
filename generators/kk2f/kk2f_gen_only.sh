#!/bin/bash
# Runs INSIDE the kk2f .sif. KK2f GENERATION ONLY: kk2f_qq.exe -> lund.output -> fixer -> fadgen.
# NO DELSIM here (DELSIM runs separately in delphi-sim.sif so kk2f SDSTs match pythia8/sherpa).
# Mirrors steps 1-6 of run_kk2f_pipeline.sh; binaries baked at /work/kk2f_build in the image.
# Args: <nev> <isr: on|off> <ecms_gev> <kk2f_nrun> <out_fadgen_path>
set -uo pipefail
NEV="${1:?nev}"; ISR="${2:?isr on|off}"; ECMS="${3:?ecms}"; KKNRUN="${4:?kk2f nrun}"; OUT="${5:?out fadgen}"

WORK="$(mktemp -d /tmp/kk2fgen.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/kk2fgen.XXXXXX")"
cd "$WORK"
cp /work/kk2f_build/kk2f_qq.exe .
cp /work/kk2f_build/.KK2f_defaults .
cp /work/kk2f_build/DelKK.inp .
cp /work/kk2f_build/kk2f.inp fort.5
cp -r /work/kk2f_build/input .
cp /work/kk2f_fadgen_fixer .

# fort.19: unique NRUN (kk2f RNG seed), inclusive hadronic (IFRM 10, KHAD 1) -- matches the
# validated run_kk2f_pipeline.sh / kk2f4146_qqpy config.
cat > fort.19 <<EOF
LIST
LABO 'LYON'
NRUN $KKNRUN
NEVT $NEV
ECMS $ECMS
IFRM 10
KHAD 1
KBCF 0402
KDCY 0402
END
EOF

# ISR toggle: KeyISR on line 49 of .KK2f_defaults (1=ISR on, 0=off). KeyISR ONLY toggles ISR; the
# matrix-element scheme stays CEEX (KeyGPS=1, KeyINT=2, per-quark vmaxGPS=0.99) -- not EEX.
# Clean integration grids (fort.51/52 must be rebuilt whenever KeyISR changes).
KEYISR=1; [ "$ISR" = off ] && KEYISR=0
sed -i "49s/              [0-2]/              ${KEYISR}/" .KK2f_defaults
echo "KeyISR line 49 -> '$(sed -n '49p' .KK2f_defaults)' (ISR=$ISR)"
rm -f lund.output fort.51 fort.52 fort.61 fort.62 kk2f.log

echo "=== kk2f_qq.exe (nev=$NEV ecms=$ECMS nrun=$KKNRUN) on $(hostname) ==="
./kk2f_qq.exe > kk2f.log 2>&1 || echo "kk2f_qq.exe returned $?"
[ -s lund.output ] || { echo "ERROR: no lund.output"; tail -60 kk2f.log; exit 1; }
echo "--- KKMC cross-section report (Z-pole sanity: ISR-off ~42 nb [Born Z->had peak], ISR-on ~30 nb [~29% ISR suppression]) ---"
grep -iE 'xsec|x-sec|\[ *pb *\]|\[ *nb *\]|total cross|nanobarn|picobarn|provided' kk2f.log | head -12 || true
echo "--- kk2f.log tail (final KKMC report incl. cross-section) ---"
tail -30 kk2f.log 2>/dev/null || true

./kk2f_fadgen_fixer lund.output my_events.fadgen
[ -s my_events.fadgen ] || { echo "ERROR: fixer produced no fadgen"; exit 1; }
cp my_events.fadgen "$OUT"
echo "GEN OK -> $OUT ($(stat -c%s "$OUT") B)"
cd /; rm -rf "$WORK"
