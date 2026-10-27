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
    try {
      return await _request(
        _endpoint(device['endpoint'] as String),
        path,
        body: body,
        bearer: device['token'] as String,
      );
    } on ConnectionFailure catch (e) {
      final message = switch (e.code) {
        'quote_unavailable' => '固定模型费率或汇率暂不可核对，已暂停收费任务；请稍后重试。',
        'budget_unavailable' => '共享账本暂时不可核对，费用预留保留，请稍后核对。',
        'quote_expired' => '报价已过期，请重新预估。',
        'owner_required' => '仅原设备可以修改共享月上限。',
        'invalid_budget' => '月上限须大于 0 且不超过 30 元，文字输入也可能超出单次上限。',
        'attempt_not_sendable' => '此尝试已发送或结束，不会重复发送。',
        'cost_conflict' ||
        'generation_conflict' => '费用回执不一致，已暂停新收费任务；保留原文与账本，请在阿里云百炼控制台核对账单。',
        _ => e.message,
      };
      throw ConnectionFailure(message, code: e.code);
    }
  }
}
