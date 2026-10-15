import 'package:path/path.dart' as p;

/// Rewrites note destinations, retaining labels, anchors and literal code.
/// Source attachments are never passed through this transformation.
String rewriteNoteLinks(
  String text,
  String from,
  String oldPath,
  String newPath,
) {
  String rewrite(String part) {
    final wiki = part.replaceAllMapped(RegExp(r'\[\[([^\]\n]+)\]\]'), (match) {
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
    return wiki.replaceAllMapped(
      RegExp(r'(\[[^\]\n]*\]\()(<[^>\n]*>|(?:\\.|[^()\n]|\([^()\n]*\))*)\)'),
      (match) {
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
        final hash = target.indexOf('#');
        final path = hash < 0 ? target : target.substring(0, hash);
        final anchor = hash < 0 ? '' : target.substring(hash);
        if (path.isEmpty ||
            path.startsWith('/') ||
            Uri.tryParse(path)?.hasScheme == true) {
          return match[0]!;
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
          return match[0]!;
        }
        if (p.posix.normalize(p.posix.join(p.posix.dirname(from), decoded)) !=
            oldPath) {
          return match[0]!;
        }
        var replacement = p.posix.relative(
          newPath,
          from: p.posix.dirname(from),
        );
        if (path.startsWith('./') && !replacement.startsWith('.')) {
          replacement = './$replacement';
        }
        if (RegExp(r'%[a-fA-F0-9]{2}').hasMatch(path)) {
          replacement = Uri(path: replacement).toString();
        } else if (!angled && path.contains(r'\(')) {
          replacement = replacement
              .replaceAll('(', r'\(')
              .replaceAll(')', r'\)');
        }
        return '${match[1]}${angled ? '<' : ''}$replacement$anchor${angled ? '>' : ''}$tail)';
      },
    );
  }

  String? fence;
  var fenceLength = 0;
  return text
      .split('\n')
      .map((line) {
        final marker = RegExp(r'^ {0,3}(`{3,}|~{3,})').firstMatch(line);
        if (marker != null) {
          final value = marker[1]!;
          if (fence == null) {
            fence = value[0];
            fenceLength = value.length;
          } else if (value[0] == fence &&
              value.length >= fenceLength &&
              line.substring(marker.end).trim().isEmpty) {
            fence = null;
          }
          return line;
        }
        if (fence != null || line.startsWith('    ') || line.startsWith('\t')) {
          return line;
        }
        return line.splitMapJoin(
          RegExp(r'(`+)[^`]*\1'),
          onMatch: (m) => m[0]!,
          onNonMatch: rewrite,
        );
      })
      .join('\n');
}
