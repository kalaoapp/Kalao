import 'package:kalao/models/lyrics.dart';

/// Timing maths for timed lyrics (IMPLEMENTATION.md §4 "Sync and sweep").
/// Positions are engine song time in milliseconds with the document offset
/// already added.

/// The longest a line without an end or a following line sweeps for, and the
/// cap on a linear sweep so a line before a long instrumental gap does not
/// crawl.
const maxLinearSweepMs = 10000;
const _fallbackLineMs = 5000;

/// When [line] stops being sung: its own end, else the start of the next
/// lead line ([nextStartMs]), else a few seconds after it starts.
int lineEndMs(LyricLine line, {int? nextStartMs}) {
  final start = line.time.inMilliseconds;
  final end = line.end?.inMilliseconds ?? nextStartMs;
  return end != null && end > start ? end : start + _fallbackLineMs;
}

/// How many UTF-16 units of [line]'s text have been sung at [ms], as a
/// fraction-carrying number in [0, text.length].
///
/// With word timing the sweep crosses each word during that word and waits
/// between words. Without it the sweep is linear over the line's duration.
double sweptChars(LyricLine line, int ms, {int? nextStartMs}) {
  final length = line.text.length.toDouble();
  final start = line.time.inMilliseconds;
  if (length == 0 || ms <= start) return 0;
  if (line.words.isEmpty) {
    final end = lineEndMs(line, nextStartMs: nextStartMs);
    final duration = (end - start).clamp(1, maxLinearSweepMs);
    return ((ms - start) / duration).clamp(0.0, 1.0) * length;
  }
  var swept = 0.0;
  for (var index = 0; index < line.words.length; index++) {
    final word = line.words[index];
    final wordStart = word.time.inMilliseconds;
    if (ms < wordStart) break;
    final next = index + 1 < line.words.length
        ? line.words[index + 1].time.inMilliseconds
        : lineEndMs(line, nextStartMs: nextStartMs);
    final wordEnd = word.end?.inMilliseconds ?? next;
    final duration = wordEnd - wordStart;
    final fraction = duration <= 0
        ? 1.0
        : ((ms - wordStart) / duration).clamp(0.0, 1.0);
    swept = word.start + fraction * word.text.length;
    // Carry the sweep across the space after a finished word.
    if (fraction >= 1 && index + 1 < line.words.length) {
      swept = line.words[index + 1].start.toDouble();
    } else if (fraction >= 1) {
      swept = length;
    }
  }
  return swept.clamp(0.0, length);
}

/// The start of the first lead line after [index], for line ends.
int? nextLeadStartMs(List<LyricLine> lines, int index) {
  for (var next = index + 1; next < lines.length; next++) {
    if (!lines[next].isBacking) return lines[next].time.inMilliseconds;
  }
  return null;
}

final _cjk = RegExp(r'[぀-ヿ㐀-䶿一-鿿豈-﫿가-힯]');

bool isCjk(String char) => _cjk.hasMatch(char);

final _wordChar = RegExp(r'[\p{L}\p{N}]', unicode: true);

/// Splits [text] into the units tapped in the sync editor's word mode: one
/// per CJK character, one per whitespace-separated word otherwise.
/// Punctuation stays with the unit before it (or after it, at the start).
/// Returns UTF-16 ranges (start, end) that skip only whitespace.
List<(int, int)> splitWords(String text) {
  final ranges = <(int, int)>[];
  // Opening punctuation waiting for the unit after it.
  int? pending;
  var gap = true;
  var wordOpen = false;
  var offset = 0;
  for (final rune in text.runes) {
    final char = String.fromCharCode(rune);
    final next = offset + char.length;
    if (char.trim().isEmpty) {
      gap = true;
      wordOpen = false;
    } else if (isCjk(char)) {
      ranges.add((pending ?? offset, next));
      pending = null;
      gap = false;
      wordOpen = false;
    } else if (_wordChar.hasMatch(char)) {
      if (wordOpen && !gap) {
        ranges[ranges.length - 1] = (ranges.last.$1, next);
      } else {
        ranges.add((pending ?? offset, next));
        pending = null;
      }
      gap = false;
      wordOpen = true;
    } else if (ranges.isNotEmpty && !gap) {
      ranges[ranges.length - 1] = (ranges.last.$1, next);
    } else {
      pending ??= offset;
      gap = false;
    }
    offset = next;
  }
  if (pending != null) {
    if (ranges.isEmpty) {
      ranges.add((pending, text.trimRight().length));
    } else {
      ranges[ranges.length - 1] = (ranges.last.$1, text.trimRight().length);
    }
  }
  return ranges;
}
