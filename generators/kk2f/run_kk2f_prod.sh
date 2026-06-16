#!/bin/bash
# Condor production wrapper: KK2f (kk2f4146) e+e- -> q qbar hadronic at the Z pole, ISR on/off
# -> SDST on EOS. Modeled on generators/pythia8_key4hep/run_default_prod.sh.
#
# Matrix-element scheme is CEEX (coherent exponentiation): KeyGPS=1, KeyINT=2 (initial-final
# interference), per-quark vmaxGPS=0.99 in the image's .KK2f_defaults. kk2f_gen_only.sh only
# toggles KeyISR for ISR on/off, so CEEX is preserved in BOTH the isron and isroff variants.
#
# Two-stage, two-container (so kk2f SDSTs are detector-level COMPARABLE to pythia8/sherpa/vincia):
#   1) GENERATION in the kk2f .sif (kk2f_gen_only.sh: kk2f_qq.exe + fixer) -> fadgen
#   2) DELSIM in delphi-sim.sif via m2_delsim_lxplus.sh -> SDST  (IDENTICAL DELSIM + the same
#      2-pass -STITL beam-spot override used by the pythia8/sherpa samples)
#
# Args: <isron|isroff> <nev> <clusterid> <process> [prodver=v94c] [date=260607]
set -uo pipefail
REPO=/afs/cern.ch/work/z/zhangj/delphi-pythia8-pipeline
GENDIR="$REPO/generators/kk2f"
KK2F_SIF="$GENDIR/delphi-kk2f.sif"

VARIANT="${1:?usage: run_kk2f_prod.sh <isron|isroff> <nev> <clusterid> <process> [prodver=v94c] [date=260607]}"
NEV="${2:?nev}"; CL="${3:?clusterid}"; PR="${4:?process}"
PROD_VER="${5:-${PROD_VER:-v94c}}"      # v94c = 1994/94c + 94c data BS | v95d = 1995/95d + 95d data BS
DATE="${6:-${DATE:-260607}}"
ECMS=91.187; EBEAM=45.5935              # match pythia8/sherpa/vincia (eCM 91.187 / EBEAM 45.5935)

case "$PROD_VER" in
  v94c) EOSBASE=/eos/experiment/eealliance/Samples/DELPHI/1994/91.2/MC/94c; DELSIM_VERSION=v94c
        export XYZP="-0.29911 0.14225 -0.6121" XYZW="0.01052 0.00512 0.1349" ;;  # 94c data beam spot (cm)
  v95d) EOSBASE=/eos/experiment/eealliance/Samples/DELPHI/1995/91.2/MC/95d; DELSIM_VERSION=v95d
        export XYZP="-0.32026 0.11079 -0.7589" XYZW="0.01208 0.01219 0.30102" ;;  # 95d data beam spot (cm)
  *) echo "FATAL: unknown PROD_VER='$PROD_VER' (expected v94c|v95d)"; exit 2 ;;
esac
case "$VARIANT" in
  isron)  ISR=on;  EOSNAME=kk2f_isron  ;;
  isroff) ISR=off; EOSNAME=kk2f_isroff ;;
  *) echo "FATAL: unknown variant '$VARIANT' (expected isron|isroff)"; exit 2 ;;
esac

SEED=$(( (CL % 80000) * 10000 + PR ))      # kk2f NRUN + drives DELSIM_NRUN; <8e8, per-job unique
TAG="${CL}_${PR}"
WORK="${_CONDOR_SCRATCH_DIR:-/tmp/$$}/work"; mkdir -p "$WORK"
SDST_DEST="$EOSBASE/SDST/$EOSNAME/$DATE"; mkdir -p "$SDST_DEST"
GEN_BUFFER=$(( (NEV + 9) / 10 )); NEV_GEN=$(( NEV + GEN_BUFFER ))   # 10% over-generation (EOF guard)

echo "=== kk2f_prod CONFIG: variant=$VARIANT(ISR=$ISR) PROD_VER=$PROD_VER VERSION=$DELSIM_VERSION DATE=$DATE ==="
echo "=== nev=$NEV(+$GEN_BUFFER buf=$NEV_GEN) seed=$SEED tag=$TAG BS='${XYZP}' ecms=$ECMS host=$(hostname) ==="
[ -s "$KK2F_SIF" ] || { echo "FATAL: missing $KK2F_SIF (build it first)"; exit 3; }
command -v singularity >/dev/null || { echo "FATAL: singularity not on worker"; exit 3; }

# 1) GENERATE in the kk2f .sif -> $WORK/my_events.fadgen
echo "=== stage 1: kk2f generation in $KK2F_SIF ==="
singularity exec --bind /afs:/afs --bind /eos:/eos --bind "$WORK:/genout" "$KK2F_SIF" \
  bash "$GENDIR/kk2f_gen_only.sh" "$NEV_GEN" "$ISR" "$ECMS" "$SEED" /genout/my_events.fadgen
[ -s "$WORK/my_events.fadgen" ] || { echo "ERROR: kk2f gen produced no fadgen"; exit 1; }

# 2) DELSIM in delphi-sim.sif (same as pythia8; XYZP/XYZW -> 2-pass beam-spot override) -> SDST
echo "=== stage 2: DELSIM in delphi-sim.sif (NRUN from seed, BS override) ==="
export DELSIM_NRUN=$(( 3000 + SEED % 88000 ))
bash "$REPO/m2_delsim_lxplus.sh" "$WORK/my_events.fadgen" "$NEV" "$EBEAM" "$DELSIM_VERSION"
rc=$?

DST="$WORK/my_events.fadgen.sdst"
if [ -s "$DST" ]; then
  cp -f "$DST" "$SDST_DEST/${EOSNAME}_${TAG}.sdst" \
    && echo "SDST -> $SDST_DEST/${EOSNAME}_${TAG}.sdst ($(stat -c%s "$DST") B)" || rc=1
else
  echo "ERROR: no SDST at $DST"; rc=1
fi
exit $rc
