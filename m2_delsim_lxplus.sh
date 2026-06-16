#!/bin/bash
# m2_delsim_lxplus.sh — run the DELSIM step (subshell B) on a FADGEN/fort.26 file, inside the
# delphi-sim .sif, on lxplus. Deliberately sources NO key4hep: env isolation by
# construction — the fort.26 is the ONLY thing that crosses into the container, so there is no
# need to bind-mount /cvmfs/sw.hsf.org or otherwise expose the generator stack to DELSIM.
#
# Must run on a host with singularity/apptainer (lxplus, NOT the bare VM). Drive it from the VM:
#   ssh -o PreferredAuthentications=gssapi-with-mic -o GSSAPIDelegateCredentials=yes \
#       zhangj@lxplus.cern.ch 'bash <repo>/m2_delsim_lxplus.sh <fadgen> [nev] [ebeam]'
#
# Usage: m2_delsim_lxplus.sh <fadgen_file> [nevmax=20] [ebeam=45.5935] [version=v94c] [out_sdst]
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIF="$REPO/delphi-sim.sif"

FADGEN="${1:?usage: m2_delsim_lxplus.sh <fadgen_file> [nevmax] [ebeam] [version] [out_sdst]}"
NEVMAX="${2:-20}"
EBEAM="${3:-45.5935}"          # eCM 91.187 / 2
VERSION="${4:-${DELSIM_VERSION:-v94c}}"   # arg 4, else $DELSIM_VERSION env (used by the sherpa/run_generic path), else v94c
OUT_SDST="${5:-${FADGEN}.sdst}"   # NB: append, don't strip — AFS paths contain dots (cern.ch)
NRUN="${DELSIM_NRUN:-100001}"     # DELSIM run number = its RNG seed; vary per job in production
                                  # (export DELSIM_NRUN) so detector-sim fluctuations decorrelate.

[ -s "$FADGEN" ] || { echo "ERROR: fadgen file not found/empty: $FADGEN"; exit 1; }
[ -s "$SIF" ]    || { echo "ERROR: .sif not found: $SIF"; exit 1; }
command -v singularity >/dev/null || { echo "ERROR: singularity not on this host (run on lxplus)"; exit 1; }

aklog 2>/dev/null || true
echo "HOST=$(hostname)  fadgen=$FADGEN  nev=$NEVMAX ebeam=$EBEAM ver=$VERSION nrun=$NRUN"
echo "host LD_LIBRARY_PATH (must be clean, no key4hep): '${LD_LIBRARY_PATH:-<empty>}'"

SCRATCH_ROOT="$(mktemp -d /tmp/m2_delsim.XXXXXX)"
SCRATCH="$SCRATCH_ROOT/work"; mkdir -p "$SCRATCH"
trap 'rm -rf "$SCRATCH_ROOT"' EXIT

echo "=== stage image /work -> $SCRATCH ==="
singularity exec --bind "$SCRATCH:/host_scratch" "$SIF" cp -a /work/. /host_scratch/ 2>/dev/null || \
  echo "(warn: /work stage returned nonzero; continuing)"
cp "$FADGEN" "$SCRATCH/my_events.fadgen"
cp "$REPO/run_delsim_only.sh" "$SCRATCH/run_delsim_only.sh"; chmod +x "$SCRATCH/run_delsim_only.sh"

# Optional beam-spot override -> inject into the container. APPTAINERENV_/SINGULARITYENV_ is the
# guaranteed way to pass env across singularity exec; run_delsim_only.sh picks XYZP/XYZW up and
# switches to its 2-pass -STITL flow. Empty -> single-pass (VERSION-default beam spot).
if [ -n "${XYZP:-}" ]; then export APPTAINERENV_XYZP="$XYZP" SINGULARITYENV_XYZP="$XYZP"; fi
if [ -n "${XYZW:-}" ]; then export APPTAINERENV_XYZW="$XYZW" SINGULARITYENV_XYZW="$XYZW"; fi
echo "=== DELSIM inside .sif ===  (BS override XYZP='${XYZP:-}' XYZW='${XYZW:-}')"
singularity exec --bind /afs:/afs --bind /eos:/eos --bind "$SCRATCH:/work" "$SIF" \
    bash -lc "cd /work && ./run_delsim_only.sh $NEVMAX $NRUN $EBEAM $VERSION"
RC=$?

echo "=== outputs ==="
ls -l "$SCRATCH"/simana.sdst "$SCRATCH"/simana.fadana 2>&1 || true
if [ -s "$SCRATCH/simana.sdst" ]; then
  cp "$SCRATCH/simana.sdst" "$OUT_SDST" && echo "DST -> $OUT_SDST ($(stat -c%s "$OUT_SDST") bytes)"
else
  echo "ERROR: no simana.sdst produced"; RC=1
fi
exit $RC
