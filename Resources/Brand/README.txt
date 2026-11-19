LocalVerbatim app icon — original geometric artwork

Copyright 2026 LocalVerbatim contributors
SPDX-License-Identifier: Apache-2.0
The original icon and drawing script use the project's Apache-2.0 license.

The icon combines custom rounded paths, an asymmetric five-bar waveform,
two transcript lines and two layered cards. It contains no downloaded art,
third-party logos, typeface outlines or SF Symbols. The original green
interface accent remains unchanged; these gradients belong to the icon.

AppIcon.svg is the editable vector reference. AppIcon.png is the 1024px
render, and AppIcon-preview.png is a compact preview. The source drawing
and all 16–1024px icon representations are produced by scripts/make_icon.swift.
The installed app uses scripts/AppIcon.icns. The recording badge is applied
separately at runtime according to the user's recording-indicator setting.

Rebuild on macOS from the project directory:
  swift scripts/make_icon.swift /absolute/output/brand
  iconutil -c icns /absolute/output/brand/AppIcon.iconset -o scripts/AppIcon.icns
