#!/bin/bash
# Condor production wrapper: Sherpa FIXED-ORDER 2-jet (e+e- -> q qbar, NO CKKW merging) Z->hadrons,
# ISR on/off -> HepMC3 + SDST on EOS. Twin of run_sherpa_prod.sh, but uses the 2-jet cards
# (Sherpa_2jet_isr_on/off.yaml) + sherpa_2jet_* EOS streams, and applies the data beam-spot
# override on BOTH 94c and 95d (matches the kk2f / pythia8_default samples for cross-generator
# comparability -- unlike run_sherpa_prod.sh which leaves 94c BS-default).
# gen (Sherpa) -> hepmc2fadgen -> DELSIM(.sif) via the shared run_generic.sh.
#
# Args:  <isron|isroff>  <nev>  <clusterid>  <process>  [prodver=v94c]  [date=260607]
set -uo pipefail
REPO=/afs/cern.ch/work/z/zhangj/delphi-pythia8-pipeline
VARIANT="${1:?usage: run_sherpa2jet_prod.sh <isron|isroff> <nev> <clusterid> <process> [prodver] [date]}"
NEV="${2:?nev}"; CL="${3:?clusterid}"; PR="${4:?process}"
PROD_VER="${5:-${PROD_VER:-v94c}}"
DATE="${6:-${DATE:-260607}}"
case "$PROD_VER" in
  v94c) EOSBASE=/eos/experiment/eealliance/Samples/DELPHI/1994/91.2/MC/94c; export DELSIM_VERSION=v94c
        export XYZP="-0.29911 0.14225 -0.6121" XYZW="0.01052 0.00512 0.1349" ;;  # 94c data beam spot (cm)
  v95d) EOSBASE=/eos/experiment/eealliance/Samples/DELPHI/1995/91.2/MC/95d; export DELSIM_VERSION=v95d
        export XYZP="-0.32026 0.11079 -0.7589" XYZW="0.01208 0.01219 0.30102" ;;  # 95d data beam spot (cm)
  *) echo "FATAL: unknown PROD_VER='$PROD_VER' (expected v94c|v95d)"; exit 2 ;;
esac
case "$VARIANT" in
  isroff) YAML=Sherpa_2jet_isr_off.yaml; EOSNAME=sherpa_2jet_isroff ;;
  isron)  YAML=Sherpa_2jet_isr_on.yaml;  EOSNAME=sherpa_2jet_isron  ;;
  *) echo "FATAL: unknown variant '$VARIANT' (expected isron|isroff)"; exit 2 ;;
esac
echo "=== sherpa2jet_prod CONFIG: PROD_VER=$PROD_VER VERSION=$DELSIM_VERSION DATE=$DATE BS='${XYZP:-<default>}' EOSBASE=$EOSBASE ==="

SEED=$(( (CL % 90000) * 10000 + PR ))   # unique per job within a cluster; fits 32-bit
TAG="${CL}_${PR}"
WORK="${_CONDOR_SCRATCH_DIR:-/tmp/$$}/work"; mkdir -p "$WORK"
HEPMC3_DEST="$EOSBASE/HEPMC3/$EOSNAME/$DATE"
SDST_DEST="$EOSBASE/SDST/$EOSNAME/$DATE"
mkdir -p "$HEPMC3_DEST" "$SDST_DEST"

echo "=== sherpa2jet_prod: variant=$VARIANT yaml=$YAML nev=$NEV seed=$SEED tag=$TAG host=$(hostname) ==="
[ -r "$REPO/run_generic.sh" ] || { echo "FATAL: no AFS access to $REPO (token?)"; exit 3; }

# The 2-jet Born integrates in ~seconds, so no pre-computed grid is shipped -- Sherpa integrates per
# job (graceful: stage a grid if one is ever added at integ_2jet_<variant>).
INTEG="$REPO/generators/sherpa/integ_2jet_$VARIANT"
if [ -d "$INTEG" ]; then
  cp -r "$INTEG/." "$WORK/" 2>/dev/null && echo "staged integration grid from $INTEG"
else
  echo "NOTE: no pre-integration grid at $INTEG -> Sherpa integrates the 2-jet Born from scratch (fast)"
fi

# gen (Sherpa, ISR config via SHERPA_YAML) -> hepmc2fadgen -> DELSIM (.sif). run_generic.sh's 4th
# arg = seed -> exports SHERPA_SEED (Sherpa -R) and DELSIM_NRUN.
export SHERPA_YAML="$YAML"
bash "$REPO/run_generic.sh" sherpa "$NEV" "$WORK" "$SEED"
rc=$?
echo "run_generic.sh rc=$rc"

HEPMC3="$WORK/events.hepmc3"
SDST="$WORK/fort.26.sdst"
fail=0
if [ -s "$SDST" ]; then
  cp -f "$SDST" "$SDST_DEST/sherpa_2jet_${VARIANT}_${TAG}.sdst" \
    && echo "SDST   -> $SDST_DEST/sherpa_2jet_${VARIANT}_${TAG}.sdst ($(stat -c%s "$SDST") B)" || fail=1
else
  echo "ERROR: no SDST at $SDST"; fail=1
fi
if [ -s "$HEPMC3" ]; then
  cp -f "$HEPMC3" "$HEPMC3_DEST/sherpa_2jet_${VARIANT}_${TAG}.hepmc3" \
    && echo "HepMC3 -> $HEPMC3_DEST/sherpa_2jet_${VARIANT}_${TAG}.hepmc3 ($(stat -c%s "$HEPMC3") B)" || fail=1
else
  echo "WARN: no HepMC3 at $HEPMC3"; fail=1
fi
exit $(( rc != 0 ? rc : fail ))
