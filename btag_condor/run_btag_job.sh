#!/bin/bash
# Self-contained b-tagging-production job: [generate Z->qq (Pythia8/key4hep) -> hepmc2fadgen (status 11 + V)]
# -> DELSIM (.sif, LUDECV switch, per-job data beam spot) -> edm4hep (converter with the AABTAG combined tag),
# copy edm4hep (+ SDST + GEN record) to EOS.  Runs on a condor worker (needs CVMFS + singularity/apptainer) or on
# any host with apptainer (VM test).
# Args: <nev> <proc> <ludecv TRUE|FALSE> <eos_dest> <seed_base> [config=config_z_bb.txt]
# The optional 6th argument selects the Pythia config: a bare name is looked up in generators/pythia8/, an absolute
# path is used as given. Output is <label>_<seed>.edm4hep.root, label from the config (config_z_cc.txt -> cc).
#
# Environment knobs (all optional):
#   LABEL          override the label derived from the config (file names <LABEL>_<seed>.*)
#   REPO, SIF, CONV  pipeline checkout, delphi-sim .sif, delphi_sdst_pass binary   [AFS work area / $REPO/delphi-sim.sif / EOS-staged combined-tag binary]
#   REUSE_GEN      1: if $DEST/gen/<LABEL>_<seed>.fadgen.gz exists, feed it to DELSIM instead of regenerating
#                  (same events as the previous production, independent of the generator build)          [1]
#   BEAMSPOT_MODE  per-job: XYZP/XYZW of a 94c data run drawn by seed (beamspot/beamspot_for_seed.py);
#                  global: the 1994 average; env: use XYZP/XYZW as given in the environment              [per-job]
#   KEEP_SDST      1: also publish the DELSIM SDST to $DEST/sdst/ (so converter changes need no re-simulation) [1]
set -uo pipefail
NEV="${1:?nev}"; PROC="${2:?process}"; LUDECV="${3:?TRUE|FALSE}"; DEST="${4:?eos dest}"; BASE="${5:?seed base}"
CFGARG="${6:-config_z_bb.txt}"
SEED=$(( BASE + PROC ))
REPO="${REPO:-/afs/cern.ch/work/z/zhangj/delphi-pythia8-pipeline}"
SIF="${SIF:-$REPO/delphi-sim.sif}"
CONV="${CONV:-/eos/experiment/eealliance/Users/zhangj/edm4hepSimBTagging/_bin/delphi_sdst_pass.btag_combined_2026-09-09}"
case "$CFGARG" in /*) CFG="$CFGARG" ;; *) CFG="$REPO/generators/pythia8/$CFGARG" ;; esac
[ -s "$CFG" ] || { echo "FATAL: Pythia config not found: $CFG"; exit 27; }
LABEL_CFG=$(basename "$CFG" .txt); LABEL_CFG=${LABEL_CFG#config_z_}; LABEL_CFG=${LABEL_CFG#config_}
LABEL="${LABEL:-$LABEL_CFG}"
REUSE_GEN="${REUSE_GEN:-1}"; BEAMSPOT_MODE="${BEAMSPOT_MODE:-per-job}"; KEEP_SDST="${KEEP_SDST:-1}"
KEY4HEP=/cvmfs/sw.hsf.org/key4hep/setup.sh
export PATH=/cvmfs/oasis.opensciencegrid.org/mis/apptainer/bin:$PATH
command -v singularity >/dev/null 2>&1 || command -v apptainer >/dev/null 2>&1 || { echo "FATAL: no singularity/apptainer"; exit 20; }
export SIF

OUT=${LABEL}_${SEED}.edm4hep.root
W="${_CONDOR_SCRATCH_DIR:-$(mktemp -d /tmp/btag.XXXXXX)}/btag_${LABEL}_$SEED"; mkdir -p "$W"; cd "$W" || exit 21
echo "=== btag job: label=$LABEL nev=$NEV seed=$SEED ludecv=$LUDECV dest=$DEST host=$(hostname) $(date) ==="
echo "  repo=$REPO sif=$SIF conv=$CONV cfg=$CFG reuse_gen=$REUSE_GEN beamspot=$BEAMSPOT_MODE keep_sdst=$KEEP_SDST"

# 1-2) GEN record: reuse the stored one when allowed and present, else generate NEV+10% events and convert to fadgen
GENGZ="$DEST/gen/${LABEL}_${SEED}.fadgen.gz"
if [ "$REUSE_GEN" = 1 ] && [ -s "$GENGZ" ]; then
  gunzip -c "$GENGZ" > my_events.fadgen || { echo "FATAL: cannot gunzip $GENGZ"; exit 22; }
  echo "  GEN record reused: $GENGZ -> my_events.fadgen ($(stat -c%s my_events.fadgen) B)"; GEN_REUSED=1
else
  GEN_REUSED=0
  NGEN=$(( NEV + (NEV+9)/10 ))
  ( set +u; source "$KEY4HEP" -r 2026-04-08 >/dev/null 2>&1; set -u
    PYTHIA_SEED=$SEED "$REPO/generators/pythia8_key4hep/closure_gen" "$NGEN" "$CFG" > gen.log 2>&1 )
  [ -s events.hepmc3 ] || { echo "FATAL: no events.hepmc3"; tail -20 gen.log; exit 22; }
  echo "  generated $(grep -c '^E ' events.hepmc3) events -> events.hepmc3"
  "$REPO/hepmc2fadgen" events.hepmc3 my_events.fadgen > conv_fadgen.log 2>&1
  [ -s my_events.fadgen ] || { echo "FATAL: hepmc2fadgen produced no fadgen"; tail -20 conv_fadgen.log; exit 23; }
  grep -E "tagged K\(,1\)=11|WARNING" conv_fadgen.log | tail -3
fi

# 3) beam spot for this job (cm), then DELSIM in the .sif via the shared driver; LUDECV switch + per-job NRUN.
case "$BEAMSPOT_MODE" in
  per-job) eval "$(python3 "$REPO/beamspot/beamspot_for_seed.py" "$SEED" 2> beamspot.txt)" ;;
  global)  eval "$(python3 "$REPO/beamspot/beamspot_for_seed.py" "$SEED" --global 2> beamspot.txt)" ;;
  env)     [ -n "${XYZP:-}" ] && [ -n "${XYZW:-}" ] || { echo "FATAL: BEAMSPOT_MODE=env needs XYZP and XYZW"; exit 27; }; echo "# beam spot from environment" > beamspot.txt ;;
  *)       echo "FATAL: BEAMSPOT_MODE=$BEAMSPOT_MODE (per-job|global|env)"; exit 27 ;;
esac
[ -n "${XYZP:-}" ] && [ -n "${XYZW:-}" ] || { echo "FATAL: beam spot not set"; cat beamspot.txt; exit 27; }
echo "XYZP=\"$XYZP\" XYZW=\"$XYZW\" $(cat beamspot.txt)" > beamspot.txt
export XYZP XYZW LUDECV DELSIM_NRUN=$(( 3000 + SEED % 88000 ))
echo "  DELSIM: LUDECV=$LUDECV NRUN=$DELSIM_NRUN beam spot $(cat beamspot.txt)"
bash "$REPO/m2_delsim_lxplus.sh" "$W/my_events.fadgen" "$NEV" 45.5935 v94c "$W/out.sdst" > delsim.log 2>&1
rc=$?
[ -s "$W/out.sdst" ] || { echo "FATAL: DELSIM produced no SDST (rc=$rc)"; tail -25 delsim.log; exit 24; }
echo "  DELSIM: $(grep -c 'Selected DST records' delsim.log) tag; $(grep 'Selected DST records' delsim.log | tail -1)"
grep -E '^(XYZP|XYZW)[[:space:]]' delsim.log | head -2 | sed 's/^/  title: /'

# 4) SDST -> edm4hep (delphi + key4hep in a child shell); the converter needs its own cwd (PDLINPUT, fort.*)
mkdir -p conv && ( set +u; cd conv; source /cvmfs/delphi.cern.ch/setup.sh >/dev/null 2>&1; source "$KEY4HEP" -r 2026-04-08 >/dev/null 2>&1; set -u
  "$CONV" "$W/out.sdst" "$W/$OUT" > ../conv_edm.log 2>&1 )
sz=$(stat -c%s "$W/$OUT" 2>/dev/null || echo 0)
[ "$sz" -gt 500000 ] || { echo "FATAL: edm4hep too small ($sz B)"; tail -25 conv_edm.log; exit 25; }
echo "  edm4hep: $OUT = $sz B; $(grep -o 'Processed *[0-9]* Selected records' conv_edm.log | tail -1); combined tag: $(grep -c 'Start of Combined tagging' conv_edm.log)"

# 5) publish to EOS (worker has forwarded token via SendCredential)
mkdir -p "$DEST" "$DEST/gen"
cp "$W/$OUT" "$DEST/$OUT" && echo "PUBLISHED $DEST/$OUT ($sz B) $(date)" || { echo "FATAL: EOS copy failed -> $DEST/$OUT"; exit 26; }
cp beamspot.txt "$DEST/gen/${LABEL}_${SEED}.beamspot" 2>/dev/null || echo "WARNING: beamspot sidecar copy failed"
# 5b) keep the GEN record (the fadgen fed to DELSIM; first NEV events = the simulated ones), gzipped, unless reused
if [ "$GEN_REUSED" = 0 ]; then
  if gzip -c my_events.fadgen > gen.fadgen.gz && cp gen.fadgen.gz "$GENGZ"; then echo "  GEN record: $GENGZ ($(stat -c%s gen.fadgen.gz) B)"
  else echo "WARNING: GEN record copy failed (edm4hep already published)"; fi
fi
# 5c) keep the SDST so a converter change never needs a re-simulation
if [ "$KEEP_SDST" = 1 ]; then
  mkdir -p "$DEST/sdst"
  cp "$W/out.sdst" "$DEST/sdst/${LABEL}_${SEED}.sdst" && echo "  SDST kept: $DEST/sdst/${LABEL}_${SEED}.sdst ($(stat -c%s "$W/out.sdst") B)" || echo "WARNING: SDST copy failed"
fi
cd /; rm -rf "$W"
