#!/bin/sh
# Invoked by the Runner build phase; never modifies repository source files.
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
revision=$(/usr/bin/git -C "$repo" rev-parse --short=12 HEAD 2>/dev/null || printf unknown)
if ! /usr/bin/git -C "$repo" diff --quiet HEAD -- NativeAudio lib/audio.dart ios/Runner/Audio macos/Runner/Audio; then
  revision="${revision}-dirty"
fi
fingerprint=$(/usr/bin/find "$repo/NativeAudio/Sources/AudioCore" -name '*.swift' -type f -print |
  LC_ALL=C /usr/bin/sort | while IFS= read -r source_file; do /bin/cat "$source_file"; done |
  /usr/bin/shasum -a 256 | /usr/bin/cut -d ' ' -f 1)
output_dir="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"
/bin/mkdir -p "$output_dir"
/usr/bin/printf '{"revision":"%s","sourceFingerprint":"%s"}\n' "$revision" "$fingerprint" > "$output_dir/SilentDiscoAudioBuild.json"
