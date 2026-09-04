#!/bin/bash

# DELPHI-Pythia8 Pipeline Script
# Usage: ./run_pipeline.sh [num_events] [job_id] [output_dir] [config_file]

set -e  # Exit on any error

# Set up complete DELPHI environment (all variables from working container)
echo "Setting up DELPHI environment..."
export PATH="/root/.local/bin:/root/bin:/delphi/releases/almalinux-9-x86_64/latest/scripts:/delphi/scripts:/delphi/releases/almalinux-9-x86_64/latest/bin:/delphi/releases/almalinux-9-x86_64/latest/cern/pro/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:."

# Set all DELPHI environment variables
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

# Also add after setting DELPHI environment:
echo "=== Checking Pythia8 Data ==="
echo "PYTHIA8DATA: $PYTHIA8DATA"
ls -la "$PYTHIA8DATA" 2>/dev/null || echo "Pythia8 data directory not found"
find /usr -name "xmldoc" -type d 2>/dev/null | head -5

# Verify runsim is available
if ! command -v runsim &> /dev/null; then
    echo "ERROR: runsim not found"
    echo "PATH: $PATH"
    exit 1
fi
echo "✓ DELPHI environment configured, runsim found at: $(which runsim)"

# Updated parameter handling with config file support.
# NUM_EVENTS is the DELSIM target. Pythia over-generates by PYTHIA_BUFFER
# events (default = 10% of NUM_EVENTS, rounded up) so DELSIM still reaches
# NEVMAX even if a handful of generator events are skipped — otherwise
# runsim waits for events that never arrive and never exits.
NUM_EVENTS=${1:-3000}
JOB_ID=${2:-$(date +%Y%m%d_%H%M%S)}
OUTPUT_DIR=${3:-/work/output}
CONFIG_FILE=${4:-""}
DELSIM_VERSION=${5:-"v94c"}
E_BEAM=${6:-"45.625"}
PYTHIA_BUFFER=${PYTHIA_BUFFER:-$(( (NUM_EVENTS + 9) / 10 ))}
[ "$PYTHIA_BUFFER" -lt 1 ] && PYTHIA_BUFFER=1
PYTHIA_EVENTS=$((NUM_EVENTS + PYTHIA_BUFFER))
# Beam-spot override for DELSIM (XYZP centroid, XYZW widths, both in cm).
# Per-period defaults from data BS measurements; widths converted µm -> cm:
#   94c : centroid (-0.29911, 0.14225, -0.6121) cm
#         widths   (105.2, 51.2, 1349.0) µm = (0.01052, 0.00512, 0.1349) cm
#   95d : centroid (-0.32026, 0.11079, -0.7589) cm
#         widths   (120.8, 121.9, 3010.2) µm = (0.01208, 0.01219, 0.30102) cm
# Override per-job with XYZP / XYZW env vars.
case "$DELSIM_VERSION" in
    v94c)
        XYZP_DEFAULT="-0.29911 0.14225 -0.6121"
        XYZW_DEFAULT="0.01052 0.00512 0.1349"
        ;;
    v95d)
        XYZP_DEFAULT="-0.32026 0.11079 -0.7589"
        XYZW_DEFAULT="0.01208 0.01219 0.30102"
        ;;
    *)
        echo "WARNING: no per-period BS defaults for DELSIM_VERSION=$DELSIM_VERSION; falling back to 94c values" >&2
        XYZP_DEFAULT="-0.29911 0.14225 -0.6121"
        XYZW_DEFAULT="0.01052 0.00512 0.1349"
        ;;
esac
XYZP="${XYZP:-$XYZP_DEFAULT}"
XYZW="${XYZW:-$XYZW_DEFAULT}"

echo "DELSIM version: $DELSIM_VERSION"
echo "Beam energy: $E_BEAM"

# Generate variable NRUN for DELSIM based on job_id and time
# This ensures different random seeds for DELSIM across jobs
BASE_NRUN=3000
if [[ "$JOB_ID" =~ ^[0-9]+$ ]]; then
    # If JOB_ID is numeric, use it directly
    DELSIM_NRUN=$((BASE_NRUN + JOB_ID % 88000))  # Keep within reasonable range
else
    # If JOB_ID is string (like timestamp), hash it to get number
    HASH_VALUE=$(echo "$JOB_ID" | cksum | cut -d' ' -f1)
    DELSIM_NRUN=$((BASE_NRUN + HASH_VALUE % 88000))
fi

echo "=== DELPHI-Pythia8 Pipeline Starting ==="
echo "DELSIM target: $NUM_EVENTS events (Pythia generates $PYTHIA_EVENTS = +$PYTHIA_BUFFER buffer)"
echo "Job ID: $JOB_ID"
echo "Output directory: $OUTPUT_DIR"
if [ -n "$CONFIG_FILE" ]; then
    echo "Pythia config file: $CONFIG_FILE"
else
    echo "Pythia config: default (Z->hadrons)"
fi
echo "DELSIM NRUN: $DELSIM_NRUN"
echo "Working directory: $(pwd)"
echo "========================================="

# Change to work directory (replaces your manual 'cd /work')
cd /work

# Step 1: Smart Pythia generator compilation check
echo "=== Checking Pythia8 Generator ==="
if [ -f "pythia8_generate" ] && [ -x "pythia8_generate" ]; then
    echo "✅ Using existing pythia8_generate binary"
elif [ -w "." ]; then
    echo "Directory writable, compiling..."
    if make clean && make pythia8_generate; then
        echo "✅ Compilation successful"
    else
        echo "❌ Compilation failed"
        exit 1
    fi
else
    echo "❌ No binary found and directory not writable"
    exit 1
fi

# Verify compilation succeeded
if [ ! -f "./pythia8_generate" ]; then
    echo "ERROR: Compilation failed"
    exit 1
fi

# Add this to your script RIGHT BEFORE compilation check:
echo "=== Environment at Runtime ==="
echo "PWD: $(pwd)"
echo "USER: $(whoami)"
echo "LD_LIBRARY_PATH: $LD_LIBRARY_PATH"
echo "PATH: $PATH"
echo "PYTHIA8DATA: $PYTHIA8DATA"

echo "=== Pre-Pythia Debug ==="
echo "LD_LIBRARY_PATH: $LD_LIBRARY_PATH"
echo "Checking pythia8_generate dependencies:"
ldd ./pythia8_generate 2>/dev/null || echo "ldd failed"
echo "File permissions:"
ls -la pythia8_generate
echo "=== Starting Pythia ==="

# Optional B-hadron veto, OFF by default (opt-in). Set VETO_PDG_CSV=541 (etc.)
# to reject events containing those |PDG|; empty = no veto.
VETO_PDG_CSV="${VETO_PDG_CSV:-}"

# Retry budget as a multiple of the requested event count. The default of 3 is
# for the unbiased run; a veto that keeps only a small fraction of events needs
# far more, and pythia8_generate now FAILS rather than writing a short fort.26.
# Measured acceptances within the Z->bb lane, for sizing:
#   VETO_PDG_CSV=521                        -> 32.8%  (factor ~10)
#   VETO_PDG_CSV=511,521                    ->  2.1%  (factor ~150)
#   VETO_PDG_CSV=511,521,5122,5132,5232,5332 -> 0.98% (factor ~300)
MAX_ATTEMPT_FACTOR="${MAX_ATTEMPT_FACTOR:-3}"

# Step 2: Generate events with optional config file
echo "Step 2: Generating $PYTHIA_EVENTS events (DELSIM target $NUM_EVENTS + buffer $PYTHIA_BUFFER)..."
[ -n "$VETO_PDG_CSV" ] && echo "B-hadron veto: $VETO_PDG_CSV (attempt factor $MAX_ATTEMPT_FACTOR)"
if [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ]; then
    echo "Using config file: $CONFIG_FILE"
    cat "$CONFIG_FILE"
    echo "--- End of config file ---"
    ./pythia8_generate $PYTHIA_EVENTS "$CONFIG_FILE" "$VETO_PDG_CSV" "$MAX_ATTEMPT_FACTOR"
else
    echo "Using default configuration"
    ./pythia8_generate $PYTHIA_EVENTS "" "$VETO_PDG_CSV" "$MAX_ATTEMPT_FACTOR"
fi

# ADD DEBUGGING HERE:
echo "=== DEBUG: Pythia generation completed ==="
echo "Pythia exit code: $?"
echo "Current directory contents:"
ls -la
echo "Looking for fort.* files:"
ls -la fort.* 2>/dev/null || echo "No fort.* files found"
echo "Looking for *.fadgen files:"
ls -la *.fadgen 2>/dev/null || echo "No .fadgen files found"
echo "Working directory: $(pwd)"
echo "Disk space:"
df -h .
echo "=== END DEBUG ==="

# Check if events were generated
if [ ! -f "fort.26" ]; then
    echo "ERROR: No events generated (fort.26 missing)"
    exit 1
fi

# Count lines in fort.26 to verify
EVENT_COUNT=$(wc -l < fort.26)
echo "Generated event file contains $EVENT_COUNT lines"

# Step 3: Prepare for DELSIM (replaces your manual 'mv fort.26 my_events.fadgen')
echo "Step 3: Preparing DELSIM input..."
mv fort.26 my_events.fadgen

# Step 4: Run DELSIM simulation with variable NRUN
echo "Step 4: Running DELSIM simulation..."
DELSIM_EVENTS=$NUM_EVENTS
if [ $DELSIM_EVENTS -lt 1 ]; then
    DELSIM_EVENTS=1
fi

echo "Running DELSIM with $DELSIM_EVENTS events (Pythia produced $PYTHIA_EVENTS) and NRUN=$DELSIM_NRUN..."
if [ -n "$XYZP" ] || [ -n "$XYZW" ]; then
    echo "  XYZP = $XYZP"
    echo "  XYZW = $XYZW"
    echo "  (BS-override mode: prerun -> edit simlocal.title -> re-run with -STITL)"
    # Step A: prerun without -STITL so runsim's MakeSimTitle() can
    # substitute its placeholders ({nrun}, IGENER, ISEEDG, NEVMAX, ...)
    # into a complete simlocal.title. -STITL alone copies the raw
    # template, leaves placeholders unfilled, and DELSIM ends up
    # running its internal qq generator (IGENER=15, NEVMAX=450)
    # instead of our fadgen input.
    echo "--- Step 4a: prerun (generate simlocal.title) ---"
    runsim -VERSION $DELSIM_VERSION -LABO CERN -NRUN $DELSIM_NRUN -EBEAM $E_BEAM -NEVMAX $DELSIM_EVENTS -gext my_events.fadgen 2>&1 | tail -3
    if [ ! -f simlocal.title ]; then
        echo "ERROR: prerun did not produce simlocal.title" >&2
        exit 1
    fi
    # Step B: edit XYZP/XYZW into a copy of the resolved title.
    cp simlocal.title simlocal_edit.title
    [ -n "$XYZP" ] && sed -i "s|^XYZP[[:space:]].*|XYZP    $XYZP|" simlocal_edit.title
    [ -n "$XYZW" ] && sed -i "s|^XYZW[[:space:]].*|XYZW    $XYZW|" simlocal_edit.title
    echo "--- BS override applied ---"
    grep -E '^(XYZP|XYZW)[[:space:]]' simlocal_edit.title
    # Step C: clean prerun artifacts and re-run with -STITL.
    rm -f simana.fadsim simana.sdst simana.fadana FOR* fort.* \
          simdec.data igtots.logn delsimrn.out88 scanlist.sumr \
          T.FSEQ1 simlocal.title
    ln -sf my_events.fadgen fort.18
    echo "--- Step 4b: main run with edited title ---"
    runsim -VERSION $DELSIM_VERSION -LABO CERN -NRUN $DELSIM_NRUN -EBEAM $E_BEAM -NEVMAX $DELSIM_EVENTS -gext my_events.fadgen -STITL simlocal_edit.title
else
    echo "  (default v94c BS centroid -- no override)"
    # Run runsim
    runsim -VERSION $DELSIM_VERSION -LABO CERN -NRUN $DELSIM_NRUN -EBEAM $E_BEAM -NEVMAX $DELSIM_EVENTS -gext my_events.fadgen
fi

# Step 5: Collect outputs (move instead of copy to save disk space)
echo "Step 5: Collecting outputs..."

if [ -f "simana.sdst" ]; then
    mv simana.sdst "${OUTPUT_DIR}/simana_${JOB_ID}.sdst"
    echo "✓ Moved simana.sdst"
fi

# Also preserve the DELANA full-DST output (simana.fadana). It carries the
# per-track 3-D hits (PA.TETP / TEID / TEOD / TEFA / TEFB) that the shortDST
# (.sdst) throws away — needed by downstream hit-based refitting / particle-
# flow analyses. The fadana is small (~0.5 MB for 30 events) compared to the
# raw fadsim it is derived from, so cost is modest.
if [ -f "simana.fadana" ]; then
    mv simana.fadana "${OUTPUT_DIR}/simana_${JOB_ID}.fadana"
    echo "✓ Moved simana.fadana"
fi

# Clean up the big raw DELSIM simulation file (fadsim) and the scratch bits.
echo "Step 6: Cleaning up large files..."
rm -f simana.fadsim my_events.fadgen *.out *.log fort.* FOR*
echo "✓ Cleaned up unnecessary files"

echo "=== Pipeline completed successfully ==="
echo "Configuration used:"
if [ -n "$CONFIG_FILE" ]; then
    echo "  Pythia config: $CONFIG_FILE"
else
    echo "  Pythia config: default"
fi
echo "  DELSIM NRUN: $DELSIM_NRUN"
echo "  Events generated by Pythia: $PYTHIA_EVENTS (target $NUM_EVENTS + buffer $PYTHIA_BUFFER)"
echo "  Events processed by DELSIM: $DELSIM_EVENTS"
echo "Output directory: $OUTPUT_DIR"
echo "Files created:"
ls -la "$OUTPUT_DIR"
echo "========================================="
