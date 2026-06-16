#!/bin/bash
# Build the kk2f generator .sif from the published docker image, on a condor worker
# (lxplus interactive nohup gets reaped), then copy to AFS next to delphi-sim.sif.
# The .sif is used GEN-ONLY (kk2f_qq.exe + fixer -> fadgen); DELSIM stays in delphi-sim.sif.
set -uo pipefail
DEST=/afs/cern.ch/work/z/zhangj/delphi-pythia8-pipeline/generators/kk2f/delphi-kk2f.sif
IMG=docker://registry.cern.ch/docker.io/jingyucms/delphi-kk2f:v2.16
export APPTAINER_CACHEDIR="$_CONDOR_SCRATCH_DIR/apptcache"
export SINGULARITY_CACHEDIR="$APPTAINER_CACHEDIR"
export APPTAINER_TMPDIR="$_CONDOR_SCRATCH_DIR/apptmp"
mkdir -p "$APPTAINER_CACHEDIR" "$APPTAINER_TMPDIR"
cd "$_CONDOR_SCRATCH_DIR"
echo "=== building kk2f.sif from $IMG on $(hostname) ==="
singularity build kk2f.sif "$IMG"; rc=$?
[ $rc -eq 0 ] && [ -s kk2f.sif ] || { echo "BUILD FAILED rc=$rc"; exit 1; }
sz=$(stat -c%s kk2f.sif); echo "built kk2f.sif = $((sz/1024/1024)) MB"
echo "=== smoke: kk2f binaries present in image? ==="
singularity exec kk2f.sif ls -l /work/kk2f_build/kk2f_qq.exe /work/kk2f_fadgen_fixer 2>&1 | head
echo "=== copy to AFS $DEST ==="
cp kk2f.sif "$DEST" && echo "OK -> $DEST" || { echo "COPY FAILED (AFS quota?)"; exit 2; }
ls -lh "$DEST"
