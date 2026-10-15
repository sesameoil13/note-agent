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

  String rewrite(String part) {
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
    return inline.replaceAllMapped(
      RegExp(
        r'^( {0,3}\[[^\]\n]+\]:[ \t]*)(<[^>\n]+>|[^\s]+)(.*)$',
        multiLine: true,
      ),
      (match) {
        if (_insideCode(referenceCode, match.start) ||
            _insideCode(referenceCode, match.start + match[1]!.length)) {
          return match[0]!;
        }
        final target = match[2]!;
        final angled = target.startsWith('<');
        final replacement = destination(
          angled ? target.substring(1, target.length - 1) : target,
          angled: angled,
        );
        if (replacement == null) return match[0]!;
        return '${match[1]}${angled ? '<' : ''}$replacement${angled ? '>' : ''}${match[3]}';
      },
    );
  }

  final output = StringBuffer();
  final paragraph = StringBuffer();
  void flushParagraph() {
    if (paragraph.isEmpty) return;
    output.write(rewrite(paragraph.toString()));
    paragraph.clear();
  }

  String? fence;
  var fenceLength = 0;
  final lines = text.split('\n');
  for (var index = 0; index < lines.length; index++) {
    final line = lines[index];
    final original = '$line${index < lines.length - 1 ? '\n' : ''}';
    final marker = RegExp(r'^(?: {0,3}>[ \t]?)* {0,3}(`{3,}|~{3,})')
        .firstMatch(line);
    if (fence != null) {
      output.write(original);
      if (marker != null &&
          marker[1]![0] == fence &&
          marker[1]!.length >= fenceLength &&
          line.substring(marker.end).trim().isEmpty) {
        fence = null;
      }
      continue;
    }
    if (marker != null &&
        (marker[1]![0] != '`' || !line.substring(marker.end).contains('`'))) {
      flushParagraph();
      fence = marker[1]![0];
      fenceLength = marker[1]!.length;
      output.write(original);
    } else if (line.trim().isEmpty ||
        line.startsWith('    ') ||
        line.startsWith('\t')) {
      flushParagraph();
      output.write(original);
    } else {
      paragraph.write(original);
    }
  }
  flushParagraph();
  return output.toString();
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
