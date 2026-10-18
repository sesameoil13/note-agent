import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';
import 'package:xml/xml_events.dart';

import 'document_extraction.dart';

const _engine = 'docx/local-xml-v1';
const _wordNs = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
const _strictWordNs = 'http://purl.oclc.org/ooxml/wordprocessingml/main';
const _relNs = 'http://schemas.openxmlformats.org/package/2006/relationships';
const _contentNs =
    'http://schemas.openxmlformats.org/package/2006/content-types';

/// DOCX is read locally, never extracted to host paths. The worker owns only
/// pure Dart parsing and immutable retained input: cancellation can terminate
/// it, unlike a timeout around native work. No macros, external links or OCR.
class LocalWordExtractor implements DocumentExtractor {
  static Future<void> _queue = Future.value();
  Isolate? _worker;
  Completer<DocumentExtraction>? _result;
  bool _cancelled = false;
  @override
  void cancel() {
    _cancelled = true;
    _stop('cancelled', '已停止文档提取；原件继续保留，可重新提取。');
  }

  void _stop(String code, String message) {
    _worker?.kill(priority: Isolate.immediate);
    final result = _result;
    if (result != null && !result.isCompleted) {
      result.complete(_failure(code, message));
    }
  }

  @override
  Future<DocumentExtraction> extract(
    File original,
    String sourceId,
    DocumentExtractionOptions options,
  ) async {
    final previous = _queue;
    final done = Completer<void>();
    _queue = done.future;
    await previous;
    if (_cancelled) {
      done.complete();
      return _failure('cancelled', '已停止文档提取；原件继续保留。');
    }
    final port = ReceivePort();
    final exited = Completer<void>();
    final result = _result = Completer<DocumentExtraction>();
    final timer = Timer(
      options.timeBudget,
      () => _stop('timeLimit', '达到文档本机提取时间上限；原件继续保留，可重试。'),
    );
    port.listen((message) {
      if (message == null && !exited.isCompleted) exited.complete();
      if (result.isCompleted) return;
      if (message is DocumentExtraction) {
        result.complete(message);
      } else {
        result.complete(_failure('engineFailed', '本机 Word 提取未完成；原件已保留。'));
      }
    });
    try {
      _worker = await Isolate.spawn(
        _extractWord,
        (port.sendPort, original.path, sourceId, options),
        onError: port.sendPort,
        onExit: port.sendPort,
      );
      if (_cancelled || result.isCompleted) {
        _worker?.kill(priority: Isolate.immediate);
      }
      return await result.future;
    } catch (_) {
      return _failure('engineFailed', '本机 Word 引擎无法启动；原件已保留。');
    } finally {
      timer.cancel();
      _worker?.kill(priority: Isolate.immediate);
      // A result/cancel can arrive before worker teardown. Do not release the
      // global resource queue until its actual exit has been observed.
      if (_worker != null) await exited.future;
      port.close();
      _worker = null;
      _result = null;
      done.complete();
    }
  }
}

DocumentExtraction _failure(String code, String message) => DocumentExtraction(
  engine: _engine,
  completion: DocumentCompletion.failed,
  problems: [DocumentProblem(code, message)],
);

void _extractWord((SendPort, String, String, DocumentExtractionOptions) input) {
  final (port, path, sourceId, options) = input;
  try {
    final file = File(path);
    if (file.lengthSync() > options.maximumInputBytes) {
      throw const _WordProblem('inputLimit', '超过本机文档输入上限，未解析；完整原件已保留。');
    }
    final handle = file.openSync();
    late final Uint8List bytes;
    try {
      bytes = handle.readSync(options.maximumInputBytes + 1);
    } finally {
      handle.closeSync();
    }
    if (bytes.length > options.maximumInputBytes) {
      throw const _WordProblem('inputLimit', '超过本机文档输入上限，未解析；完整原件已保留。');
    }
    if (bytes.length >= 8 && bytes[0] == 0xd0 && bytes[1] == 0xcf) {
      throw const _WordProblem(
        'legacyOrEncrypted',
        '旧版 DOC 或加密 Office 文件暂不支持；请在本机 Word 中解锁并另存为 DOCX。原件已保留。',
      );
    }
    final package = _WordPackage(bytes);
    final rels = package.xml('_rels/.rels');
    if (rels.rootElement.name.namespaceUri != _relNs) {
      throw const FormatException();
    }
    final office = rels.rootElement.childElements
        .where(
          (e) =>
              e.name.local == 'Relationship' &&
              e.name.namespaceUri == _relNs &&
              (e.getAttribute('Type') ==
                      'http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument' ||
                  e.getAttribute('Type') ==
                      'http://purl.oclc.org/ooxml/officeDocument/relationships/officeDocument'),
        )
        .toList();
    if (office.length != 1 ||
        office.single.getAttribute('TargetMode') == 'External') {
      throw const FormatException();
    }
    final part = _partName(office.single.getAttribute('Target') ?? '');
    final contentTypes = package.xml('[Content_Types].xml');
    if (contentTypes.rootElement.name.namespaceUri != _contentNs) {
      throw const FormatException();
    }
    final declared = contentTypes.rootElement.childElements
        .where(
          (e) =>
              e.name.namespaceUri == _contentNs &&
              e.name.local == 'Override' &&
              _partKey(e.getAttribute('PartName') ?? '') == _partKey('/$part'),
        )
        .toList();
    if (declared.length != 1 ||
        declared.single.getAttribute('ContentType') !=
            'application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml') {
      throw const _WordProblem(
        'unsupportedWordFormat',
        '此 Office 包不是受支持的无宏 DOCX 文档；原件已保留。',
      );
    }
    final document = package.xml(part);
    final ns = document.rootElement.name.namespaceUri;
    if (document.rootElement.name.local != 'document' ||
        (ns != _wordNs && ns != _strictWordNs)) {
      throw const FormatException();
    }
    final body = document.rootElement.childElements
        .where((e) => e.name.namespaceUri == ns && e.name.local == 'body')
        .single;
    final reader = _WordReader(sourceId, part, ns!, options);
    reader.read(body);
    final slash = part.lastIndexOf('/');
    final directory = slash < 0 ? '' : part.substring(0, slash + 1);
    final filename = part.substring(slash + 1);
    final relPart = '${directory}_rels/$filename.rels';
    if (package.entries.containsKey(_partKey(relPart))) {
      final relationships = package.xml(relPart);
      if (relationships.rootElement.name.namespaceUri != _relNs) {
        throw const FormatException();
      }
      for (final relation in relationships.rootElement.childElements) {
        final type = relation.getAttribute('Type')?.split('/').last;
        if (const [
          'header',
          'footer',
          'footnotes',
          'endnotes',
          'comments',
          'aFChunk',
        ].contains(type)) {
          final external = relation.getAttribute('TargetMode') == 'External';
          final target = relation.getAttribute('Target') ?? '';
          reader.problem(
            'unsupportedStory',
            '页眉、页脚、脚注、批注或嵌入文档暂未提取；请核对原件。',
            DocumentLocation(
              sourceId: sourceId,
              part: external ? relPart : _partName('$directory$target'),
            ),
          );
        }
      }
    }
    port.send(reader.result());
  } on _WordProblem catch (e) {
    port.send(_failure(e.code, e.message));
  } catch (_) {
    port.send(
      _failure(
        'damagedWord',
        'Word 包或 XML 无法验证，可能损坏；原件已保留，可在本机 Word 中检查并另存为 DOCX。',
      ),
    );
  }
}

// OPC compares part URIs by ASCII case, independent of the host filesystem.
String _partKey(String name) => String.fromCharCodes(
  name.codeUnits.map((c) => c >= 65 && c <= 90 ? c + 32 : c),
);

String _partName(String name) {
  final trimmed = name.startsWith('/') ? name.substring(1) : name;
  if (trimmed.codeUnits.any((c) => c < 32 || c == 127) ||
      trimmed.isEmpty ||
      trimmed.contains('\\') ||
      trimmed.contains('%') ||
      trimmed.contains(':') ||
      trimmed.contains('?') ||
      trimmed.contains('#') ||
      trimmed.split('/').any((p) => p.isEmpty || p == '.' || p == '..')) {
    throw const FormatException('Unsafe package name');
  }
  return trimmed;
}

/// Preflight central + local headers before any inflate. Bounds are checked
/// before allocation; only required XML is read. CRC is explicit: archive's
/// decode(verify: true) does not verify it in the pinned release.
class _WordPackage {
  _WordPackage(this.bytes) {
    data = ByteData.sublistView(bytes);
    if (bytes.length < 22) throw const FormatException();
    var end = bytes.length - 22;
    while (end >= 0 && end >= bytes.length - 65557 && u32(end) != 0x06054b50) {
      end--;
    }
    if (end < 0 ||
        u32(end) != 0x06054b50 ||
        end + 22 + u16(end + 20) != bytes.length ||
        u16(end + 4) != 0 ||
        u16(end + 6) != 0 ||
        u16(end + 8) != u16(end + 10)) {
      throw const FormatException();
    }
    final count = u16(end + 10), size = u32(end + 12), start = u32(end + 16);
    if (count > 2048 || size > 1024 * 1024) {
      throw const _WordProblem('packageLimit', 'Word 包条目过多，超过本机提取上限；原件已保留。');
    }
    if (start + size != end) throw const FormatException();
    var offset = start;
    final ranges = <(int, int)>[];
    for (var i = 0; i < count; i++) {
      if (offset + 46 > end || u32(offset) != 0x02014b50) {
        throw const FormatException();
      }
      final flags = u16(offset + 8), method = u16(offset + 10);
      final crc = u32(offset + 16),
          compressed = u32(offset + 20),
          expanded = u32(offset + 24);
      final nameLength = u16(offset + 28),
          extraLength = u16(offset + 30),
          commentLength = u16(offset + 32);
      final local = u32(offset + 42);
      if (offset + 46 + nameLength + extraLength + commentLength > end ||
          local + 30 > start) {
        throw const FormatException();
      }
      if (flags & 0x41 != 0) {
        throw const _WordProblem(
          'encryptedWord',
          '加密 DOCX 暂不支持，请在本机解锁后重新导入；原件已保留。',
        );
      }
      if (method != 0 && method != 8 ||
          u16(offset + 34) != 0 ||
          (u32(offset + 38) >> 16) & 0xf000 == 0xa000) {
        throw const FormatException();
      }
      final nameBytes = bytes.sublist(offset + 46, offset + 46 + nameLength);
      final rawName = utf8.decode(nameBytes);
      final name = _partName(
        rawName.endsWith('/')
            ? rawName.substring(0, rawName.length - 1)
            : rawName,
      );
      if (entries.containsKey(_partKey(name))) {
        throw const FormatException('Duplicate part');
      }
      if (u32(local) != 0x04034b50 ||
          u16(local + 6) != flags ||
          u16(local + 8) != method) {
        throw const FormatException();
      }
      final localNameLength = u16(local + 26), localExtra = u16(local + 28);
      final payload = local + 30 + localNameLength + localExtra;
      if (payload + compressed > start ||
          utf8.decode(
                bytes.sublist(local + 30, local + 30 + localNameLength),
              ) !=
              rawName) {
        throw const FormatException();
      }
      if (flags & 8 == 0 &&
          (u32(local + 14) != crc ||
              u32(local + 18) != compressed ||
              u32(local + 22) != expanded)) {
        throw const FormatException();
      }
      var payloadEnd = payload + compressed;
      if (flags & 8 != 0) {
        final skips = [
          0,
          if (payloadEnd + 4 <= start && u32(payloadEnd) == 0x08074b50) 4,
        ];
        final matching = skips
            .where(
              (skip) =>
                  payloadEnd + skip + 12 <= start &&
                  u32(payloadEnd + skip) == crc &&
                  u32(payloadEnd + skip + 4) == compressed &&
                  u32(payloadEnd + skip + 8) == expanded,
            )
            .toList();
        if (matching.isEmpty) {
          throw const FormatException('Invalid data descriptor');
        }
        payloadEnd += matching.last + 12;
      }
      ranges.add((local, payloadEnd));
      entries[_partKey(name)] = (
        payload: payload,
        compressed: compressed,
        expanded: expanded,
        crc: crc,
        method: method,
      );
      offset += 46 + nameLength + extraLength + commentLength;
    }
    if (offset != end) throw const FormatException();
    ranges.sort((a, b) => a.$1.compareTo(b.$1));
    for (var i = 1; i < ranges.length; i++) {
      if (ranges[i].$1 < ranges[i - 1].$2) throw const FormatException();
    }
  }
  final Uint8List bytes;
  late final ByteData data;
  final entries =
      <
        String,
        ({int payload, int compressed, int expanded, int crc, int method})
      >{};
  var consumedXml = 0;
  int u16(int n) => data.getUint16(n, Endian.little);
  int u32(int n) => data.getUint32(n, Endian.little);
  XmlDocument xml(String name) {
    final entry = entries[_partKey(name)];
    if (entry == null) throw const FormatException('Missing required part');
    if (entry.expanded > 4 * 1024 * 1024 ||
        consumedXml + entry.expanded > 8 * 1024 * 1024) {
      throw const _WordProblem('xmlLimit', 'Word XML 超过本机展开上限；原件已保留。');
    }
    final raw = Uint8List.sublistView(
      bytes,
      entry.payload,
      entry.payload + entry.compressed,
    );
    final content = entry.method == 0
        ? raw
        : const ZLibDecoder().decodeBytes(
            raw,
            raw: true,
            maxOutputSize: entry.expanded,
          );
    if (content.length != entry.expanded || getCrc32(content) != entry.crc) {
      throw const _WordProblem(
        'damagedWordCrc',
        'Word 必需部分的校验失败；未采用损坏正文，原件已保留。',
      );
    }
    consumedXml += content.length;
    final String text;
    if (content.length >= 2 &&
        ((content[0] == 0xff && content[1] == 0xfe) ||
            (content[0] == 0xfe && content[1] == 0xff))) {
      if (content.length.isOdd) throw const FormatException('Truncated UTF16');
      final data = ByteData.sublistView(content);
      final endian = content[0] == 0xff ? Endian.little : Endian.big;
      text = String.fromCharCodes([
        for (var i = 2; i < content.length; i += 2) data.getUint16(i, endian),
      ]);
    } else {
      text = utf8.decode(content);
    }
    var depth = 0, events = 0;
    for (final event in parseEvents(
      text,
      validateNesting: true,
      validateNamespace: true,
      validateDocument: true,
    )) {
      if (++events > 250000) {
        throw const _WordProblem('xmlLimit', 'Word XML 结构超过本机上限；原件已保留。');
      }
      if (event is XmlDoctypeEvent) {
        throw const _WordProblem('unsafeXml', '不处理含 DTD／外部实体声明的文档；原件已保留。');
      }
      if (event is XmlStartElementEvent) {
        if (++depth > 64 || event.attributes.length > 64) {
          throw const _WordProblem('xmlLimit', 'Word XML 层级或属性超过本机上限；原件已保留。');
        }
        if (event.isSelfClosing) depth--;
      } else if (event is XmlEndElementEvent) {
        depth--;
      }
    }
    return XmlDocument.parse(text);
  }
}

class _WordReader {
  _WordReader(this.sourceId, this.part, this.ns, this.options);
  final String sourceId, part, ns;
  final DocumentExtractionOptions options;
  final body = <DocumentBody>[];
  final tables = <DocumentTable>[];
  final unprocessed = <DocumentLocation>[];
  final problems = <DocumentProblem>[];
  int characters = 0, cells = 0;
  bool isWord(XmlElement e, String local) =>
      e.name.namespaceUri == ns && e.name.local == local;
  DocumentLocation location(int block, [String suffix = '']) =>
      DocumentLocation(
        sourceId: sourceId,
        part: '$part$suffix',
        blockIndex: block,
      );
  void read(XmlElement container) {
    for (final (index, e)
        in container.childElements.where((e) => !isWord(e, 'sectPr')).indexed) {
      final loc = location(index);
      if (e.descendantElements.any(
        (node) =>
            isWord(node, 'drawing') ||
            isWord(node, 'pict') ||
            isWord(node, 'object'),
      )) {
        problem('imageRegion', '此处含图片、绘图或嵌入对象，尚未识别／OCR；可提取文字仍已保留。', loc);
      }
      final descendants = [e, ...e.descendantElements];
      if (descendants.any(
        (n) =>
            isWord(n, 'ins') ||
            isWord(n, 'del') ||
            isWord(n, 'moveFrom') ||
            isWord(n, 'moveTo'),
      )) {
        problem('revisions', '文档含修订：采用当前视图（保留插入，忽略删除／移出）；未保留修订历史，请核对原件。', loc);
      }
      if (descendants.any((n) => isWord(n, 'numPr'))) {
        problem('listNumbering', '列表正文已保留，但自动编号／项目符号未重建；请核对原件。', loc);
      }
      if (descendants.any(
        (n) =>
            isWord(n, 'fldChar') ||
            isWord(n, 'fldSimple') ||
            isWord(n, 'instrText'),
      )) {
        problem('fieldResult', '字段仅保留已有显示文字，未执行或刷新字段；请核对原件。', loc);
      }
      if (descendants.any(
        (n) =>
            n.name.local == 'AlternateContent' ||
            n.name.local == 'oMath' ||
            isWord(n, 'txbxContent'),
      )) {
        problem(
          'unsupportedBlock',
          '此处含公式、文本框或替代内容，未完整识别；可读文字仅供核对，原件已保留。',
          loc,
        );
      }
      if (descendants.any(
        (n) =>
            n.name.namespaceUri == ns &&
            const [
              'sym',
              'altChunk',
              'subDoc',
              'contentPart',
              'footnoteReference',
              'endnoteReference',
            ].contains(n.name.local),
      )) {
        problem('unsupportedInline', '此处含特殊符号、脚注引用或嵌入内容，未完整提取；请核对原件。', loc);
      }
      if (isWord(e, 'p')) {
        final text = _text(e);
        if (!_addBody(text, loc, index)) break;
      } else if (isWord(e, 'tbl')) {
        final cellCount = e.descendantElements
            .where((n) => isWord(n, 'tc'))
            .length;
        if (cells + cellCount > options.maximumTableCells) {
          problem('tableLimit', '此表格超过本机单元格处理上限，尚未提取；正文与原件继续保留。', loc);
          continue;
        }
        cells += cellCount;
        final sourceRows = e.childElements
            .where((e) => isWord(e, 'tr'))
            .toList();
        final widths = sourceRows
            .map((r) => r.childElements.where((c) => isWord(c, 'tc')).length)
            .toSet();
        final complex =
            widths.length != 1 ||
            widths.contains(0) ||
            e.descendantElements.any(
              (n) =>
                  isWord(n, 'gridSpan') ||
                  isWord(n, 'vMerge') ||
                  isWord(n, 'hMerge') ||
                  isWord(n, 'tbl'),
            );
        if (complex) {
          problem('complexTable', '此表格含合并、嵌套或不规则结构；按原顺序保留可提取文字，未重建复杂版式。', loc);
          final text = _plain(e);
          if (!_addBody(text, loc, index)) break;
          continue;
        }
        final rows = <List<DocumentCell>>[];
        for (final (rowIndex, row)
            in e.childElements.where((e) => isWord(e, 'tr')).indexed) {
          rows.add([
            for (final (cellIndex, cell)
                in row.childElements.where((e) => isWord(e, 'tc')).indexed)
              DocumentCell(
                cell.childElements
                    .where((e) => isWord(e, 'p'))
                    .map(_text)
                    .join('\n'),
                location(index, '#block=$index/row=$rowIndex/cell=$cellIndex'),
              ),
          ]);
        }
        if (rows.isNotEmpty && rows.first.isNotEmpty) {
          final table = DocumentTable(rows, loc, order: index);
          if (!_reserve(table.markdown, loc)) break;
          tables.add(table);
        }
      } else {
        problem(
          'unsupportedBlock',
          '此处含内容控件、嵌入文档或尚不支持的正文结构；已尽量保留可读文字，请核对原件。',
          loc,
        );
        final text = _plain(e);
        if (!_addBody(text, loc, index)) break;
      }
    }
  }

  bool _reserve(String text, DocumentLocation loc) {
    if (text.trim().isEmpty) return true;
    final length = text.trim().length + (characters == 0 ? 0 : 2);
    if (characters + length > options.maximumCharacters) {
      problem('outputLimit', '达到提取文字／表格输出上限；此位置及后续正文尚未处理，完整原件已保留。', loc);
      return false;
    }
    characters += length;
    return true;
  }

  bool _addBody(String text, DocumentLocation loc, int index) {
    if (!_reserve(text, loc)) return false;
    if (text.trim().isNotEmpty) body.add(DocumentBody(text, loc, order: index));
    return true;
  }

  String _plain(XmlElement e) {
    if (isWord(e, 'del') || isWord(e, 'moveFrom')) return '';
    if (isWord(e, 'p')) return _text(e);
    return e.childElements.map(_plain).where((s) => s.isNotEmpty).join('\n');
  }

  String _text(XmlElement e) {
    if (e.name.local == 'AlternateContent' &&
        e.name.namespaceUri ==
            'http://schemas.openxmlformats.org/markup-compatibility/2006') {
      final branch = e.childElements.firstOrNull;
      return branch == null ? '' : _text(branch);
    }
    if (isWord(e, 'noBreakHyphen')) return '‑';
    if (isWord(e, 'softHyphen')) return '­';
    if (isWord(e, 'del') || isWord(e, 'moveFrom')) return '';
    if (isWord(e, 't')) return e.innerText;
    if (isWord(e, 'tab')) return '\t';
    if (isWord(e, 'br') || isWord(e, 'cr')) return '\n';
    return e.childElements.map(_text).join();
  }

  void problem(String code, String message, DocumentLocation loc) {
    problems.add(DocumentProblem(code, message));
    unprocessed.add(loc);
  }

  DocumentExtraction result() => DocumentExtraction(
    engine: _engine,
    completion: body.isEmpty && tables.isEmpty
        ? problems.every((p) => p.code == 'imageRegion')
              ? DocumentCompletion.noExtractableText
              : DocumentCompletion.failed
        : problems.isEmpty
        ? DocumentCompletion.complete
        : DocumentCompletion.partial,
    body: body,
    tables: tables,
    unprocessed: unprocessed,
    problems: problems,
  );
}

class _WordProblem implements Exception {
  const _WordProblem(this.code, this.message);
  final String code, message;
}
