import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:note_agent/connection.dart';
import 'package:note_agent/note_workspace.dart';

class BudgetMemoryStore implements SecureCredentialStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String v) async {
    value = v;
  }

  @override
  Future<void> delete() async {
    value = null;
  }
}

class BudgetFixture {
  late Process worker;
  late Uri endpoint;
  late HttpServer router;
  bool omitCost = false, generationAvailable = false;
  int generationReads = 0;
  int audioRequests = 0;
  String transcript = '明天下午两点整理会议记录。';
  bool omitAudioCost = false, omitAudioId = false;
  int audioStatus = 200;

  /// Per-request statuses for transcription, used before [audioStatus].
  final audioStatuses = <int>[];

  /// Transcripts for successive parts; [transcript] when empty.
  List<String> partTranscripts = [];

  /// Seconds billed per transcription request, read from each WAV part.
  final audioSeconds = <int>[];

  /// Budget-service requests (paths under /v1/) to fail with a 503, as a
  /// network blip would; others pass through to the local Worker.
  bool Function(String path)? failBudgetRequest;

  /// Budget-service requests the Worker carries out whose reply is then
  /// lost (a 503 instead), as when the connection drops mid-response.
  bool Function(String path)? loseBudgetReply;
  // Widget tests mock every HttpClient made in their zone; the proxy to the
  // local Worker needs a real one.
  final _proxy = HttpOverrides.runWithHttpOverrides(
    HttpClient.new,
    _RealHttpOverrides(),
  );
  Map<String, dynamic>? lastAudioRequest;
  final modelStatuses = <int>[];
  bool malformedContent = false;
  bool reuseGenerationId = false;
  Map<String, dynamic>? modelResult;

  /// Results for particular notes (by sourceId), before [modelResult].
  final modelResults = <String, Map<String, dynamic>>{};

  /// Organizes [note] into itself: same kind of note, title and body.
  void keepAsIs(WorkspaceNote note) => modelResults[note.id] = {
    'manifestVersion': 3,
    'kind': 'ordinary',
    'title': note.title,
    'body': note.text,
    'actions': [],
    'associations': [],
    'newTopics': [],
  };

  /// qwen-plus requests for the note [noteId].
  List<Map<String, dynamic>> requestsFor(String noteId) => [
    for (final r in modelRequests)
      if ((jsonDecode((r['messages'] as List).last['content'] as String)
              as Map)['sourceId'] ==
          noteId)
        r,
  ];
  double generationCost = 0.00002;
  Future<void> Function()? beforeReply;
  final modelRequests = <Map<String, dynamic>>[];
  final workspaces = <NoteWorkspace>[];
  final stores = <BudgetMemoryStore>[];
  late Directory root;
  Future<void> start() async {
    root = await Directory.systemTemp.createTemp('budget-fixture-');
    worker = await Process.start(
      Platform.environment['NOTE_AGENT_NODE'] ?? 'node',
      ['tools/budget-harness.mjs'],
      workingDirectory: 'services/pairing',
    );
    worker.stderr.transform(utf8.decoder).listen((_) {});
    endpoint = Uri.parse(
      await worker.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          // Starting the local Worker runtime is slow on Windows CI.
          .timeout(const Duration(seconds: 60)),
    );
    router = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    router.listen((r) async {
      if (r.uri.path.startsWith('/v1/')) {
        await _forward(r);
        return;
      }
      if (r.uri.path == '/chat/completions') {
        final request = jsonDecode(
          await utf8.decoder.bind(r).join(),
        ) as Map<String, dynamic>;
        if (request['model'] == 'qwen3-asr-flash') {
          await _transcribe(r, request);
          return;
        }
        modelRequests.add(request);
        final status = modelStatuses.isEmpty ? 200 : modelStatuses.removeAt(0);
        if (status != 200) {
          r.response.statusCode = status;
          r.response.write('{}');
          await r.response.close();
          return;
        }
        final input = jsonDecode(
          (request['messages'] as List).last['content'] as String,
        ) as Map;
        await beforeReply?.call();
        r.response.write(
          jsonEncode({
            // Bailian's OpenAI-compatible reply: an id and token usage.
            'id': reuseGenerationId
                ? 'chatcmpl-reused-receipt'
                : 'chatcmpl-budget-fixture-${modelRequests.length}',
            'model': 'qwen-plus',
            if (!omitCost)
              'usage': {'prompt_tokens': 37, 'completion_tokens': 22},
            'choices': [
              {
                'finish_reason': 'stop',
                'message': {
                  'content': malformedContent
                      ? '{broken'
                      : jsonEncode(
                          modelResults[input['sourceId']] != null
                              ? {
                                  'sourceId': input['sourceId'],
                                  ...modelResults[input['sourceId']]!,
                                }
                              : modelResult == null
                              ? {
                                  'sourceId': input['sourceId'],
                                  'kind': 'ordinary',
                                  'title': '记录想法',
                                  'body': '整理后的普通想法。',
                                }
                              : {
                                  'sourceId': input['sourceId'],
                                  ...modelResult!,
                                },
                        ),
                },
              },
            ],
          }),
        );
      } else if (r.uri.path == '/generation') {
        generationReads++;
        if (generationAvailable) {
          r.response.write(
            jsonEncode({
              'data': {
                'id': r.uri.queryParameters['id'],
                'total_cost': generationCost,
              },
            }),
          );
        } else {
          r.response.statusCode = 404;
          r.response.write('{}');
        }
      } else {
        r.response.write('{"object":"list","data":[{"id":"qwen-plus"}]}');
      }
      await r.response.close();
    });
    for (var i = 0; i < 3; i++) {
      final store = BudgetMemoryStore();
      stores.add(store);
      final vault = await Directory('${root.path}/vault$i').create();
      workspaces.add(
        await NoteWorkspace.open(
          localDirectory: Directory('${root.path}/local$i'),
          vaultDirectory: vault,
          connection: WorkspaceConnection(
            secureStore: store,
            textApiBase: Uri.parse('http://127.0.0.1:${router.port}/'),
            keyCheck: AiKeyCheck(
              endpoint: Uri.parse('http://127.0.0.1:${router.port}/key'),
            ),
            pairingEndpoint: Uri.parse('http://127.0.0.1:${router.port}'),
            allowLocalPairingForTests: true,
          ),
        ),
      );
    }
    final owner = workspaces.first.connection;
    await owner.connectAi('sk-or-v1-budget-fixture-only-key');
    await owner.activatePairing(
      setupToken: 'local-test-setup-only',
      deviceName: 'owner',
    );
    for (final workspace in workspaces.skip(1)) {
      await owner.createPairing();
      await workspace.connection.joinPairing(
        owner.pairing.code!,
        deviceName: 'member',
      );
      await owner.refreshPairing();
      await owner.approvePairing(
        verificationCode: owner.pairing.verificationCode!,
      );
      await workspace.connection.refreshPairing();
      await owner.refreshPairing();
    }
  }

  Future<void> advanceTo(DateTime time) async {
    final client = HttpClient();
    final request = await client.postUrl(endpoint.resolve('/fixture-clock'));
    request.write(time.millisecondsSinceEpoch.toString());
    final response = await request.close();
    await response.drain<void>();
    client.close();
  }

  Future<void> _forward(HttpRequest r) async {
    if (failBudgetRequest?.call(r.uri.path) ?? false) {
      r.response.statusCode = 503;
      r.response.write('{"error":"service_unavailable"}');
      await r.response.close();
      return;
    }
    final upstream = await _proxy.openUrl(
      r.method,
      endpoint.resolve(r.uri.toString().substring(1)),
    );
    r.headers.forEach((name, values) {
      if (name == 'authorization' || name == 'content-type') {
        upstream.headers.set(name, values);
      }
    });
    await upstream.addStream(r);
    final result = await upstream.close();
    if (loseBudgetReply?.call(r.uri.path) ?? false) {
      await result.drain<void>();
      r.response.statusCode = 503;
      r.response.write('{"error":"service_unavailable"}');
      await r.response.close();
      return;
    }
    r.response.statusCode = result.statusCode;
    r.response.headers.contentType = result.headers.contentType;
    await r.response.addStream(result);
    await r.response.close();
  }

  /// Bailian's qwen3-asr-flash reply through chat/completions: the text as
  /// the message, an id, and the billed seconds (here from the WAV header).
  Future<void> _transcribe(HttpRequest r, Map<String, dynamic> request) async {
    audioRequests++;
    lastAudioRequest = request;
    final status = audioStatuses.isEmpty
        ? audioStatus
        : audioStatuses.removeAt(0);
    r.response.statusCode = status;
    if (status != 200) {
      r.response.write('{}');
      await r.response.close();
      return;
    }
    final content = ((request['messages'] as List).single as Map)['content'];
    final data =
        (((content as List).single as Map)['input_audio'] as Map)['data']
            as String;
    final audio = base64Decode(data.split(',').last);
    final header = ByteData.sublistView(Uint8List.fromList(audio));
    final seconds =
        (header.getUint32(40, Endian.little) /
                header.getUint32(28, Endian.little))
            .ceil();
    audioSeconds.add(seconds);
    final text = partTranscripts.isEmpty
        ? transcript
        : partTranscripts.removeAt(0);
    r.response.write(
      jsonEncode({
        if (!omitAudioId) 'id': 'chatcmpl-asr-fixture-$audioRequests',
        'model': 'qwen3-asr-flash',
        'choices': [
          {
            'finish_reason': 'stop',
            'message': {'role': 'assistant', 'content': text},
          },
        ],
        if (!omitAudioCost) 'usage': {'seconds': seconds},
      }),
    );
    await r.response.close();
  }

  /// [whileClosed] runs between closing and reopening, e.g. to stand in for
  /// data an older app version saved.
  Future<void> reopen(
    int i, {
    VaultStorage? vaultStorage,
    void Function(Directory local)? whileClosed,
  }) async {
    await workspaces[i].close();
    whileClosed?.call(Directory('${root.path}/local$i'));
    workspaces[i] = await NoteWorkspace.open(
      localDirectory: Directory('${root.path}/local$i'),
      vaultDirectory: vaultStorage == null
          ? Directory('${root.path}/vault$i')
          : null,
      vaultStorage: vaultStorage,
      connection: WorkspaceConnection(
        secureStore: stores[i],
        textApiBase: Uri.parse('http://127.0.0.1:${router.port}/'),
        keyCheck: AiKeyCheck(
          endpoint: Uri.parse('http://127.0.0.1:${router.port}/key'),
        ),
        pairingEndpoint: Uri.parse('http://127.0.0.1:${router.port}'),
        allowLocalPairingForTests: true,
      ),
    );
  }

  Future<void> close() async {
    for (final w in workspaces) {
      await w.close();
    }
    await router.close(force: true);
    _proxy.close(force: true);
    worker.kill(ProcessSignal.sigterm);
    await worker.exitCode;
    await root.delete(recursive: true);
  }
}

class _RealHttpOverrides extends HttpOverrides {}
