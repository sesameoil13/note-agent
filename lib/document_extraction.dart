import 'dart:io';

/// Engine-neutral document results. Future OCR/Word adapters use these same
/// values; no native PDF handles or layout engine types cross this boundary.
enum DocumentCompletion { complete, partial, noExtractableText, failed }

class DocumentLocation {
  const DocumentLocation({
    required this.sourceId,
    this.page,
    this.lastPage,
    this.part,
    this.blockIndex,
    this.bounds,
    this.coordinateSpace,
    this.rotation = 0,
  });
  final String sourceId;

  /// Optional 1-based page. Reflowable formats must not invent pagination.
  final int? page;

  /// Inclusive end of an unprocessed page range; null denotes one page.
  final int? lastPage;

  /// Format-specific source part and zero-based block within that part.
  final String? part;
  final int? blockIndex;

  /// [left, bottom, right, top], interpreted only in [coordinateSpace].
  final List<double>? bounds;
  final String? coordinateSpace;
  final int rotation;
  Map<String, Object?> toJson() => {
    'sourceId': sourceId,
    'page': page,
    'lastPage': lastPage,
    'part': part,
    'blockIndex': blockIndex,
    'bounds': bounds,
    'rotation': rotation,
    'coordinates': coordinateSpace,
  };
  factory DocumentLocation.fromJson(Map<String, dynamic> json) =>
      DocumentLocation(
        sourceId: json['sourceId'] as String,
        page: json['page'] as int?,
        lastPage: json['lastPage'] as int?,
        part: json['part'] as String?,
        blockIndex: json['blockIndex'] as int?,
        bounds: (json['bounds'] as List?)
            ?.map((n) => (n as num).toDouble())
            .toList(),
        rotation: json['rotation'] as int? ?? 0,
        coordinateSpace: json['coordinates'] as String?,
      );
}

/// Internal adapter seam shared by local document formats and future OCR.
/// The source is an already-retained private file; adapters never publish notes.
abstract interface class DocumentExtractor {
  Future<DocumentExtraction> extract(
    File original,
    String sourceId,
    DocumentExtractionOptions options,
  );

  /// Cooperatively stop later work; an in-flight native call may finish first.
  void cancel();
}

class DocumentBody {
  const DocumentBody(this.text, this.location, {this.order});
  final String text;
  final DocumentLocation location;

  /// Global block order across body and tables, independent of pagination.
  final int? order;
  Map<String, Object?> toJson() => {
    'text': text,
    'location': location.toJson(),
    'order': order,
  };
  factory DocumentBody.fromJson(Map<String, dynamic> json) => DocumentBody(
    json['text'] as String,
    DocumentLocation.fromJson(json['location'] as Map<String, dynamic>),
    order: json['order'] as int?,
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
  const DocumentTable(this.rows, this.location, {this.order});
  final List<List<DocumentCell>> rows;
  final DocumentLocation location;
  final int? order;
  Map<String, Object?> toJson() => {
    'rows': rows.map((r) => r.map((c) => c.toJson()).toList()).toList(),
    'location': location.toJson(),
    'order': order,
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
    order: json['order'] as int?,
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
    this.engine = 'unspecified',
  });
  final DocumentCompletion completion;
  final List<DocumentBody> body;
  final List<DocumentTable> tables;
  final List<DocumentLocation> unprocessed;
  final List<DocumentProblem> problems;
  /// Zero when the source format has no reliable pagination.
  final int totalPages;
  final int processedPages;
  final String engine;

  /// Adapters can provide global block order across body and tables. Legacy
  /// PDF results fall back to page/top, with stable order for equal positions.
  String get markdown {
    final blocks =
        <({int? order, int? page, double top, int index, String text})>[
          for (final (index, b) in body.indexed)
            (
              order: b.order,
              page: b.location.page,
              top: b.location.bounds?[3] ?? double.infinity,
              index: index,
              text: b.text,
            ),
          for (final (index, t) in tables.indexed)
            (
              order: t.order,
              page: t.location.page,
              top: t.location.bounds?[3] ?? double.infinity,
              index: body.length + index,
              text: t.markdown,
            ),
        ]..sort((a, b) {
          if (a.order != null || b.order != null) {
            if (a.order == null) return 1;
            if (b.order == null) return -1;
            final order = a.order!.compareTo(b.order!);
            return order != 0 ? order : a.index.compareTo(b.index);
          }
          final page = (a.page ?? 0).compareTo(b.page ?? 0);
          if (page != 0) return page;
          final top = b.top.compareTo(a.top);
          return top != 0 ? top : a.index.compareTo(b.index);
        });
    return blocks
        .map((b) => b.text.trim())
        .where((s) => s.isNotEmpty)
        .join('\n\n');
  }

  String get summary {
    final coverage = totalPages > 0 ? '（$processedPages/$totalPages 页）' : '';
    final content = engine.startsWith('pdfium/')
        ? '已提取文字及可识别的规则表格'
        : '已提取文字及可提取表格';
    return switch (completion) {
      DocumentCompletion.complete => '$content$coverage；图片未做 OCR。',
      DocumentCompletion.partial => '已提取部分内容$coverage；仍有未处理区域，原件已保留。',
      DocumentCompletion.noExtractableText => '未检测到可提取文字；可能为扫描件。原件已保留，尚未 OCR。',
      DocumentCompletion.failed => '正文未提取，原件已保留。',
    };
  }

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
