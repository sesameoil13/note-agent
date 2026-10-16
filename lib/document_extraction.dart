/// Engine-neutral document results. Future OCR/Word adapters use these same
/// values; no native PDF handles or layout engine types cross this boundary.
enum DocumentCompletion { complete, partial, noExtractableText, failed }

class DocumentLocation {
  const DocumentLocation({
    required this.sourceId,
    required this.page,
    this.bounds,
    this.rotation = 0,
  });
  final String sourceId;
  final int page;

  /// [left, bottom, right, top] in unrotated PDF points, origin bottom-left.
  final List<double>? bounds;
  final int rotation;
  Map<String, Object?> toJson() => {
    'sourceId': sourceId,
    'page': page,
    'bounds': bounds,
    'rotation': rotation,
    'coordinates': 'pdf-points-bottom-left',
  };
  factory DocumentLocation.fromJson(Map<String, dynamic> json) =>
      DocumentLocation(
        sourceId: json['sourceId'] as String,
        page: json['page'] as int,
        bounds: (json['bounds'] as List?)
            ?.map((n) => (n as num).toDouble())
            .toList(),
        rotation: json['rotation'] as int? ?? 0,
      );
}

class DocumentBody {
  const DocumentBody(this.text, this.location);
  final String text;
  final DocumentLocation location;
  Map<String, Object?> toJson() => {
    'text': text,
    'location': location.toJson(),
  };
  factory DocumentBody.fromJson(Map<String, dynamic> json) => DocumentBody(
    json['text'] as String,
    DocumentLocation.fromJson(json['location'] as Map<String, dynamic>),
  );
}

class DocumentCell {
  const DocumentCell(this.text, this.location);
  final String text;
  final DocumentLocation location;
  Map<String, Object?> toJson() => {
    'text': text,
    'location': location.toJson(),
  };
  factory DocumentCell.fromJson(Map<String, dynamic> json) => DocumentCell(
    json['text'] as String,
    DocumentLocation.fromJson(json['location'] as Map<String, dynamic>),
  );
}

class DocumentTable {
  const DocumentTable(this.rows, this.location);
  final List<List<DocumentCell>> rows;
  final DocumentLocation location;
  Map<String, Object?> toJson() => {
    'rows': rows.map((r) => r.map((c) => c.toJson()).toList()).toList(),
    'location': location.toJson(),
  };
  factory DocumentTable.fromJson(Map<String, dynamic> json) => DocumentTable(
    (json['rows'] as List)
        .map(
          (r) => (r as List)
              .map((c) => DocumentCell.fromJson(c as Map<String, dynamic>))
              .toList(),
        )
        .toList(),
    DocumentLocation.fromJson(json['location'] as Map<String, dynamic>),
  );
  String get markdown {
    String cell(DocumentCell c) => c.text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('\\', '&#92;')
        .replaceAll('|', '&#124;')
        .replaceAll('\n', '<br>');
    String row(List<DocumentCell> r) => '| ${r.map(cell).join(' | ')} |';
    return [
      row(rows.first),
      '| ${List.filled(rows.first.length, '---').join(' | ')} |',
      ...rows.skip(1).map(row),
    ].join('\n');
  }
}

class DocumentProblem {
  const DocumentProblem(this.code, this.message, {this.page, this.lastPage});
  final String code;
  final String message;
  final int? page;
  final int? lastPage;
  Map<String, Object?> toJson() => {
    'code': code,
    'message': message,
    'page': page,
    'lastPage': lastPage,
  };
  factory DocumentProblem.fromJson(Map<String, dynamic> json) =>
      DocumentProblem(
        json['code'] as String,
        json['message'] as String,
        page: json['page'] as int?,
        lastPage: json['lastPage'] as int?,
      );
}

class DocumentExtraction {
  const DocumentExtraction({
    required this.completion,
    this.body = const [],
    this.tables = const [],
    this.unprocessed = const [],
    this.problems = const [],
    this.totalPages = 0,
    this.processedPages = 0,
    this.engine = 'pdfium/7811 guarded-text-v1',
  });
  final DocumentCompletion completion;
  final List<DocumentBody> body;
  final List<DocumentTable> tables;
  final List<DocumentLocation> unprocessed;
  final List<DocumentProblem> problems;
  final int totalPages;
  final int processedPages;
  final String engine;

  /// Tables and prose stay in page order. The adapter supplies body fragments
  /// around a table, so table words are never repeated in the prose.
  String get markdown {
    final blocks =
        <({int page, double top, String text})>[
          for (final b in body)
            (
              page: b.location.page,
              top: b.location.bounds?[3] ?? double.infinity,
              text: b.text,
            ),
          for (final t in tables)
            (
              page: t.location.page,
              top: t.location.bounds?[3] ?? double.infinity,
              text: t.markdown,
            ),
        ]..sort((a, b) {
          final page = a.page.compareTo(b.page);
          return page != 0 ? page : b.top.compareTo(a.top);
        });
    return blocks
        .map((b) => b.text.trim())
        .where((s) => s.isNotEmpty)
        .join('\n\n');
  }

  String get summary => switch (completion) {
    DocumentCompletion.complete =>
      '已提取文字及可识别的规则表格（$processedPages/$totalPages 页）；图片未做 OCR。',
    DocumentCompletion.partial =>
      '已提取部分内容（$processedPages/$totalPages 页）；仍有未处理区域，原件已保留。',
    DocumentCompletion.noExtractableText => '未检测到可提取文字；可能为扫描件。原件已保留，尚未 OCR。',
    DocumentCompletion.failed => '正文未提取，原件已保留。',
  };
  Map<String, Object?> toJson() => {
    'completion': completion.name,
    'body': body.map((b) => b.toJson()).toList(),
    'tables': tables.map((t) => t.toJson()).toList(),
    'unprocessed': unprocessed.map((l) => l.toJson()).toList(),
    'problems': problems.map((p) => p.toJson()).toList(),
    'totalPages': totalPages,
    'processedPages': processedPages,
    'engine': engine,
  };
  factory DocumentExtraction.fromJson(Map<String, dynamic> json) =>
      DocumentExtraction(
        completion: DocumentCompletion.values.byName(
          json['completion'] as String,
        ),
        body: (json['body'] as List)
            .map((b) => DocumentBody.fromJson(b as Map<String, dynamic>))
            .toList(),
        tables: (json['tables'] as List)
            .map((t) => DocumentTable.fromJson(t as Map<String, dynamic>))
            .toList(),
        unprocessed: (json['unprocessed'] as List)
            .map((l) => DocumentLocation.fromJson(l as Map<String, dynamic>))
            .toList(),
        problems: (json['problems'] as List)
            .map((p) => DocumentProblem.fromJson(p as Map<String, dynamic>))
            .toList(),
        totalPages: json['totalPages'] as int,
        processedPages: json['processedPages'] as int,
        engine: json['engine'] as String,
      );
}

/// Callers may lower, but never raise, the hard resource limits.
class DocumentExtractionOptions {
  const DocumentExtractionOptions({
    this.maximumInputBytes = 32 * 1024 * 1024,
    this.maximumPages = 300,
    this.maximumPageCharacters = 100000,
    this.maximumCharacters = 1000000,
    this.maximumTableCells = 10000,
    this.timeBudget = const Duration(seconds: 30),
  });
  final int maximumInputBytes;
  final int maximumPages;
  final int maximumPageCharacters;
  final int maximumCharacters;
  final int maximumTableCells;
  final Duration timeBudget;
  void validate() {
    if (maximumInputBytes < 1 ||
        maximumInputBytes > 32 * 1024 * 1024 ||
        maximumPages < 1 ||
        maximumPages > 300 ||
        maximumPageCharacters < 1 ||
        maximumPageCharacters > 100000 ||
        maximumCharacters < 1 ||
        maximumCharacters > 1000000 ||
        maximumTableCells < 1 ||
        maximumTableCells > 10000 ||
        timeBudget <= Duration.zero ||
        timeBudget > const Duration(seconds: 30)) {
      throw ArgumentError('提取选项超出本机处理上限。');
    }
  }
}

enum DocumentImportStatus {
  savingOriginal,
  extracting,
  ready,
  interrupted,
  originalFailed,
  writePending,
}

class WorkspaceDocument {
  const WorkspaceDocument({
    required this.noteId,
    required this.status,
    this.attachmentId,
    this.result,
    this.error,
  });
  final String noteId;
  final String? attachmentId;
  final DocumentImportStatus status;
  final DocumentExtraction? result;
  final String? error;
}
