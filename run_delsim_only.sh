#!/bin/bash
# Run ONLY the DELSIM step on a pre-made FADGEN file (my_events.fadgen in CWD).
# Used to validate end-to-end that hepmc2fadgen's fort.26 is ingested by DELSIM.
# Must run INSIDE the delphi-sim .sif with a writable /work. Env block is
# copied verbatim from run_pipeline.sh.
# Usage: run_delsim_only.sh <nevmax> [nrun] [ebeam] [version]
set -e

export PATH="/root/.local/bin:/root/bin:/delphi/releases/almalinux-9-x86_64/latest/scripts:/delphi/scripts:/delphi/releases/almalinux-9-x86_64/latest/bin:/delphi/releases/almalinux-9-x86_64/latest/cern/pro/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:."
export OPGS_RUN_TIME="/delphi/releases/almalinux-9-x86_64/latest/delgra/run_time"
export DELPHI_RELEASE="latest"
export CERN_ROOT="/delphi/releases/almalinux-9-x86_64/latest/cern/pro"
export DELPHI_PAM="/delphi/releases/almalinux-9-x86_64/latest/dstana/161018/src/car"
export DELPHI_DDB_BIN="/delphi/releases/almalinux-9-x86_64/latest/ddb/bin"
export DELPHI="/delphi/releases/almalinux-9-x86_64/latest/dstana/161018"
export GROUPPATH="/delphi/releases/almalinux-9-x86_64/latest/bin"
export CERN_PAM="/delphi/releases/almalinux-9-x86_64/latest/cern/pro/src/car"
export DELPHI_LIB="/delphi/releases/almalinux-9-x86_64/latest/dstana/161018/lib"
export DES_HOME="/delphi/releases/almalinux-9-x86_64/latest/evserv"
export CERN="/delphi/releases/almalinux-9-x86_64/latest/cern"
export CERN_LIB="/delphi/releases/almalinux-9-x86_64/latest/cern/pro/lib"
export DELPHI_BATCAVE="/delphi/pdl"
export OPENPHIGS="/delphi/releases/almalinux-9-x86_64/latest/openphigs"
export DELPHI_BLKD="/delphi/releases/almalinux-9-x86_64/latest/dstana/161018/blkd"
export DELPHI_ZIP="on"
export DELPHI_XRD=""
export DELPHI_DATA_ROOT="/eos/opendata/delphi"
export GRA_PLACE="/delphi/releases/almalinux-9-x86_64/latest/delgra"
export DELPHI_CRA="/delphi/releases/almalinux-9-x86_64/latest/dstana/161018/src/car"
export DELSIM_ROOT="/delphi/releases/almalinux-9-x86_64/latest/simana"
export DELPHI_PATH="/delphi/releases/almalinux-9-x86_64/latest/bin"
export DELPHI_DAT="/delphi/releases/almalinux-9-x86_64/latest/dstana/161018/dat"
export GROUP_DIR="/delphi/releases/almalinux-9-x86_64/latest"
export DELPHI_DDB="/eos/opendata/delphi/condition-data"
export DELPHI_DDB_DIR="/delphi/releases/almalinux-9-x86_64/latest/ddb"
export ADDLIB="/delphi/releases/almalinux-9-x86_64/latest/dstana/161018/blkd/delblkd.o"
export DELPHI_INSTALL_DIR="/delphi"
export DELPHI_BIN="/delphi/releases/almalinux-9-x86_64/latest/bin"
export PYTHIA8DATA="/usr/share/Pythia8/xmldoc"
export LD_LIBRARY_PATH="/usr/lib64:/lib64:$LD_LIBRARY_PATH"

NEVMAX=${1:-10}
NRUN=${2:-100001}
EBEAM=${3:-45.625}
VERSION=${4:-v94c}
# Optional beam-spot override (cm) via env: XYZP="x y z" (centroid), XYZW="wx wy wz" (widths).
# Set -> 2-pass -STITL flow (prerun fills simlocal.title, edit BS, re-run). Unset -> single-pass
# with DELSIM's VERSION-default beam spot (the legacy 94c key4hep behaviour; leaves 94c unchanged).
XYZP="${XYZP:-}"
XYZW="${XYZW:-}"

command -v runsim >/dev/null || { echo "ERROR: runsim not found"; exit 1; }
[ -f my_events.fadgen ] || { echo "ERROR: my_events.fadgen missing in $(pwd)"; exit 1; }

echo "FADGEN input: $(ls -l my_events.fadgen)"
rm -f fort.18 simlocal.title simlocal_edit.title simana.sdst simana.fadana simana.fadsim FOR* 2>/dev/null || true

if [ -n "$XYZP" ] || [ -n "$XYZW" ]; then
    echo "Running DELSIM (beam-spot override, 2-pass): VERSION=$VERSION NRUN=$NRUN EBEAM=$EBEAM NEVMAX=$NEVMAX"
    echo "  XYZP=$XYZP  XYZW=$XYZW"
    # Step A: short prerun so runsim's MakeSimTitle() writes a COMPLETE simlocal.title (with IGENER
    # set for external/-gext input). -STITL on a RAW template leaves placeholders unfilled and DELSIM
    # would run its internal qq generator (IGENER=15, NEVMAX=450) instead of our fadgen.
    echo "--- prerun: fill simlocal.title ---"
    runsim -VERSION "$VERSION" -LABO CERN -NRUN "$NRUN" -EBEAM "$EBEAM" -NEVMAX 5 -gext my_events.fadgen 2>&1 | tail -3
    [ -f simlocal.title ] || { echo "ERROR: prerun did not produce simlocal.title"; exit 1; }
    # Step B: edit the data beam spot into a copy of the resolved title.
    cp simlocal.title simlocal_edit.title
    [ -n "$XYZP" ] && sed -i "s|^XYZP[[:space:]].*|XYZP    $XYZP|" simlocal_edit.title
    [ -n "$XYZW" ] && sed -i "s|^XYZW[[:space:]].*|XYZW    $XYZW|" simlocal_edit.title
    # The prerun baked its OWN (small) NEVMAX into the title, and with -STITL the title's NEVMAX
    # wins over the command line -> pin it back to the requested NEVMAX for the main run.
    sed -i "s|^NEVMAX[[:space:]].*|NEVMAX    $NEVMAX|" simlocal_edit.title
    echo "VAL_TITLE_DUMP_BEGIN"; grep -inE 'nevmax|nevt|xyzp|xyzw|igener' simlocal_edit.title; echo "VAL_TITLE_DUMP_END"
    # Step C: clear prerun artifacts and run the FULL sim with the edited title.
    rm -f simana.fadsim simana.sdst simana.fadana FOR* fort.* simdec.data igtots.logn delsimrn.out88 scanlist.sumr T.FSEQ1 simlocal.title
    ln -sf my_events.fadgen fort.18
    echo "--- main run with edited title (NEVMAX=$NEVMAX) ---"
    runsim -VERSION "$VERSION" -LABO CERN -NRUN "$NRUN" -EBEAM "$EBEAM" -NEVMAX "$NEVMAX" -gext my_events.fadgen -STITL simlocal_edit.title
else
    echo "Running DELSIM: VERSION=$VERSION NRUN=$NRUN EBEAM=$EBEAM NEVMAX=$NEVMAX"
    runsim -VERSION "$VERSION" -LABO CERN -NRUN "$NRUN" -EBEAM "$EBEAM" -NEVMAX "$NEVMAX" -gext my_events.fadgen
fi

echo "=== DELSIM outputs ==="
ls -l simana.sdst simana.fadana 2>&1 || echo "(expected outputs missing)"
