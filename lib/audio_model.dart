part of 'connection.dart';

const transcriptionModelId = 'openai/whisper-large-v3-turbo';

class AudioModelReply {
  const AudioModelReply(this.text, this.generationId, this.usdNanos);
  final String text;
  final String? generationId;
  final int? usdNanos;
}

extension WorkspaceAudioNetwork on WorkspaceConnection {
  /// A single admitted upload. No retries or remote file hosting are implicit.
  Future<AudioModelReply> sendReservedAudio(
    String attemptId, {
    required List<int> bytes,
    required String format,
  }) async {
    await _ensureLoaded();
    final key = _aiKey;
    if (key == null) throw const ConnectionFailure('请先在 App 连接 OpenRouter。');
    await requestSharedBudget('/v1/budget/attempt/$attemptId/send', body: {});
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    String? generationId;
    try {
      final request = await client
          .postUrl(_textApiBase.resolve('audio/transcriptions'))
          .timeout(const Duration(seconds: 15));
      request.followRedirects = false;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $key');
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'model': transcriptionModelId,
          'input_audio': {'data': base64Encode(bytes), 'format': format},
          'language': 'zh',
          'response_format': 'json',
        }),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 75),
      );
      final header = response.headers.value('X-Generation-Id');
      if (header != null && RegExp(r'^[a-zA-Z0-9_-]{8,80}$').hasMatch(header)) {
        generationId = header;
      }
      final body = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 75))) {
        body.addAll(chunk);
        if (body.length > 1048576) {
          throw const ConnectionFailure('转写响应过大，原音与费用预留保留。');
        }
      }
      if (response.statusCode != 200) {
        throw TextNetworkFailure(
          switch (response.statusCode) {
            401 || 403 => 'Key 无效或无转写权限，请在 App 重新连接。',
            402 => 'OpenRouter 余额不足，请在官网核对。',
            413 => '转写服务拒绝此文件大小，原音保留。',
            _ => '转写服务未返回完整结果，可能已计费；请核对费用。',
          },
          generationId: generationId,
          code: switch (response.statusCode) {
            401 || 403 => 'credentials',
            402 => 'balance',
            _ => null,
          },
        );
      }
      final decoded = jsonDecode(utf8.decode(body));
      final text = decoded is Map ? decoded['text'] : null;
      if (text is! String || text.trim().isEmpty || text.contains('\u0000')) {
        throw const ConnectionFailure('转写为空或格式异常，原音保留，费用待核对。');
      }
      final usage = decoded['usage'];
      final cost = usage is Map ? usage['cost'] : null;
      final generation = response.headers.value('X-Generation-Id');
      return AudioModelReply(
        text,
        generation != null &&
                RegExp(r'^[a-zA-Z0-9_-]{8,80}$').hasMatch(generation)
            ? generation
            : null,
        cost is num && cost.isFinite && cost >= 0 && cost <= 1000
            ? _usdNanos(cost)
            : null,
      );
    } on TextNetworkFailure {
      rethrow;
    } on ConnectionFailure catch (e) {
      throw TextNetworkFailure(e.message, generationId: generationId);
    } catch (_) {
      throw TextNetworkFailure(
        '转写请求中断，可能已计费；原音与预留保留，不自动重传。',
        generationId: generationId,
      );
    } finally {
      client.close(force: true);
    }
  }
}
