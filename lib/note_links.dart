import 'package:path/path.dart' as p;

/// Rewrites note destinations, retaining labels, anchors and literal code.
/// Source attachments are never passed through this transformation.
String rewriteNoteLinks(
  String text,
  String from,
  String oldPath,
  String newPath,
) {
  String? destination(String target, {required bool angled}) {
    final hash = target.indexOf('#');
    final path = hash < 0 ? target : target.substring(0, hash);
    final anchor = hash < 0 ? '' : target.substring(hash);
    if (path.isEmpty ||
        path.startsWith('/') ||
        Uri.tryParse(path)?.hasScheme == true) {
      return null;
    }
    String decoded;
    try {
      decoded = path
          .replaceAllMapped(
            RegExp(r'(?:%[a-fA-F0-9]{2})+'),
            (m) => Uri.decodeComponent(m[0]!),
          )
          .replaceAllMapped(RegExp(r'\\([() ])'), (m) => m[1]!);
    } on ArgumentError {
      return null;
    }
    if (p.posix.normalize(p.posix.join(p.posix.dirname(from), decoded)) !=
        oldPath) {
      return null;
    }
    var replacement = p.posix.relative(newPath, from: p.posix.dirname(from));
    if (path.startsWith('./') && !replacement.startsWith('.')) {
      replacement = './$replacement';
    }
    if (RegExp(r'%[a-fA-F0-9]{2}').hasMatch(path) ||
        RegExp(r'[#?%]').hasMatch(replacement) ||
        (!angled && RegExp(r'\s').hasMatch(replacement))) {
      replacement = Uri(path: replacement).toString();
    } else if (!angled && path.contains(r'\(')) {
      replacement = replacement.replaceAll('(', r'\(').replaceAll(')', r'\)');
    }
    return '$replacement$anchor';
  }

  String rewrite(String part, List<int> contentOffsets) {
    final wikiCode = _codeSpans(part);
    final wiki = part.replaceAllMapped(RegExp(r'\[\[([^\]\n]+)\]\]'), (match) {
      if (_escaped(part, match.start) || _insideCode(wikiCode, match.start)) {
        return match[0]!;
      }
      final value = match[1]!;
      final split = value.indexOf(RegExp(r'[#|]'));
      final target = split < 0 ? value : value.substring(0, split);
      final suffix = split < 0 ? '' : value.substring(split);
      final withExtension = target.toLowerCase().endsWith('.md');
      final normalized = p.posix.normalize(
        withExtension ? target : '$target.md',
      );
      if (normalized != oldPath) return match[0]!;
      final replacement = withExtension
          ? newPath
          : p.posix.withoutExtension(newPath);
      return '[[$replacement$suffix]]';
    });
    final inlineCode = _codeSpans(wiki);
    final inline = wiki.replaceAllMapped(
      RegExp(r'(\[[^\]\n]*\]\()(<[^>\n]*>|(?:\\.|[^()\n]|\([^()\n]*\))*)\)'),
      (match) {
        if (_escaped(wiki, match.start) ||
            _insideCode(inlineCode, match.start) ||
            _insideCode(inlineCode, match.start + match[1]!.length)) {
          return match[0]!;
        }
        final body = match[2]!;
        final angled = body.startsWith('<');
        final targetEnd = angled
            ? body.indexOf('>')
            : body.indexOf(RegExp(r'\s'));
        final target = angled
            ? body.substring(1, targetEnd)
            : targetEnd < 0
            ? body
            : body.substring(0, targetEnd);
        final tail = angled
            ? body.substring(targetEnd + 1)
            : targetEnd < 0
            ? ''
            : body.substring(targetEnd);
        final replacement = destination(target, angled: angled);
        if (replacement == null) return match[0]!;
        return '${match[1]}${angled ? '<' : ''}$replacement${angled ? '>' : ''}$tail)';
      },
    );
    final referenceCode = _codeSpans(inline);
    final lines = inline.split('\n');
    var lineOffset = 0;
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      final prefix = index < contentOffsets.length ? contentOffsets[index] : 0;
      final match = RegExp(
        r'^( {0,3}\[[^\]\n]+\]:[ \t]*)(<[^>\n]+>|[^\s]+)([\s\S]*)$',
      ).firstMatch(line.substring(prefix));
      if (match != null &&
          !_insideCode(referenceCode, lineOffset + prefix) &&
          !_insideCode(referenceCode, lineOffset + prefix + match[1]!.length)) {
        final target = match[2]!;
        final angled = target.startsWith('<');
        final replacement = destination(
          angled ? target.substring(1, target.length - 1) : target,
          angled: angled,
        );
        if (replacement != null) {
          lines[index] =
              '${line.substring(0, prefix)}${match[1]}${angled ? '<' : ''}$replacement${angled ? '>' : ''}${match[3]}';
        }
      }
      lineOffset += line.length + 1;
    }
    return lines.join('\n');
  }

  final output = StringBuffer();
  final paragraph = StringBuffer();
  final contentOffsets = <int>[];
  void flushParagraph() {
    if (paragraph.isEmpty) return;
    output.write(rewrite(paragraph.toString(), contentOffsets));
    paragraph.clear();
    contentOffsets.clear();
  }

  final blocks = _MarkdownBlocks();
  final lines = text.split('\n');
  for (var index = 0; index < lines.length; index++) {
    final line = lines[index];
    final original = '$line${index < lines.length - 1 ? '\n' : ''}';
    final region = blocks.read(line, hasParagraph: paragraph.isNotEmpty);
    if (region.boundary || region.protected) flushParagraph();
    if (region.protected) {
      output.write(original);
    } else {
      paragraph.write(original);
      contentOffsets.add(region.contentOffset);
    }
  }
  flushParagraph();
  return output.toString();
}

/// Only block context needed to protect code and locate link definitions. Raw
/// lines are retained; expanded tabs are used solely to count container columns.
class _MarkdownBlocks {
  final _containers = <_MarkdownContainer>[];
  ({String character, int length})? _fence;
  bool _indented = false;

  ({bool protected, bool boundary, int contentOffset}) read(
    String raw, {
    required bool hasParagraph,
  }) {
    final line = _expandTabs(raw);
    var offset = 0;
    var boundary = false;
    var paragraphContinuation = false;
    for (var index = 0; index < _containers.length; index++) {
      final next = _containers[index].continueAt(line, offset);
      if (next == null) {
        if (_fence == null &&
            hasParagraph &&
            _continuesParagraph(line.substring(offset))) {
          paragraphContinuation = true;
          break;
        }
        _containers.removeRange(index, _containers.length);
        _fence = null; // An unclosed fence ends with its containing block.
        _indented = false;
        boundary = true;
        break;
      }
      offset = next;
    }
    if (_fence != null) {
      final marker = _fenceAt(line.substring(offset));
      if (marker != null &&
          marker.run[0] == _fence!.character &&
          marker.run.length >= _fence!.length &&
          marker.tail.trim().isEmpty) {
        _fence = null;
      }
      return (protected: true, boundary: false, contentOffset: 0);
    }

    while (!paragraphContinuation) {
      final opening = _MarkdownContainer.openAt(line, offset);
      if (opening == null) break;
      _containers.add(opening.container);
      offset = opening.end;
      boundary = true;
      _indented = false;
    }
    final content = line.substring(offset);
    final originalOffset = _rawOffset(raw, offset);
    if (content.trim().isEmpty) {
      return (
        protected: true,
        boundary: boundary,
        contentOffset: originalOffset,
      );
    }
    final marker = _fenceAt(content);
    if (marker != null &&
        (marker.run[0] != '`' || !marker.tail.contains('`'))) {
      _fence = (character: marker.run[0], length: marker.run.length);
      _indented = false;
      return (protected: true, boundary: true, contentOffset: originalOffset);
    }
    if (content.startsWith('    ') &&
        (_indented || boundary || !hasParagraph)) {
      _indented = true;
      return (protected: true, boundary: true, contentOffset: originalOffset);
    }
    _indented = false;
    return (
      protected: false,
      boundary: boundary,
      contentOffset: originalOffset,
    );
  }

  ({String run, String tail})? _fenceAt(String content) {
    final match = RegExp(r'^ {0,3}(`{3,}|~{3,})(.*)$').firstMatch(content);
    return match == null ? null : (run: match[1]!, tail: match[2]!);
  }

  bool _continuesParagraph(String content) {
    if (content.trim().isEmpty ||
        _MarkdownContainer.openAt(content, 0) != null) {
      return false;
    }
    final fence = _fenceAt(content);
    if (fence != null && (fence.run[0] != '`' || !fence.tail.contains('`'))) {
      return false;
    }
    // Lazy paragraph lines may omit quote/list prefixes, but new block markers
    // end that paragraph. Fenced code never uses lazy continuation.
    return !RegExp(
      r'^ {0,3}(?:#{1,6}(?:\s|$)|(?:[-*_]\s*){3,}$|(?:=+|-+)\s*$|<(?:/?[A-Za-z]|!--|\?|!))',
    ).hasMatch(content);
  }
}

class _MarkdownContainer {
  const _MarkdownContainer.quote() : indentation = null;
  const _MarkdownContainer.list(this.indentation);
  final int? indentation;

  int? continueAt(String line, int offset) {
    final content = line.substring(offset);
    if (indentation == null) {
      final quote = RegExp(r'^ {0,3}> ?').firstMatch(content);
      return quote == null ? null : offset + quote.end;
    }
    if (content.trim().isEmpty) return line.length;
    return content.startsWith(' ' * indentation!)
        ? offset + indentation!
        : null;
  }

  static ({_MarkdownContainer container, int end})? openAt(
    String line,
    int offset,
  ) {
    final content = line.substring(offset);
    final quote = RegExp(r'^ {0,3}> ?').firstMatch(content);
    if (quote != null) {
      return (
        container: const _MarkdownContainer.quote(),
        end: offset + quote.end,
      );
    }
    final marker = RegExp(r'^ {0,3}(?:[-+*]|[0-9]{1,9}[.)])(?= |$)')
        .firstMatch(content);
    if (marker == null) return null;
    var end = marker.end;
    while (end < content.length && content[end] == ' ') {
      end++;
    }
    final padding = end - marker.end;
    // CommonMark uses one column when padding exceeds four, leaving the rest
    // as code indentation; empty list items still reserve one content column.
    final used = padding == 0 || padding > 4 ? 1 : padding;
    final indent = marker.end + used;
    return (
      container: _MarkdownContainer.list(indent),
      end: offset + (padding == 0 ? marker.end : marker.end + used),
    );
  }
}

String _expandTabs(String raw) {
  final output = StringBuffer();
  var column = 0;
  for (final character in raw.split('')) {
    if (character == '\t') {
      final width = 4 - column % 4;
      output.write(' ' * width);
      column += width;
    } else {
      output.write(character);
      column++;
    }
  }
  return output.toString();
}

int _rawOffset(String raw, int column) {
  var width = 0;
  for (var index = 0; index < raw.length; index++) {
    if (width >= column) return index;
    width += raw[index] == '\t' ? 4 - width % 4 : 1;
  }
  return raw.length;
}

bool _escaped(String text, int offset) {
  var slashes = 0;
  for (var index = offset - 1; index >= 0 && text[index] == r'\'; index--) {
    slashes++;
  }
  return slashes.isOdd;
}

/// Complete backtick runs delimit code; shorter runs inside are literal. A
/// closing run may follow a backslash because escapes do not apply inside code.
List<({int start, int end})> _codeSpans(String paragraph) {
  final runs = RegExp(r'`+').allMatches(paragraph).toList();
  final spans = <({int start, int end})>[];
  for (var index = 0; index < runs.length; index++) {
    final opening = runs[index];
    if (_escaped(paragraph, opening.start)) continue;
    for (var closing = index + 1; closing < runs.length; closing++) {
      if (runs[closing].group(0)!.length == opening.group(0)!.length) {
        spans.add((start: opening.start, end: runs[closing].end));
        index = closing;
        break;
      }
    }
  }
  return spans;
}

bool _insideCode(List<({int start, int end})> spans, int offset) =>
    spans.any((span) => span.start <= offset && offset < span.end);
