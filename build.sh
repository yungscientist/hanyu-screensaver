#!/bin/zsh
# Сборка Hanyu HSK.saver. Использование:
#   ./build.sh            — собрать в build/
#   ./build.sh install    — собрать и установить в ~/Library/Screen Savers
#   ./build.sh words      — пересобрать Resources/words.json из data/raw (дамп БКРС + списки HSK)
set -euo pipefail
cd "${0:A:h}"

if [[ "${1:-}" == "words" ]]; then
  python3 -I tools/build_words.py data/raw/dabkrs.gz data/raw/hsk Resources/words.json
  shift
fi

SAVER="build/Hanyu HSK.saver"
rm -rf "$SAVER"
mkdir -p "$SAVER/Contents/MacOS" "$SAVER/Contents/Resources"

for arch in arm64 x86_64; do
  swiftc -O -module-name HanyuSaver -parse-as-library \
    -target "$arch-apple-macos13.0" \
    -emit-library -Xlinker -bundle \
    -framework ScreenSaver -framework AppKit \
    -o "build/HanyuSaver-$arch" Sources/*.swift
done
lipo -create build/HanyuSaver-arm64 build/HanyuSaver-x86_64 -output "$SAVER/Contents/MacOS/HanyuSaver"
rm build/HanyuSaver-arm64 build/HanyuSaver-x86_64

cp Resources/Info.plist "$SAVER/Contents/"
cp Resources/words.json "$SAVER/Contents/Resources/"
codesign --force --deep --sign - "$SAVER"
echo "Собрано: $SAVER"

if [[ "${1:-}" == "install" ]]; then
  DEST="$HOME/Library/Screen Savers"
  mkdir -p "$DEST"
  rm -rf "$DEST/Hanyu HSK.saver"
  cp -R "$SAVER" "$DEST/"
  # legacyScreenSaver держит старую версию в памяти — перезапускаем
  killall legacyScreenSaver 2>/dev/null || true
  echo "Установлено в $DEST. Выберите «Hanyu HSK» в Системных настройках → Заставка"
  echo "(если Настройки были открыты — перезапустите их, чтобы подхватить новую версию)."
fi
