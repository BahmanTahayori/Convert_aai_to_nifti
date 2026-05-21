#!/bin/bash
#SBATCH --partition=sapphire
#SBATCH --job-name=aar_to_nifti
#SBATCH --account="punim2712"
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=32G
#SBATCH --time=0-01:50:00
#SBATCH --output=logsn03/bslurm-%A.out
#SBATCH --error=logsn03/bslurm-%A.err
#SBATCH --mail-user=bahmant@unimelb.edu.au
##SBATCH --mail-type=BEGIN
##SBATCH --mail-type=END
#SBATCH --mail-type=FAIL

start=$SECONDS

#######module load Java and module load dcm2niix are required

set -u
set -o pipefail

# ============================================================
# User settings
# ============================================================

SRC_ROOT="/home/tahayori/Desktop/punim2955/Data/TrainSmart/Diffusion_Data"
OUT_ROOT="/home/tahayori/Desktop/punim2955/Data/TrainSmart/Diffusion_Data/Nifti"

AAR_JAR="/home/tahayori/Desktop/punim2955/Data/TrainSmart/Diffusion_Data/aar.jar"

TMP_ROOT="${OUT_ROOT}/_tmp_extracted_dicoms"
LOG_DIR="${OUT_ROOT}/logs"
MAIN_LOG="${LOG_DIR}/batch_conversion.log"
MAPPING_FILE="${OUT_ROOT}/subject_mapping.tsv"

JAVA_MEM="8g"

mkdir -p "$OUT_ROOT" "$TMP_ROOT" "$LOG_DIR"

if ! command -v dcm2niix >/dev/null 2>&1; then
    echo "ERROR: dcm2niix not found."
    exit 1
fi

if ! command -v java >/dev/null 2>&1; then
    echo "ERROR: java not found. Try loading Java module."
    exit 1
fi

if [ ! -f "$AAR_JAR" ]; then
    echo "ERROR: aar.jar not found at:"
    echo "$AAR_JAR"
    exit 1
fi

echo -e "subject_uid\tsubject_id" > "$MAPPING_FILE"
echo "Batch conversion started: $(date)" > "$MAIN_LOG"

make_subject_id() {
    local uid="$1"
    local num

    num=$(echo "$uid" | sed -E 's/^1\.7\.121\.([0-9]+)\.1\.1$/\1/')

    if [[ "$num" =~ ^[0-9]+$ ]]; then
        printf "Sub-%03d" "$num"
    else
        echo "Sub-UNKNOWN"
    fi
}

replace_subject_folder_only() {
    local rel_dir="$1"
    local subject_uid="$2"
    local subject_id="$3"

    local output=""
    IFS='/' read -ra parts <<< "$rel_dir"

    for part in "${parts[@]}"; do
        if [ "$part" = "$subject_uid" ]; then
            part="$subject_id"
        fi

        if [ -z "$output" ]; then
            output="$part"
        else
            output="$output/$part"
        fi
    done

    echo "$output"
}

find "$SRC_ROOT" \
    -type f \
    -name "*.aar" \
    ! -path "${OUT_ROOT}/*" \
    ! -path "${TMP_ROOT}/*" \
    | sort \
    | while read -r AAR_FILE; do

    echo ""
    echo "============================================================"
    echo "Processing:"
    echo "$AAR_FILE"
    echo "============================================================"

    # Robust relative path calculation
    REL_PATH=$(realpath --relative-to="$SRC_ROOT" "$AAR_FILE")

    # Safety check: skip if realpath failed strangely
    if [[ "$REL_PATH" = /* ]]; then
        echo "ERROR: Relative path failed. Skipping:"
        echo "$AAR_FILE"
        continue
    fi

    REL_DIR=$(dirname "$REL_PATH")
    SERIES_NAME=$(basename "$AAR_FILE" .aar)

    SUBJECT_UID=$(echo "$REL_PATH" | grep -oE '1\.7\.121\.[0-9]+\.1\.1' | head -n 1)

    if [ -z "$SUBJECT_UID" ]; then
        echo "WARNING: Could not identify subject UID. Skipping."
        continue
    fi

    SUBJECT_ID=$(make_subject_id "$SUBJECT_UID")

    TP=$(echo "$REL_PATH" | grep -oE 'TP[0-9]+' | head -n 1)
    if [ -z "$TP" ]; then
        TP="TPunknown"
    fi

    OUT_REL_DIR=$(replace_subject_folder_only "$REL_DIR" "$SUBJECT_UID" "$SUBJECT_ID")
    OUT_DIR="${OUT_ROOT}/${OUT_REL_DIR}"

    mkdir -p "$OUT_DIR"

    SAFE_SERIES=$(echo "$SERIES_NAME" | sed -E 's/[^A-Za-z0-9_+-]+/_/g')
    FILE_PREFIX="${SUBJECT_ID}_${TP}_${SAFE_SERIES}"

    TMP_DIR="${TMP_ROOT}/${SUBJECT_ID}_${TP}_${SAFE_SERIES}"
    rm -rf "$TMP_DIR"
    mkdir -p "$TMP_DIR"

    echo -e "${SUBJECT_UID}\t${SUBJECT_ID}" >> "$MAPPING_FILE"

    echo "Relative path: $REL_PATH"
    echo "Subject UID  : $SUBJECT_UID"
    echo "Subject ID   : $SUBJECT_ID"
    echo "Timepoint    : $TP"
    echo "Series       : $SERIES_NAME"
    echo "Output dir   : $OUT_DIR"
    echo "File prefix  : $FILE_PREFIX"

    echo "Extracting AAR..."

    (
        cd "$TMP_DIR" || exit 1
        java -Xmx"$JAVA_MEM" -jar "$AAR_JAR" -extract "$AAR_FILE"
    ) >> "$MAIN_LOG" 2>&1

    if [ $? -ne 0 ]; then
        echo "ERROR: AAR extraction failed. Temporary files kept at:"
        echo "$TMP_DIR"
        continue
    fi

    N_EXTRACTED=$(find "$TMP_DIR" -type f | wc -l)
    echo "Extracted files: $N_EXTRACTED"

    if [ "$N_EXTRACTED" -eq 0 ]; then
        echo "ERROR: No files extracted. Skipping."
        rm -rf "$TMP_DIR"
        continue
    fi

    echo "Converting to NIfTI..."

    dcm2niix \
        -z y \
        -b y \
        -d 9 \
        -f "$FILE_PREFIX" \
        -o "$OUT_DIR" \
        "$TMP_DIR" >> "$MAIN_LOG" 2>&1

    if [ $? -ne 0 ]; then
        echo "ERROR: dcm2niix failed. Temporary DICOMs kept at:"
        echo "$TMP_DIR"
        continue
    fi

    if ls "$OUT_DIR/${FILE_PREFIX}"*.nii* >/dev/null 2>&1; then
        echo "SUCCESS: NIfTI created."
        rm -rf "$TMP_DIR"
        echo "Temporary extracted DICOMs deleted."
    else
        echo "WARNING: dcm2niix finished but no NIfTI found. Temporary files kept:"
        echo "$TMP_DIR"
    fi

done

sort -u "$MAPPING_FILE" -o "$MAPPING_FILE"

echo ""
echo "Batch conversion finished: $(date)"
echo "Output folder:"
echo "$OUT_ROOT"
echo ""
echo "Subject mapping:"
echo "$MAPPING_FILE"
echo ""
echo "Log file:"
echo "$MAIN_LOG"


end=$SECONDS
duration=$(( end-start ))

my-job-stats -a -n -s

printf '************************\n'

hrs=$(( duration/3600 ))
mins=$(( (duration-hrs*3600)/60 ))
secs=$(( duration-hrs*3600-mins*60 ))

printf 'The script took approximately %02d:%02d:%02d (hh:mm:ss).\n' $hrs $mins $secs
