#!/bin/bash

# KK2f-DELSIM Pipeline Script
# Usage: ./run_kk2f_pipeline.sh [num_events] [job_id] [output_dir] [isr_mode] [energy]

set -e  # Exit on any error

# Parse arguments
NUM_EVENTS=${1:-3000}
JOB_ID=${2:-$(date +%Y%m%d_%H%M%S)}
OUTPUT_DIR=${3:-/work/output}
ISR_MODE=${4:-"on"}  # "on" or "off"
ENERGY=${5:-91.187}  # Center-of-mass energy in GeV (default: Z pole)

# Convert OUTPUT_DIR to absolute path if relative
if [[ "$OUTPUT_DIR" != /* ]]; then
    OUTPUT_DIR="$(pwd)/$OUTPUT_DIR"
fi

echo "=== KK2f-DELSIM Pipeline Starting ==="
echo "Events to generate: $NUM_EVENTS"
echo "Job ID: $JOB_ID"
echo "Output directory: $OUTPUT_DIR"
echo "ISR mode: $ISR_MODE"
echo "Center-of-mass energy: $ENERGY GeV"
echo "Working directory: $(pwd)"
echo "========================================"

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Generate unique random seeds from JOB_ID
# Extract cluster and process IDs from job_ISRon_X_Y or job_ISRoff_X_Y format
BASE_NRUN=50000
if [[ "$JOB_ID" =~ ([0-9]+)_([0-9]+) ]]; then
    CLUSTER_ID=${BASH_REMATCH[1]}
    PROCESS_ID=${BASH_REMATCH[2]}
    KK2F_NRUN=$((BASE_NRUN + (CLUSTER_ID % 800)*100 + PROCESS_ID))
    DELSIM_NRUN=$((BASE_NRUN + (CLUSTER_ID % 800)*100 + PROCESS_ID + 1))  # +1 offset from KK2f
else
    HASH_VALUE=$(echo "$JOB_ID" | cksum | cut -d' ' -f1)
    KK2F_NRUN=$((BASE_NRUN + HASH_VALUE % 88000))
    DELSIM_NRUN=$((BASE_NRUN + (HASH_VALUE % 88000) + 1))
fi

echo "Random seeds:"
echo "  KK2f NRUN: $KK2F_NRUN"
echo "  DELSIM NRUN: $DELSIM_NRUN"

# Step 1: Prepare KK2f workspace in /tmp
TEMP_DIR="/tmp/kk2f_${JOB_ID}"
mkdir -p "$TEMP_DIR"
cd "$TEMP_DIR"

echo "=== Setting up KK2f workspace ==="
cp /work/kk2f_build/kk2f_qq.exe .
cp /work/kk2f_build/.KK2f_defaults .
cp /work/kk2f_build/DelKK.inp .
cp /work/kk2f_build/kk2f.inp fort.5
cp -r /work/kk2f_build/input .

# Create fort.19 with UNIQUE NRUN for each job
cat > fort.19 <<EOF
LIST
LABO 'LYON'
NRUN $KK2F_NRUN
NEVT $NUM_EVENTS
ECMS $ENERGY
IFRM 10
KHAD 1
KBCF 0402
KDCY 0402
END
EOF

echo "Generated fort.19 with unique NRUN $KK2F_NRUN:"
cat fort.19

# CRITICAL: Set ISR mode by modifying ONLY .KK2f_defaults line 49
# KeyISR=1 for ISR ON, KeyISR=0 for ISR OFF. NB: KeyISR only toggles ISR -- the matrix-element
# scheme is CEEX (KeyGPS=1, KeyINT=2, per-quark vmaxGPS=0.99 in .KK2f_defaults), NOT EEX.
echo ""
echo "=== Configuring ISR mode ==="
if [ "$ISR_MODE" = "on" ]; then
    KEYISR_VALUE=1
    echo "Setting KeyISR=1 (ISR ON; matrix element = CEEX via KeyGPS=1)"
else
    KEYISR_VALUE=0
    echo "Setting KeyISR=0 (ISR OFF)"
fi

# Modify KeyISR in .KK2f_defaults line 49 only
sed -i "49s/              [0-2]/              ${KEYISR_VALUE}/" .KK2f_defaults

# Verify KeyISR setting
echo "KeyISR setting in .KK2f_defaults line 49:"
sed -n '49p' .KK2f_defaults

echo ""
echo "=== Running KK2f event generation ==="

# CRITICAL: Clean old outputs and cache files before running
# fort.51/fort.52 are integration grids - must delete when switching ISR mode
rm -f lund.output fort.51 fort.52 fort.61 fort.62 kk2f.log

# Run KK2f
./kk2f_qq.exe > kk2f.log 2>&1

# Check if KK2f succeeded
if [ ! -f "lund.output" ] || [ ! -s "lund.output" ]; then
    echo "ERROR: KK2f failed to generate events"
    cat kk2f.log | tail -50
    exit 1
fi

# Extract and display cross-section for verification
EVENT_COUNT=$(grep -c "Event listing" kk2f.log || echo 0)
CROSS_SECTION=$(grep "Cross-section:" kk2f.log || echo "Cross-section not found")

echo "✓ KK2f generation completed"
echo "  Events generated: $EVENT_COUNT"
echo "  $CROSS_SECTION"
echo ""
echo "=== ISR Verification ==="
if [ "$ISR_MODE" = "on" ]; then
    echo "Expected x-sec: 200 GeV ~85 pb (ISR enhances via radiative return); Z pole ~30 nb (ISR SUPPRESSES the Born peak by ~29%)"
else
    echo "Expected x-sec: 200 GeV ~20 pb; Z pole ~42 nb (Born Z->hadrons peak; ISR off => no radiative suppression)"
fi
echo "========================================"
echo ""

ls -lh lund.output

# Step 2: retain the native DELKK FADGEN record.  DELKKWRITE emits DELSIM's
# binary format directly; filtering it removes status-11 decays and ancestry.
echo "=== Preserving native DELKK FADGEN record for DELSIM ==="
cp -- lund.output my_events.fadgen
cmp -s lund.output my_events.fadgen || { echo "ERROR: native fadgen copy differs"; exit 1; }

if [ ! -f "my_events.fadgen" ] || [ ! -s "my_events.fadgen" ]; then
    echo "ERROR: native FADGEN copy failed"
    exit 1
fi

echo "✓ Native FADGEN record retained byte-for-byte (decay ancestry preserved)"
ls -lh my_events.fadgen

# Step 3: Set up DELPHI environment
echo "=== Setting up DELPHI environment ==="
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
export LD_LIBRARY_PATH="/usr/lib64:/lib64:$LD_LIBRARY_PATH"

# Verify runsim is available
if ! command -v runsim &> /dev/null; then
    echo "ERROR: runsim not found"
    exit 1
fi
echo "✓ DELPHI environment configured"

# Step 4: Run DELSIM simulation
echo "=== Running DELSIM simulation ==="
DELSIM_EVENTS=$((NUM_EVENTS * 90 / 100))
if [ $DELSIM_EVENTS -lt 1 ]; then
    DELSIM_EVENTS=1
fi

echo "Running DELSIM with $DELSIM_EVENTS events (90% of $NUM_EVENTS)..."
runsim -VERSION v94c -LABO CERN -NRUN $DELSIM_NRUN -EBEAM 45.625 -NEVMAX $DELSIM_EVENTS -gext my_events.fadgen

# Step 5: Collect outputs
echo "=== Collecting outputs ==="
if [ -f "simana.sdst" ]; then
    mv simana.sdst "${OUTPUT_DIR}/simana_${JOB_ID}.sdst"
    echo "✓ Moved simana.sdst"
else
    echo "ERROR: DELSIM failed to produce simana.sdst"
    ls -la
    exit 1
fi

# Clean up temporary files
echo "=== Cleaning up ==="
rm -f simana.fadsim simana.fadana my_events.fadgen *.out *.log fort.* lund.output

# Clean up temp directory
cd /work
rm -rf "$TEMP_DIR"

echo ""
echo "=== Pipeline completed successfully ==="
echo "Configuration:"
echo "  ISR mode: $ISR_MODE (KeyISR=$KEYISR_VALUE)"
echo "  Energy: $ENERGY GeV"
echo "  KK2f NRUN: $KK2F_NRUN"
echo "  DELSIM NRUN: $DELSIM_NRUN"
echo "  $CROSS_SECTION"
echo "Output: ${OUTPUT_DIR}/simana_${JOB_ID}.sdst"
ls -lh "${OUTPUT_DIR}/simana_${JOB_ID}.sdst"
echo "========================================"
