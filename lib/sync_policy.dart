/// Conservative decimal units: the official Standard documentation labels the
/// cap as 5 MB without specifying a binary boundary. No remote usage API is used.
abstract final class ObsidianSyncStandard {
  static const maximumFileBytes = 5000000;
  static const accountStorageBytes = 1000000000;
  static const plansUrl = 'https://obsidian.md/help/sync/plans';
}

class SyncStorageOverview {
  const SyncStorageOverview({required this.localVaultBytes});

  /// Local file bytes only. Remote version history and exclusions are unknown.
  final int? localVaultBytes;
  int? get remoteUsedBytes => null;
  int get maximumFileBytes => ObsidianSyncStandard.maximumFileBytes;
  int get accountStorageBytes => ObsidianSyncStandard.accountStorageBytes;
  bool get localVaultExceedsAccountLimit =>
      localVaultBytes != null && localVaultBytes! > accountStorageBytes;
}
