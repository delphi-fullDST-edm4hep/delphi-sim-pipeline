#!/bin/bash
# Re-simulate the private Pythia 8 samples with the per-job data beam spot + the combined-tag converter, reusing the stored
# GEN records (same events as the previous production). Run on lxplus (condor), e.g. from the VM:
#   ssh zhangj@lxplus.cern.ch 'bash /afs/cern.ch/work/z/zhangj/delphi-pythia8-pipeline/btag_condor/submit_resim.sh Zbb'
# Usage: submit_resim.sh <sample> [njobs] [nev=5000]     sample in Zbb zqq_inclusive zcc zss zlight_ud
# Per-run knobs are passed with `condor_submit -append`, no personal .sub files are kept in the repo.
set -euo pipefail
S="${1:?sample}"; NJ="${2:-}"; NEV="${3:-5000}"
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
NJ="${NJ:-$N}"; DEST="${DEST_OVERRIDE:-$B/$S}"; LOGD=/afs/cern.ch/work/z/zhangj/btag_condorOut/resim_$S; mkdir -p "$LOGD"
[ -s "$REPO/generators/pythia8/$CFG" ] || { echo "no config $REPO/generators/pythia8/$CFG"; exit 1; }
[ -d "$DEST/gen" ] || echo "note: no $DEST/gen (GEN records) -> jobs will regenerate"
echo "submitting $NJ jobs: $S cfg=$CFG base=$BASE nev=$NEV dest=$DEST logs=$LOGD"
# classads = the validated model (README §8.1 / §8.8): vanilla, AFS .sif + EOS via the forwarded credential,
# nothing transferred back; previous production: ~2h20 CPU per 5000-event job -> "tomorrow" (24 h)
condor_submit -name bigbird25.cern.ch \
  -append "universe = vanilla" \
  -append "executable = $REPO/btag_condor/run_btag_job.sh" \
  -append "arguments = $NEV \$(Process) TRUE $DEST $BASE $CFG" \
  -append "environment = \"REPO=$REPO REUSE_GEN=1 BEAMSPOT_MODE=per-job KEEP_SDST=1\"" \
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
  -append "output = $LOGD/\$(ClusterId)_\$(Process).out" \
  -append "error = $LOGD/\$(ClusterId)_\$(Process).err" \
  -append "log = $LOGD/\$(ClusterId).log" \
  -append "queue $NJ" /dev/null
