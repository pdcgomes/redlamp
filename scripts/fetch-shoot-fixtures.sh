#!/bin/zsh
# Downloads CC0 raws from raw.pixls.us for the dust evaluation (DustEvaluationTests) into
# tests/fixtures/shoots: a shoot (eight Nikon Z 6 frames taken within 11 minutes, on a tripod) and
# one frame each from seven more cameras, beside the samples in tests/fixtures/raw.
set -euo pipefail
cd "$(dirname "$0")/.."

fetch() { # <folder> <file name> <path under raw.pixls.us/data>
  local file="$1/$2"
  mkdir -p "$1"
  [[ -s "$file" ]] && return
  curl --fail --silent --show-error --location -o "$file.part" "https://raw.pixls.us/data/$3"
  mv "$file.part" "$file"
}

for frame in 0750 0751 0752 0753 0754 0755 0756 0757; do
  fetch tests/fixtures/shoots/nikon-z6 "DSC_$frame.NEF" "Nikon/Z%206/DSC_$frame.NEF"
done

scenes=(
  "Canon_EOS-5D-Mark-IV_B13A0729.CR2" "Canon/EOS%205D%20Mark%20IV/B13A0729.CR2"
  "Canon_EOS-6D_EOS_6D_RAW.CR2" "Canon/EOS%206D/EOS_6D_RAW.CR2"
  "Canon_EOS-80D_IMG_0096.CR2" "Canon/EOS%2080D/IMG_0096.CR2"
  "Nikon_D7500_RAW_NIKON_D7500_12BIT_COMPRESSED.NEF" "Nikon/D7500/RAW_NIKON_D7500_12BIT_COMPRESSED.NEF"
  "Olympus_E-M1MarkII_Olympus_EM1mk2_Standard_20MP.ORF" "Olympus/E-M1MarkII/Olympus_EM1mk2_Standard_20MP.ORF"
  "Panasonic_DC-G9_P1000475.RW2" "Panasonic/DC-G9/P1000475.RW2"
  "Sony_ILCE-7RM3_DSC03791.ARW" "Sony/ILCE-7RM3/DSC03791.ARW"
)
for name source in "${scenes[@]}"; do
  fetch tests/fixtures/shoots/scenes "$name" "$source"
done
ls -l tests/fixtures/shoots/*
