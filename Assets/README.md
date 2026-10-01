# App icon

Original vector design drawn locally with AppKit: a green trackpad center surrounded by protected margins, a raised palm, and a shield. No image-generation API was used.

- AppIcon.png: 1024-pixel source preview with transparent corners.
- AppIcon.icns: packaged macOS icon with all standard sizes.
- AppIcon.iconset: size-specific PNGs.
- Regenerate from the project root with: swift scripts/generate-app-icon.swift Assets

The app bundle uses AppIcon.icns through CFBundleIconFile. The build script copies it into Contents/Resources.
