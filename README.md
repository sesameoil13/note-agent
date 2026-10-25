# Note Agent

A local-first personal note workspace for Obsidian. The T01 macOS text collection slice from [specification #1](https://github.com/sesameoil13/note-agent/issues/1) has passed basic native acceptance. Windows runner source is present; Windows build and Windows 11 runtime acceptance are pending. The full product specification is still in progress.

The Flutter interface collects text, lists recent records, and opens a detail view with 正文 → 关联 → 来源. It saves the original text and stable identity to a local SQLite database before publishing a Markdown note and an original `.txt` source into the selected test vault. Notes contain no YAML properties or generated summary. Collection and modification times appear immediately after the source link.

## Development

Use Flutter 3.47.7 (Dart 3.13.5) or a compatible newer stable SDK. A native macOS build also needs full Xcode configured according to [Flutter's macOS setup guide](https://docs.flutter.dev/platform-integration/macos/setup).

```sh
flutter pub get
flutter test
flutter analyze
flutter test integration_test/native_clipboard_test.dart -d macos
flutter run -d macos
```

Select a newly created **test vault** through the app's system directory picker. To use the Obsidian button, install Obsidian and first open that same test folder as an Obsidian vault. The app never discovers, imports, or switches an old vault automatically.

## Local files

- The app's Application Support directory contains `dev.noteagent/workspace/workspace.sqlite3`, including recoverable original text and export state.
- The chosen vault receives `<title>.md` and `attachments/note-agent/<stable-id>.txt`.
- `.note-agent-staging/` holds private transient publication files. Publication uses atomic, exclusive hard links on macOS; interrupted operations can recover without replacing an unrelated existing note.
- A write failure preserves the local original and exposes a retry action. An existing destination with different content remains untouched.

The SQLite index and credentials are not written into note properties. The app uses security-scoped bookmarks to restore the selected directory authorization on macOS.

On Windows, private state lives in `%LOCALAPPDATA%\dev.noteagent\workspace`, and only the selected folder path is remembered in `HKCU\Software\NoteAgent`. The Windows publisher uses a same-volume move without replacing an existing destination. See [T03 validation](docs/development/t03-validation.md) for the native acceptance gate and Windows commands. A manual Windows build workflow draft is retained locally outside the repository; registration and any cost-authorized dispatch remain pending.

See [T01 validation](docs/development/t01-validation.md) for the completed T01 basic acceptance evidence and the broader setup/platform checks that remain unverified. The Android ARM64 release APK now compiles and passes signature/alignment checks; see [T02 validation](docs/development/t02-validation.md) for build evidence and the pending actual Xiaomi installation/authorization acceptance. Android uses persisted tree grants and provider URIs, not filesystem paths or broad storage access.

See [T04 validation](docs/development/t04-validation.md) for keyword search, duplicate-safe editable titles, link-preserving rename and remaining native acceptance. The semantic-title contract accepts candidates from the future T13 service; no AI title generation or paid provider is included yet. Later tickets add AI, other capture formats, further platform delivery, reminders, and sync. The current local save status makes no synchronization claim.
