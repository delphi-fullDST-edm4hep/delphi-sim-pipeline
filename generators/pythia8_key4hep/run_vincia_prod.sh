#!/bin/bash
# Condor production wrapper: Pythia8 + VINCIA, Z->hadrons (91.2 GeV, 94c), ISR on/off -> SDST on EOS.
#
# SDST-ONLY by design: uses closure_gen's NATIVE EventWriter fort.26 (the validated Pythia8->fort.26
# converter, straight from the Pythia event) and runs DELSIM on THAT, bypassing hepmc2fadgen --
# because Vincia's HepMC3 trips HepMC3 ReaderAscii ("not enough implicit vertices", empty-incoming
# vertices). No HepMC3 is saved for Vincia (it is not cleanly readable). A per-job unique seed drives
# both the Pythia RNG (Random:seed) and the DELSIM NRUN.
#
# Args:  <variant: isron|isroff>  <nev>  <clusterid>  <process>
set -uo pipefail
REPO=/afs/cern.ch/work/z/zhangj/delphi-pythia8-pipeline
GENDIR="$REPO/generators/pythia8_key4hep"

VARIANT="${1:?usage: run_vincia_prod.sh <isron|isroff> <nev> <clusterid> <process> [prodver=v94c] [date]}"
NEV="${2:?nev}"; CL="${3:?clusterid}"; PR="${4:?process}"
PROD_VER="${5:-${PROD_VER:-v94c}}"      # v94c = 1994/94c, DELSIM-default BS (legacy) | v95d = 1995/95d + 95d data BS
DATE="${6:-${DATE:-260607}}"
case "$PROD_VER" in
  v94c) EOSBASE=/eos/experiment/eealliance/Samples/DELPHI/1994/91.2/MC/94c; DELSIM_VERSION=v94c ;;
  v95d) EOSBASE=/eos/experiment/eealliance/Samples/DELPHI/1995/91.2/MC/95d; DELSIM_VERSION=v95d
        export XYZP="-0.32026 0.11079 -0.7589" XYZW="0.01208 0.01219 0.30102" ;;  # 95d data beam spot (cm)
  *) echo "FATAL: unknown PROD_VER='$PROD_VER' (expected v94c|v95d)"; exit 2 ;;
esac
echo "=== vincia_prod CONFIG: PROD_VER=$PROD_VER VERSION=$DELSIM_VERSION DATE=$DATE BS='${XYZP:-<default>}' EOSBASE=$EOSBASE ==="
case "$VARIANT" in
  isron)  CFGBASE="$GENDIR/config_vincia_isr_on.txt";  EOSNAME=pythia8_vincia_isron  ;;
  isroff) CFGBASE="$GENDIR/config_vincia_isr_off.txt"; EOSNAME=pythia8_vincia_isroff ;;
  *) echo "FATAL: unknown variant '$VARIANT' (expected isron|isroff)"; exit 2 ;;
esac

SEED=$(( (CL % 80000) * 10000 + PR ))      # unique per job, kept < 8e8 (Pythia Random:seed max ~9e8)
TAG="${CL}_${PR}"
WORK="${_CONDOR_SCRATCH_DIR:-/tmp/$$}/work"; mkdir -p "$WORK"
SDST_DEST="$EOSBASE/SDST/$EOSNAME/$DATE"; mkdir -p "$SDST_DEST"
GEN_BUFFER=$(( (NEV + 9) / 10 )); NEV_GEN=$(( NEV + GEN_BUFFER ))   # 10% over-generation (EOF-hang guard)

echo "=== vincia_prod: variant=$VARIANT nev=$NEV(+$GEN_BUFFER buf=$NEV_GEN) seed=$SEED tag=$TAG host=$(hostname) ==="
[ -r "$CFGBASE" ] || { echo "FATAL: cannot read $CFGBASE (AFS token?)"; exit 3; }

# Per-job config = the variant config + an explicit Pythia seed (closure_gen sets a time+pid seed
# BEFORE loading the config, so this readString overrides it -> guaranteed-distinct events per job).
CFG="$WORK/config_${VARIANT}_${TAG}.txt"
cp "$CFGBASE" "$CFG"
printf '\n# per-job seed (injected by run_vincia_prod.sh)\nRandom:setSeed = on\nRandom:seed = %d\n' "$SEED" >> "$CFG"

# 1) generate (closure_gen) -> WORK/fort.26 (native EventWriter) + WORK/events.hepmc3 (ignored)
bash "$GENDIR/generate.sh" "$NEV_GEN" "$CFG" "$WORK"
[ -s "$WORK/fort.26" ] || { echo "ERROR: closure_gen produced no fort.26"; exit 1; }

# 2) DELSIM on the native fort.26 -> SDST  (NEVMAX = NEV target; NRUN from the seed; XYZP/XYZW exported above)
export DELSIM_NRUN=$(( 3000 + SEED % 88000 ))
bash "$REPO/m2_delsim_lxplus.sh" "$WORK/fort.26" "$NEV" 45.5935 "$DELSIM_VERSION"
rc=$?

DST="$WORK/fort.26.sdst"
if [ -s "$DST" ]; then
  cp -f "$DST" "$SDST_DEST/${EOSNAME}_${TAG}.sdst" \
    && echo "SDST -> $SDST_DEST/${EOSNAME}_${TAG}.sdst ($(stat -c%s "$DST") B)" || rc=1
else
  echo "ERROR: no SDST at $DST"; rc=1
fi
exit $rc
