/// Names the exact build in the setup guide so bug reports can cite it.
///
/// [appVersion] mirrors `version:` in pubspec.yaml (a test keeps them equal).
/// Release builds pass `--dart-define=BUILD_REVISION=<git sha>`.
const appVersion = '0.1.0+1';
const buildRevision = String.fromEnvironment(
  'BUILD_REVISION',
  defaultValue: 'dev',
);
const buildLabel = '版本 $appVersion · 构建 $buildRevision';
