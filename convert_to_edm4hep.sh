#!/usr/bin/env bash

# Convert a local or FATMEN-resolved DELPHI shortDST with delphi-edm4hep.

set -euo pipefail

usage() {
  cat <<'EOF'
usage: convert_to_edm4hep.sh [options] (--input FILE | --nickname NAME | --pdl FILE) --output FILE

Input (exactly one):
  --input FILE       local shortDST, including simulation produced here
  --nickname NAME    FATMEN dataset nickname resolved by PHDST/fatfind
  --pdl FILE         prebuilt PDLINPUT file, for example from fatfind

Options:
  --output FILE      output EDM4hep ROOT file
  --edmbin DIR       directory containing delphi_sdst_pass and delphi_btag_check
                     (default: $DELPHI_EDM4HEP_BIN, or ../delphi-edm4hep-upstream-dev/build)
  --sample data|mc   checker run-sign contract (default: mc)
  -n, --max-events N
  --no-check         skip delphi_btag_check
  -h, --help

The merged converter emits both stored BTG and recalculated AABTAG. There is
no --btag mode in this interface.
EOF
}

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEFAULT_EDMBIN="$HERE/../delphi-edm4hep-upstream-dev/build"
EDMBIN=${DELPHI_EDM4HEP_BIN:-$DEFAULT_EDMBIN}
INPUT_MODE=
INPUT_VALUE=
OUTPUT=
SAMPLE=mc
MAX_EVENTS=
RUN_CHECK=1

set_input() {
  local mode=$1 value=$2
  if [[ -n $INPUT_MODE ]]; then
    echo "error: only one of --input, --nickname, and --pdl may be given" >&2
    exit 2
  fi
  INPUT_MODE=$mode
  INPUT_VALUE=$value
}

while (($#)); do
  case $1 in
    --input|--nickname|--pdl)
      (($# >= 2)) || { echo "error: $1 requires a value" >&2; exit 2; }
      set_input "${1#--}" "$2"
      shift 2
      ;;
    --output)
      (($# >= 2)) || { echo "error: --output requires a value" >&2; exit 2; }
      OUTPUT=$2
      shift 2
      ;;
    --edmbin)
      (($# >= 2)) || { echo "error: --edmbin requires a value" >&2; exit 2; }
      EDMBIN=$2
      shift 2
      ;;
    --sample)
      (($# >= 2)) || { echo "error: --sample requires data or mc" >&2; exit 2; }
      SAMPLE=$2
      shift 2
      ;;
    -n|--max-events)
      (($# >= 2)) || { echo "error: $1 requires a value" >&2; exit 2; }
      MAX_EVENTS=$2
      shift 2
      ;;
    --no-check)
      RUN_CHECK=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n $INPUT_MODE ]] || { echo "error: an input is required" >&2; exit 2; }
[[ -n $OUTPUT ]] || { echo "error: --output is required" >&2; exit 2; }
[[ $SAMPLE == data || $SAMPLE == mc ]] || {
  echo "error: --sample must be data or mc" >&2
  exit 2
}
[[ -z $MAX_EVENTS || $MAX_EVENTS =~ ^[1-9][0-9]*$ ]] || {
  echo "error: --max-events must be a positive integer" >&2
  exit 2
}

CONVERTER="$EDMBIN/delphi_sdst_pass"
CHECKER="$EDMBIN/delphi_btag_check"
[[ -x $CONVERTER ]] || { echo "error: converter is not executable: $CONVERTER" >&2; exit 1; }
if ((RUN_CHECK)); then
  [[ -x $CHECKER ]] || { echo "error: checker is not executable: $CHECKER" >&2; exit 1; }
fi

case $INPUT_MODE in
  input)
    [[ -s $INPUT_VALUE && -f $INPUT_VALUE ]] || {
      echo "error: local input is not a nonempty regular file: $INPUT_VALUE" >&2
      exit 1
    }
    INPUT_ARGS=("$INPUT_VALUE")
    ;;
  nickname)
    [[ -n $INPUT_VALUE ]] || { echo "error: nickname is empty" >&2; exit 2; }
    INPUT_ARGS=(--nickname "$INPUT_VALUE")
    ;;
  pdl)
    [[ -s $INPUT_VALUE && -f $INPUT_VALUE ]] || {
      echo "error: PDL input is not a nonempty regular file: $INPUT_VALUE" >&2
      exit 1
    }
    INPUT_ARGS=(--pdl "$INPUT_VALUE")
    ;;
esac

mkdir -p "$(dirname "$OUTPUT")"
COMMAND=("$CONVERTER" "${INPUT_ARGS[@]}" "$OUTPUT")
[[ -z $MAX_EVENTS ]] || COMMAND+=(-n "$MAX_EVENTS")

printf 'Running:'
printf ' %q' "${COMMAND[@]}"
printf '\n'
"${COMMAND[@]}"

[[ -s $OUTPUT && -f $OUTPUT ]] || {
  echo "error: converter did not produce a nonempty regular file: $OUTPUT" >&2
  exit 1
}

if ((RUN_CHECK)); then
  "$CHECKER" --source sDST "$OUTPUT" "$SAMPLE"
fi

echo "EDM4hep output: $OUTPUT"
