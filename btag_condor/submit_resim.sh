#!/bin/bash
# Re-simulate the private Pythia 8 samples with the per-job data beam spot + the combined-tag converter, reusing the stored
# GEN records (same events as the previous production). Run on lxplus (condor), e.g. from the VM:
#   ssh zhangj@lxplus.cern.ch 'bash /afs/cern.ch/work/z/zhangj/delphi-pythia8-pipeline/btag_condor/submit_resim.sh Zbb'
# Usage: submit_resim.sh <sample> [njobs|missing] [nev=5000]     sample in Zbb zqq_inclusive zcc zss zlight_ud
#   njobs   : submit procs 0..njobs-1 (default: the sample's full job count)
#   missing : submit only the procs whose edm4hep is not on EOS and which are not queued/running in condor
# Per-run knobs are passed with `condor_submit -append`, no personal .sub files are kept in the repo.
# EXTRA_ENV="DELSIM_NRUN_OFFSET=1" adds job environment (e.g. to re-run a seed whose DELSIM hangs in one event).
# The .sif is read from EOS (SIF env) and condor's stdout/stderr go to /dev/null: the job writes its own log to
# <dest>/logs/ (1200 jobs reading the AFS .sif + the AP writing 1200 .out files to AFS held 959 jobs, errno 110).
set -euo pipefail
S="${1:?sample}"; NJ="${2:-}"; NEV="${3:-5000}"
SIF="${SIF:-/eos/experiment/eealliance/Users/zhangj/edm4hepSimBTagging/_bin/delphi-sim.sif}"
B=/eos/experiment/eealliance/Users/zhangj/edm4hepSimBTagging
REPO="${REPO:-/afs/cern.ch/work/z/zhangj/delphi-pythia8-pipeline}"
case "$S" in
  Zbb)           CFG=config_z_bb.txt;    BASE=1000000; N=200;;
  zqq_inclusive) CFG=config_z_qq.txt;    BASE=3000000; N=400;;
  zcc)           CFG=config_z_cc.txt;    BASE=4000000; N=200;;
  zss)           CFG=config_z_ss.txt;    BASE=5000000; N=200;;
  zlight_ud)     CFG=config_z_light.txt; BASE=6000000; N=200;;
  *) echo "unknown sample $S"; exit 1;;
esac
DEST="${DEST_OVERRIDE:-$B/$S}"; LOGD=/afs/cern.ch/work/z/zhangj/btag_condorOut/resim_$S; mkdir -p "$LOGD"
[ -s "$REPO/generators/pythia8/$CFG" ] || { echo "no config $REPO/generators/pythia8/$CFG"; exit 1; }
[ -s "$SIF" ] || { echo "no .sif at $SIF"; exit 1; }
[ -d "$DEST/gen" ] || echo "note: no $DEST/gen (GEN records) -> jobs will regenerate"
LABEL=${CFG#config_z_}; LABEL=${LABEL%.txt}
if [ "$NJ" = missing ]; then
  # procs still queued/running for this destination (any cluster) are not resubmitted
  ACTIVE=$(condor_q -name bigbird25.cern.ch -constraint "JobStatus==1 || JobStatus==2" -af Args 2>/dev/null | awk -v d="$DEST" '$4==d {print $2}' | sort -u)
  LIST=$(mktemp); for p in $(seq 0 $((N-1))); do s=$((BASE+p)); [ -s "$DEST/${LABEL}_${s}.edm4hep.root" ] && continue; echo "$ACTIVE" | grep -qx "$p" && continue; echo $p >> "$LIST"; done
  NMISS=$(wc -l < "$LIST"); echo "$S: $NMISS of $N procs missing (and not active)"; [ "$NMISS" -gt 0 ] || { rm -f "$LIST"; exit 0; }
  QUEUE="queue PROC from $LIST"; ARGS="$NEV \$(PROC) TRUE $DEST $BASE $CFG"
else
  NJ="${NJ:-$N}"; QUEUE="queue $NJ"; ARGS="$NEV \$(Process) TRUE $DEST $BASE $CFG"
fi
echo "submitting ($QUEUE): $S cfg=$CFG base=$BASE nev=$NEV dest=$DEST sif=$SIF"
# classads = the validated model (README §8.1 / §8.8): vanilla, AFS .sif + EOS via the forwarded credential,
# nothing transferred back; previous production: ~2h20 CPU per 5000-event job -> "tomorrow" (24 h)
condor_submit -name bigbird25.cern.ch \
  -append "universe = vanilla" \
  -append "executable = $REPO/btag_condor/run_btag_job.sh" \
  -append "arguments = $ARGS" \
  -append "environment = \"REPO=$REPO SIF=$SIF REUSE_GEN=1 BEAMSPOT_MODE=per-job KEEP_SDST=1 ${EXTRA_ENV:-}\"" \
  -append "should_transfer_files = YES" \
  -append "when_to_transfer_output = ON_EXIT" \
  -append "transfer_output_files = \"\"" \
  -append "MY.SendCredential = true" \
  -append "getenv = False" \
  -append "requirements = (HasSingularity =?= true)" \
  -append "request_memory = 4GB" \
  -append "request_cpus = 1" \
  -append "request_disk = 15GB" \
  -append "+JobFlavour = \"tomorrow\"" \
  -append "output = /dev/null" \
  -append "error = /dev/null" \
  -append "log = $LOGD/\$(ClusterId).log" \
  -append "$QUEUE" /dev/null
[ "${LIST:-}" ] && rm -f "$LIST" || true
