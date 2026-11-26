#!/usr/bin/env bash
# Build and run the offscreen glass proof on this Mac, and leave PNGs behind.
#
#   Tools/glass-proof/render.sh [output directory]
#
# The app's glass is a Metal fragment pass, so it cannot be checked from the Python suite and cannot
# be eyeballed on a device from a bot's shell. This compiles the avatar sources the pass needs —
# together with `main.swift`, in one module, so the preview goes through the same internal types the
# app does — runs it, and writes one PNG per size and state, composited over the theme's dark canvas
# and over its raised surface (the pair is the translucency proof: a translucent body changes with
# what is behind it).
#
# Requires: Xcode's command line tools (swiftc) on a Mac. Nothing here is part of the app's build —
# no target in `project.yml` compiles this folder.
set -euo pipefail
cd "$(dirname "$0")/../.."

OUT="${1:-/tmp/hermey-glass-proof}"
mkdir -p "$OUT"

AVATAR="Sources/HermeyUI/OpenBotAvatar"
SOURCES=(
  Sources/HermesKit/BotAvatarActivity.swift
  Sources/HermeyUI/BotAvatarIdentity.swift
  "$AVATAR/BotAvatarDefinition.swift"
  "$AVATAR/OpenBotAvatarGeometry.swift"
  Sources/HermeyUI/BotAvatarGeometry.swift
  Sources/HermeyUI/BotAvatarPalette.swift
  Sources/HermeyUI/BotAvatarShape.swift
  Sources/HermeyUI/BotAvatarMotion.swift
  Sources/HermeyUI/BotAvatarPathParser.swift
  "$AVATAR/BotAvatarMaterial.swift"
  "$AVATAR/OpenBotAvatarMaterialPaint.swift"
  "$AVATAR/OpenBotAvatarEyes.swift"
  "$AVATAR/OpenBotAvatarEyeOverride.swift"
  "$AVATAR/OpenBotAvatarMarks.swift"
  "$AVATAR/OpenBotAvatarRibbons.swift"
  "$AVATAR/OpenBotAvatarSoften.swift"
  "$AVATAR/OpenBotAvatarState.swift"
  "$AVATAR/OpenBotAvatarStateDefinition.swift"
  "$AVATAR/OpenBotAvatarVolume.swift"
  "$AVATAR/OpenBotAvatarRenderer.swift"
  "$AVATAR/OpenBotAvatarPresets.swift"
  "$AVATAR/OpenBotAvatarRandom.swift"
  "$AVATAR/OpenBotAvatarGlassRoute.swift"
  "$AVATAR/Glass/HermeyGlassSource.swift"
  "$AVATAR/Glass/BotAvatarGlassLayer.swift"
  Tools/glass-proof/main.swift
)

SDK="$(xcrun --show-sdk-path --sdk macosx)"
swiftc -Onone -sdk "$SDK" -target "$(uname -m)-apple-macos14.0" \
  -o "$OUT/glass-proof" "${SOURCES[@]}"

"$OUT/glass-proof" "$OUT"
