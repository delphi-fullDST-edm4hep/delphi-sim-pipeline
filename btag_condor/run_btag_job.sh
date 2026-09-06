#!/bin/bash
# Self-contained b-tagging-production job: generate Z->bb (Pythia8/key4hep) -> hepmc2fadgen
# (status 11 + V, the fix branch) -> DELSIM (.sif, LUDECV switch) -> edm4hep, copy edm4hep to EOS.
# Runs on a condor worker (needs CVMFS + singularity). All work in worker scratch; only the
# edm4hep is kept. Args: <nev> <proc> <ludecv TRUE|FALSE> <eos_dest> <seed_base>
set -uo pipefail
NEV="${1:?nev}"; PROC="${2:?process}"; LUDECV="${3:?TRUE|FALSE}"; DEST="${4:?eos dest}"; BASE="${5:?seed base}"
SEED=$(( BASE + PROC ))
REPO=/afs/cern.ch/work/z/zhangj/delphi-pythia8-pipeline
SIF=$REPO/delphi-sim.sif
CONV=/afs/cern.ch/work/z/zhangj/edm4hep_build_prod/delphi_sdst_pass
CFG=$REPO/generators/pythia8/config_z_bb.txt
KEY4HEP=/cvmfs/sw.hsf.org/key4hep/setup.sh
export PATH=/cvmfs/oasis.opensciencegrid.org/mis/apptainer/bin:$PATH
command -v singularity >/dev/null 2>&1 || { command -v apptainer >/dev/null 2>&1 || { echo "FATAL: no singularity/apptainer"; exit 20; }; }

OUT=bb_${SEED}.edm4hep.root
W="${_CONDOR_SCRATCH_DIR:-$(mktemp -d /tmp/btag.XXXXXX)}/btag_$SEED"; mkdir -p "$W"; cd "$W" || exit 21
echo "=== btag job: nev=$NEV seed=$SEED ludecv=$LUDECV dest=$DEST host=$(hostname) $(date) ==="

# 1) generate NEV+10% events -> events.hepmc3 (key4hep sourced in a child shell only)
NGEN=$(( NEV + (NEV+9)/10 ))
( set +u; source "$KEY4HEP" -r 2026-04-08 >/dev/null 2>&1; set -u
  PYTHIA_SEED=$SEED "$REPO/generators/pythia8_key4hep/closure_gen" "$NGEN" "$CFG" > gen.log 2>&1 )
[ -s events.hepmc3 ] || { echo "FATAL: no events.hepmc3"; tail -20 gen.log; exit 22; }
echo "  generated $(grep -c '^E ' events.hepmc3) events -> events.hepmc3"

# 2) hepmc2fadgen (fix branch: status 11 + V) -> my_events.fadgen (rpath-self-contained)
"$REPO/hepmc2fadgen" events.hepmc3 my_events.fadgen > conv_fadgen.log 2>&1
[ -s my_events.fadgen ] || { echo "FATAL: hepmc2fadgen produced no fadgen"; tail -20 conv_fadgen.log; exit 23; }
grep -E "tagged K\(,1\)=11|WARNING" conv_fadgen.log | tail -3

# 3) DELSIM in the .sif via the shared driver; LUDECV switch + per-job NRUN. Output SDST in scratch.
# 94c DATA beam spot (cm), same override as every production driver (run_pipeline.sh / run_*_prod.sh):
# DELSIM's v94c default beam spot is NOT centred on the data one -> reco PV / impact parameters would be off.
export XYZP="${XYZP:--0.29911 0.14225 -0.6121}" XYZW="${XYZW:-0.01052 0.00512 0.1349}"
export LUDECV DELSIM_NRUN=$(( 3000 + SEED % 88000 ))
echo "  DELSIM: LUDECV=$LUDECV NRUN=$DELSIM_NRUN beam spot XYZP=($XYZP) XYZW=($XYZW) cm"
bash "$REPO/m2_delsim_lxplus.sh" "$W/my_events.fadgen" "$NEV" 45.5935 v94c "$W/out.sdst" > delsim.log 2>&1
rc=$?
[ -s "$W/out.sdst" ] || { echo "FATAL: DELSIM produced no SDST (rc=$rc)"; tail -25 delsim.log; exit 24; }
echo "  DELSIM: $(grep -c 'Selected DST records' delsim.log) tag; $(grep 'Selected DST records' delsim.log | tail -1)"

# 4) SDST -> edm4hep (delphi + key4hep in a child shell)
( set +u; source /cvmfs/delphi.cern.ch/setup.sh >/dev/null 2>&1; source "$KEY4HEP" -r 2026-04-08 >/dev/null 2>&1; set -u
  "$CONV" "$W/out.sdst" "$W/$OUT" > conv_edm.log 2>&1 )
sz=$(stat -c%s "$W/$OUT" 2>/dev/null || echo 0)
[ "$sz" -gt 500000 ] || { echo "FATAL: edm4hep too small ($sz B)"; tail -25 conv_edm.log; exit 25; }
echo "  edm4hep: $OUT = $sz B; $(grep -o 'wrote [0-9]* events' conv_edm.log | tail -1)"

# 5) publish to EOS (worker has forwarded token via SendCredential)
mkdir -p "$DEST"
cp "$W/$OUT" "$DEST/$OUT" && echo "PUBLISHED $DEST/$OUT ($sz B) $(date)" || { echo "FATAL: EOS copy failed -> $DEST/$OUT"; exit 26; }
# 5b) keep the GEN record (the fadgen fed to DELSIM; first NEV events = the simulated ones), gzipped
mkdir -p "$DEST/gen"
if gzip -c my_events.fadgen > gen.fadgen.gz && cp gen.fadgen.gz "$DEST/gen/bb_${SEED}.fadgen.gz"; then
  echo "  GEN record: $DEST/gen/bb_${SEED}.fadgen.gz ($(stat -c%s gen.fadgen.gz) B)"
else echo "WARNING: GEN record copy failed (edm4hep already published)"; fi
cd /; rm -rf "$W"
