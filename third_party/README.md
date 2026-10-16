# PDFium notices

The app pins `pdfium_flutter` and `pdfium_dart` 0.3.1. Their native deployment
pins PDFium `chromium/7811`; Darwin's XCFramework reference is
`v144.0.7811.0-20260502-190206`, with archive checksum
`948d9257f53f01cbed74b81bb8adc8758e52ac9390751772de7889026d32d5a1`.

The retained component notices are under `pdfium/`. `NOTICES` combines them
with component headings and Flutter's 80-hyphen separator; the original
FreeType ISO-8859-1 notice is converted losslessly to UTF-8 in that combined
file. `pubspec.yaml` includes it via `flutter.licenses`, so Flutter packages it
in the app's standard `NOTICES.Z` along with dependency notices.

Pinned native distribution references:

- [PDFium binaries 7811](https://github.com/bblanchon/pdfium-binaries/releases/tag/chromium/7811)
- [Darwin XCFramework](https://github.com/espresso3389/pdfium-xcframework/releases/tag/v144.0.7811.0-20260502-190206)

Native asset build hooks may download binaries. The pinned Dart package's
non-Darwin archive hook does not verify an archive digest; record/verify release
assets for each target as part of release packaging. Local artifact hashes are
validation provenance, not a substitute for verifying upstream archives.
