#!/bin/zsh
# Downloads Meta's EdgeTAM video tracker as Core ML packages (jutsuhq/edgetam-coreml v1.2,
# Apache-2.0, built from facebookresearch/EdgeTAM) into ios/Models/EdgeTAM (gitignored), with the
# propagator that masks the memory bank's empty slots. Checks the release's SHA-256 sums.
# Usage: ios/scripts/fetch-edgetam.sh
set -euo pipefail
ROOT=${0:A:h:h:h}
DEST="$ROOT/ios/Models/EdgeTAM"
BASE=https://github.com/jutsuhq/edgetam-coreml/releases/download/v1.2
MAIN=edgetam-coreml-v1.2.zip
MASKED=edgetam-coreml-v1.2-masked-propagator.zip
typeset -A SUMS
SUMS[$MAIN]=9c35c1b6667a0dd80b093bbc20747628f304133ad2a531de049307beb3ae1401
SUMS[$MASKED]=505766a4002098f52c0d7b16bcb1ebf099d71f2d26cce24df7655d9c5bf879f7

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
for f in $MAIN $MASKED; do
  curl -fsSL -o "$WORK/$f" "$BASE/$f"
  sum=$(shasum -a 256 "$WORK/$f" | cut -d' ' -f1)
  [[ "$sum" == "${SUMS[$f]}" ]] || { echo "SHA-256 mismatch for $f" >&2; exit 1; }
done
# Nothing in the archives may land outside the folder.
if unzip -Z1 "$WORK/$MAIN" "$WORK/$MASKED" 2>/dev/null | grep -qE '(^/|(^|/)\.\./)'; then
  echo "unsafe path in an archive" >&2; exit 1
fi
mkdir -p "$WORK/main" "$WORK/masked"
unzip -q "$WORK/$MAIN" -d "$WORK/main"
unzip -q "$WORK/$MASKED" -d "$WORK/masked"
rm -rf "$DEST"
mkdir -p "$DEST"
for name in EdgeTAMVideoImageEncoder EdgeTAMVideoInitializer EdgeTAMVideoMemoryEncoder; do
  mv "$WORK/main/$name.mlpackage" "$DEST/"
done
mv "$WORK/masked/EdgeTAMVideoPropagator.mlpackage" "$DEST/"
# The licence and notice travel with the models (Apache-2.0).
cp "$WORK/main/LICENSE" "$DEST/EdgeTAM-LICENSE.txt"
cp "$WORK/main/NOTICE" "$DEST/EdgeTAM-NOTICE.txt"
du -sh "$DEST"/*.mlpackage
echo "EdgeTAM models in $DEST. Run xcodegen generate in ios/ to add them to the app."
