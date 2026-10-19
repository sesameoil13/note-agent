part of 'connection.dart';

extension WorkspaceBudgetConnection on WorkspaceConnection {
  Future<Map<String, dynamic>> requestSharedBudget(
    String path, {
    Map<String, dynamic>? body,
  }) async {
    if (path != '/v1/budget' && !path.startsWith('/v1/budget/')) {
      throw ArgumentError('Invalid budget operation');
    }
    await _ensureLoaded();
    final device = _device;
    if (device == null) {
      throw const ConnectionFailure(
        '请先通过原设备完成配对；本机保存仍可使用。',
        code: 'not_paired',
      );
    }
    return _request(
      _endpoint(device['endpoint'] as String),
      path,
      body: body,
      bearer: device['token'] as String,
    );
  }
}
