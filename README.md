# Note Agent

A local-first personal note workspace for Obsidian. This repository currently implements the T01 text collection slice from [specification #1](https://github.com/sesameoil13/note-agent/issues/1). The full product specification is still in progress.

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

See [T01 validation](docs/development/t01-validation.md) for the completed T01 basic acceptance evidence and the broader setup/platform checks that remain unverified. Android SAF source and host-side coverage are also prepared; see [T02 validation](docs/development/t02-validation.md) for the pending SDK setup, APK build, and actual Xiaomi acceptance. Android uses persisted tree grants and provider URIs, not filesystem paths or broad storage access. Later tickets add AI, other capture formats, title disambiguation/editing, further platform delivery, reminders, and sync. The current local save status makes no synchronization claim.
