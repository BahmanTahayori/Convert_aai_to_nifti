#!/bin/bash
#SBATCH --partition=sapphire
#SBATCH --job-name=aar_to_nifti
#SBATCH --account="punim2712"
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=16G
#SBATCH --time=0-01:50:00
#SBATCH --output=logsn03/bslurm-%A.out
#SBATCH --error=logsn03/bslurm-%A.err
#SBATCH --mail-user=bahmant@unimelb.edu.au
##SBATCH --mail-type=BEGIN
##SBATCH --mail-type=END
#SBATCH --mail-type=FAIL

start=$SECONDS
#############################################################################
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
MAIN_LOG="${LOG_DIR}/batch_conversion_resume.log"
MAPPING_FILE="${OUT_ROOT}/subject_mapping.tsv"

JAVA_MEM="8g"

# Set to 1 only if you want to reconvert everything
FORCE_RECONVERT=0

# ============================================================
# Setup and checks
# ============================================================

mkdir -p "$OUT_ROOT" "$TMP_ROOT" "$LOG_DIR"

if ! command -v dcm2niix >/dev/null 2>&1; then
    echo "ERROR: dcm2niix not found."
    exit 1
fi

if ! command -v java >/dev/null 2>&1; then
    echo "ERROR: java not found. Try loading Java module first."
    exit 1
fi

if [ ! -f "$AAR_JAR" ]; then
    echo "ERROR: aar.jar not found at:"
    echo "$AAR_JAR"
    exit 1
fi

echo -e "subject_uid\tsubject_id" > "$MAPPING_FILE"
echo "Batch conversion started: $(date)" > "$MAIN_LOG"
echo "Source: $SRC_ROOT" >> "$MAIN_LOG"
echo "Output: $OUT_ROOT" >> "$MAIN_LOG"
echo "" >> "$MAIN_LOG"

# ============================================================
# Functions
# ============================================================

make_subject_id() {
    local uid="$1"
    local num

    # Accepts:
    # 1.7.121.3.1.1
    # 1.7.121.13.1.3
    # etc.
    num=$(echo "$uid" | sed -E 's/^1\.7\.121\.([0-9]+)\.1\.[0-9]+$/\1/')

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

already_converted() {
    local out_dir="$1"
    local prefix="$2"

    find "$out_dir" -maxdepth 1 -type f \
        \( -name "${prefix}*.nii" -o -name "${prefix}*.nii.gz" \) \
        | grep -q .
}

# ============================================================
# Main loop
# ============================================================

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

    echo "" >> "$MAIN_LOG"
    echo "Processing: $AAR_FILE" >> "$MAIN_LOG"

    REL_PATH=$(realpath --relative-to="$SRC_ROOT" "$AAR_FILE")

    if [[ "$REL_PATH" = /* ]]; then
        echo "ERROR: Could not calculate relative path. Skipping."
        echo "ERROR: Relative path failed: $AAR_FILE" >> "$MAIN_LOG"
        continue
    fi

    REL_DIR=$(dirname "$REL_PATH")
    SERIES_NAME=$(basename "$AAR_FILE" .aar)

    # Accept subject folders:
    # 1.7.121.X.1.Y
    SUBJECT_UID=$(echo "$REL_PATH" | grep -oE '1\.7\.121\.[0-9]+\.1\.[0-9]+' | head -n 1)

    if [ -z "$SUBJECT_UID" ]; then
        echo "WARNING: Could not identify subject UID. Skipping."
        echo "WARNING: Could not identify subject UID: $AAR_FILE" >> "$MAIN_LOG"
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

    echo -e "${SUBJECT_UID}\t${SUBJECT_ID}" >> "$MAPPING_FILE"

    echo "Relative path: $REL_PATH"
    echo "Subject UID  : $SUBJECT_UID"
    echo "Subject ID   : $SUBJECT_ID"
    echo "Timepoint    : $TP"
    echo "Series       : $SERIES_NAME"
    echo "Output dir   : $OUT_DIR"
    echo "File prefix  : $FILE_PREFIX"

    # --------------------------------------------------------
    # Skip if already converted
    # --------------------------------------------------------

    if [ "$FORCE_RECONVERT" -eq 0 ] && already_converted "$OUT_DIR" "$FILE_PREFIX"; then
        echo "SKIP: NIfTI already exists for this series."
        echo "SKIP: Already converted: $OUT_DIR/${FILE_PREFIX}*.nii*" >> "$MAIN_LOG"

        # Remove stale temporary extraction folder, if present
        rm -rf "$TMP_DIR"
        continue
    fi

    # --------------------------------------------------------
    # Prepare temporary folder
    # --------------------------------------------------------

    rm -rf "$TMP_DIR"
    mkdir -p "$TMP_DIR"

    # --------------------------------------------------------
    # Extract AAR
    # --------------------------------------------------------

    echo "Extracting AAR..."

    (
        cd "$TMP_DIR" || exit 1
        java -Xmx"$JAVA_MEM" -jar "$AAR_JAR" -extract "$AAR_FILE"
    ) >> "$MAIN_LOG" 2>&1

    if [ $? -ne 0 ]; then
        echo "ERROR: AAR extraction failed. Temporary files kept at:"
        echo "$TMP_DIR"
        echo "ERROR: AAR extraction failed: $AAR_FILE" >> "$MAIN_LOG"
        continue
    fi

    N_EXTRACTED=$(find "$TMP_DIR" -type f | wc -l)
    echo "Extracted files: $N_EXTRACTED"

    if [ "$N_EXTRACTED" -eq 0 ]; then
        echo "ERROR: No files extracted. Skipping."
        echo "ERROR: No files extracted: $AAR_FILE" >> "$MAIN_LOG"
        rm -rf "$TMP_DIR"
        continue
    fi

    # --------------------------------------------------------
    # Convert DICOM to NIfTI
    # --------------------------------------------------------

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
        echo "ERROR: dcm2niix failed: $AAR_FILE" >> "$MAIN_LOG"
        continue
    fi

    # --------------------------------------------------------
    # Verify output and delete temporary DICOMs
    # --------------------------------------------------------

    if already_converted "$OUT_DIR" "$FILE_PREFIX"; then
        echo "SUCCESS: NIfTI created."
        echo "Deleting temporary extracted DICOMs..."
        rm -rf "$TMP_DIR"
        echo "SUCCESS: $AAR_FILE -> $OUT_DIR" >> "$MAIN_LOG"
    else
        echo "WARNING: dcm2niix finished but no NIfTI was found."
        echo "Temporary DICOMs kept at:"
        echo "$TMP_DIR"
        echo "WARNING: No NIfTI found after conversion: $AAR_FILE" >> "$MAIN_LOG"
    fi

done

# De-duplicate subject mapping while keeping header
awk 'NR==1 || !seen[$0]++' "$MAPPING_FILE" > "${MAPPING_FILE}.tmp"
mv "${MAPPING_FILE}.tmp" "$MAPPING_FILE"

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

#############################################################################
end=$SECONDS
duration=$(( end-start ))

my-job-stats -a -n -s

printf '************************\n'

hrs=$(( duration/3600 ))
mins=$(( (duration-hrs*3600)/60 ))
secs=$(( duration-hrs*3600-mins*60 ))

printf 'The script took approximately %02d:%02d:%02d (hh:mm:ss).\n' $hrs $mins $secs
