#!/bin/bash
# Condor production wrapper: Sherpa Z->hadrons (91.2 GeV, 94c) ISR on/off -> HepMC3 + SDST on EOS.
# Transferred to the worker as the job executable; runs gen -> hepmc2fadgen -> DELSIM in
# worker-LOCAL scratch via the shared run_generic.sh, then copies BOTH the HepMC3 and the SDST to
# the eealliance EOS area. A per-job unique seed (from ClusterId/Process) drives Sherpa (-R) AND
# the DELSIM NRUN, so parallel jobs do not duplicate events / detector fluctuations.
#
# Args:  <variant: isroff|isrin>  <nev>  <clusterid>  <process>
set -uo pipefail
REPO=/afs/cern.ch/work/z/zhangj/delphi-pythia8-pipeline
VARIANT="${1:?usage: run_sherpa_prod.sh <isron|isroff> <nev> <clusterid> <process> [prodver=v94c] [date]}"
NEV="${2:?nev}"; CL="${3:?clusterid}"; PR="${4:?process}"
PROD_VER="${5:-${PROD_VER:-v94c}}"      # v94c = 1994/94c, DELSIM-default BS (legacy) | v95d = 1995/95d + 95d data BS
DATE="${6:-${DATE:-260607}}"
case "$PROD_VER" in
  v94c) EOSBASE=/eos/experiment/eealliance/Samples/DELPHI/1994/91.2/MC/94c; export DELSIM_VERSION=v94c ;;
  v95d) EOSBASE=/eos/experiment/eealliance/Samples/DELPHI/1995/91.2/MC/95d; export DELSIM_VERSION=v95d
        export XYZP="-0.32026 0.11079 -0.7589" XYZW="0.01208 0.01219 0.30102" ;;  # 95d data beam spot (cm)
  *) echo "FATAL: unknown PROD_VER='$PROD_VER' (expected v94c|v95d)"; exit 2 ;;
esac

# NB: sherpa ISR-on variant is 'isron' (the 94c dirs were historically 'isrin'; renamed).
case "$VARIANT" in
  isroff) YAML=Sherpa_isr_off.yaml; EOSNAME=sherpa_isroff ;;
  isron)  YAML=Sherpa_isr_on.yaml;  EOSNAME=sherpa_isron  ;;
  *) echo "FATAL: unknown variant '$VARIANT' (expected isron|isroff)"; exit 2 ;;
esac
echo "=== sherpa_prod CONFIG: PROD_VER=$PROD_VER VERSION=$DELSIM_VERSION DATE=$DATE BS='${XYZP:-<default>}' EOSBASE=$EOSBASE ==="

SEED=$(( (CL % 90000) * 10000 + PR ))   # unique per job within a cluster; fits 32-bit
TAG="${CL}_${PR}"
WORK="${_CONDOR_SCRATCH_DIR:-/tmp/$$}/work"; mkdir -p "$WORK"
HEPMC3_DEST="$EOSBASE/HEPMC3/$EOSNAME/$DATE"
SDST_DEST="$EOSBASE/SDST/$EOSNAME/$DATE"
mkdir -p "$HEPMC3_DEST" "$SDST_DEST"

echo "=== sherpa_prod: variant=$VARIANT yaml=$YAML nev=$NEV seed=$SEED tag=$TAG host=$(hostname) ==="
[ -r "$REPO/run_generic.sh" ] || { echo "FATAL: no AFS access to $REPO (token?)"; exit 3; }

# Stage the pre-computed Sherpa integration grid into the Sherpa run dir ($WORK) so this job
# SKIPS the ~15-min merged integration and goes straight to event generation. Seed-independent;
# Sherpa re-integrates automatically if the grid is absent/mismatched (graceful fallback).
INTEG="$REPO/generators/sherpa/integ_$VARIANT"
if [ -d "$INTEG" ]; then
  cp -r "$INTEG/." "$WORK/" 2>/dev/null && echo "staged integration grid from $INTEG (skip re-integration)"
else
  echo "NOTE: no pre-integration grid at $INTEG -> job will integrate from scratch (~15 min)"
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
  cp -f "$SDST" "$SDST_DEST/sherpa_${VARIANT}_${TAG}.sdst" \
    && echo "SDST   -> $SDST_DEST/sherpa_${VARIANT}_${TAG}.sdst ($(stat -c%s "$SDST") B)" || fail=1
else
  echo "ERROR: no SDST at $SDST"; fail=1
fi
if [ -s "$HEPMC3" ]; then
  cp -f "$HEPMC3" "$HEPMC3_DEST/sherpa_${VARIANT}_${TAG}.hepmc3" \
    && echo "HepMC3 -> $HEPMC3_DEST/sherpa_${VARIANT}_${TAG}.hepmc3 ($(stat -c%s "$HEPMC3") B)" || fail=1
else
  echo "WARN: no HepMC3 at $HEPMC3"; fail=1
fi
exit $(( rc != 0 ? rc : fail ))
