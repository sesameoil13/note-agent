part of 'connection.dart';

/// To-do lifecycle coordination over the paired device identity. Only action
/// identities and lifecycle operations are sent; never note text (ADR 0001).
extension WorkspaceTodoConnection on WorkspaceConnection {
  /// Whether this device holds a paired identity. No network request.
  Future<bool> todoSyncAvailable() async {
    await _ensureLoaded();
    return _device != null;
  }

  Future<Map<String, dynamic>> requestTodoSync(
    Map<String, dynamic> body,
  ) async {
    await _ensureLoaded();
    final device = _device;
    if (device == null) {
      throw const ConnectionFailure('尚未配对；待办操作保留在本机。', code: 'not_paired');
    }
    return _request(
      _endpoint(device['endpoint'] as String),
      '/v1/todos/sync',
      body: body,
      bearer: device['token'] as String,
    );
  }
}
