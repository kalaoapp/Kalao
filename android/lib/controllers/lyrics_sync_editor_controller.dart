import 'package:flutter/foundation.dart';
import 'package:kalao/models/lyrics.dart';
import 'package:kalao/utils/lyrics_timeline.dart';

/// What a tap stamps in the sync editor.
enum SyncMode { line, word }

/// A word of a draft line: the UTF-16 range [start, end) of the line text.
@immutable
class DraftWord {
  const DraftWord(this.start, this.end, {this.timeMs, this.endMs});

  final int start;
  final int end;
  final int? timeMs;
  final int? endMs;

  DraftWord timed(int? timeMs, int? endMs) =>
      DraftWord(start, end, timeMs: timeMs, endMs: endMs);
}

/// A line being timed. Times are song time in ms, null until stamped.
@immutable
class DraftLine {
  const DraftLine(
    this.source, {
    this.timeMs,
    this.endMs,
    this.words = const [],
  });

  /// The line the draft started from (text, section, layers).
  final LyricLine source;
  final int? timeMs;
  final int? endMs;
  final List<DraftWord> words;

  String get text => source.text;

  /// Every word has a start, so the line can be saved word-timed.
  bool get wordTimed =>
      words.isNotEmpty && words.every((word) => word.timeMs != null);

  DraftLine copyWith({
    int? Function()? timeMs,
    int? Function()? endMs,
    List<DraftWord>? words,
  }) => DraftLine(
    source,
    timeMs: timeMs != null ? timeMs() : this.timeMs,
    endMs: endMs != null ? endMs() : this.endMs,
    words: words ?? this.words,
  );
}

class _Snapshot {
  const _Snapshot(this.lines, this.cursor, this.wordCursor, this.target);

  final List<DraftLine> lines;
  final int cursor;
  final int wordCursor;
  final (int, int?)? target;
}

/// The tap-to-time editor's draft (IMPLEMENTATION.md §4 "Sync editor"):
/// each tap stamps the start of the line (or word) under the cursor with the
/// song position; holding the tap until the end also stamps where it ends.
/// Nudge moves the last stamped (or selected) item; undo restores the draft
/// before the last stamp or nudge.
///
/// Positions passed in are song time, already corrected for tap latency.
class LyricsSyncEditor extends ChangeNotifier {
  LyricsSyncEditor(LyricDocument doc) : _doc = doc {
    _lines = [for (final line in doc.lines) _draft(line, doc)];
  }

  /// A tap held at least this long also stamps the end.
  static const holdThreshold = Duration(milliseconds: 350);

  final LyricDocument _doc;
  late List<DraftLine> _lines;
  final _undo = <_Snapshot>[];
  SyncMode _mode = SyncMode.line;
  int _cursor = 0;
  int _wordCursor = 0;
  (int, int?)? _target;
  (int, int?)? _holding;

  List<DraftLine> get lines => _lines;
  SyncMode get mode => _mode;

  /// The line the next tap stamps; `lines.length` after the last line.
  int get cursor => _cursor;

  /// The word of the cursor line the next tap stamps (word mode).
  int get wordCursor => _wordCursor;

  /// The line (and word) nudge moves, or null before anything is stamped.
  (int, int?)? get target => _target;
  bool get canUndo => _undo.isNotEmpty;
  bool get finished => _cursor >= _lines.length;

  /// Lines still without a start.
  int get remaining => _lines.where((line) => line.timeMs == null).length;
  bool get complete => _lines.isNotEmpty && remaining == 0;

  /// Existing timing is kept (with the document offset applied, so the saved
  /// draft needs none); untimed lines start empty.
  static DraftLine _draft(LyricLine line, LyricDocument doc) {
    int shifted(Duration time) =>
        (time.inMilliseconds - doc.offsetMs).clamp(0, 1 << 31);
    final words = line.words.isNotEmpty
        ? [
            for (final word in line.words)
              DraftWord(
                word.start,
                word.start + word.text.length,
                timeMs: doc.timed ? shifted(word.time) : null,
                endMs: doc.timed && word.end != null
                    ? shifted(word.end!)
                    : null,
              ),
          ]
        : [
            for (final (start, end) in splitWords(line.text))
              DraftWord(start, end),
          ];
    return DraftLine(
      line,
      timeMs: doc.timed ? shifted(line.time) : null,
      endMs: doc.timed && line.end != null ? shifted(line.end!) : null,
      words: words,
    );
  }

  void _remember() =>
      _undo.add(_Snapshot(_lines, _cursor, _wordCursor, _target));

  void _replace(int index, DraftLine line) =>
      _lines = [..._lines]..[index] = line;

  void setMode(SyncMode mode) {
    if (mode == _mode) return;
    _mode = mode;
    _wordCursor = 0;
    notifyListeners();
  }

  /// Moves the cursor to [line]: the next tap re-times it, nudge moves it.
  void select(int line) {
    if (line < 0 || line >= _lines.length) return;
    _cursor = line;
    _wordCursor = 0;
    _target = (line, null);
    notifyListeners();
  }

  /// The tap went down at [positionMs]: the start of the cursor's line, or
  /// of its next word in word mode.
  void tapDown(int positionMs) {
    if (finished) return;
    final ms = positionMs < 0 ? 0 : positionMs;
    final line = _lines[_cursor];
    _remember();
    if (_mode == SyncMode.line || line.words.isEmpty) {
      _replace(
        _cursor,
        line.copyWith(
          timeMs: () => ms,
          endMs: () => null,
          words: [for (final word in line.words) word.timed(null, null)],
        ),
      );
      _holding = _target = (_cursor, null);
    } else {
      final index = _wordCursor.clamp(0, line.words.length - 1);
      final words = [
        for (final (i, word) in line.words.indexed)
          if (i == index)
            word.timed(ms, null)
          else if (i > index || index == 0)
            word.timed(null, null)
          else
            word,
      ];
      _replace(
        _cursor,
        line.copyWith(
          timeMs: index == 0 ? () => ms : null,
          endMs: () => null,
          words: words,
        ),
      );
      _holding = _target = (_cursor, index);
    }
    notifyListeners();
  }

  /// The tap was released at [positionMs] after [held]. A hold stamps the
  /// end; either way the cursor moves on.
  void tapUp(int positionMs, {required Duration held}) {
    final holding = _holding;
    if (holding == null) return;
    _holding = null;
    final (index, wordIndex) = holding;
    final line = _lines[index];
    final isHold = held >= holdThreshold;
    if (wordIndex == null) {
      if (isHold && positionMs > (line.timeMs ?? 0)) {
        _replace(index, line.copyWith(endMs: () => positionMs));
      }
      _cursor = index + 1;
      _wordCursor = 0;
    } else {
      final word = line.words[wordIndex];
      final last = wordIndex == line.words.length - 1;
      if (isHold && positionMs > (word.timeMs ?? 0)) {
        _replace(
          index,
          line.copyWith(
            endMs: last ? () => positionMs : null,
            words: [...line.words]
              ..[wordIndex] = word.timed(word.timeMs, positionMs),
          ),
        );
      }
      if (last) {
        _cursor = index + 1;
        _wordCursor = 0;
      } else {
        _wordCursor = wordIndex + 1;
      }
    }
    notifyListeners();
  }

  /// Moves the target by [deltaMs]: one word when a word was stamped last,
  /// otherwise the whole line with its words.
  void nudge(int deltaMs) {
    final target = _target;
    if (target == null) return;
    final (index, wordIndex) = target;
    final line = _lines[index];
    if (line.timeMs == null) return;
    int? moved(int? ms) => ms == null ? null : (ms + deltaMs).clamp(0, 1 << 31);
    _remember();
    if (wordIndex == null) {
      _replace(
        index,
        line.copyWith(
          timeMs: () => moved(line.timeMs),
          endMs: () => moved(line.endMs),
          words: [
            for (final word in line.words)
              word.timed(moved(word.timeMs), moved(word.endMs)),
          ],
        ),
      );
    } else {
      final word = line.words[wordIndex];
      final last = wordIndex == line.words.length - 1;
      _replace(
        index,
        line.copyWith(
          timeMs: wordIndex == 0 ? () => moved(line.timeMs) : null,
          endMs: last ? () => moved(line.endMs) : null,
          words: [...line.words]
            ..[wordIndex] = word.timed(moved(word.timeMs), moved(word.endMs)),
        ),
      );
    }
    notifyListeners();
  }

  void undo() {
    if (_undo.isEmpty) return;
    final snapshot = _undo.removeLast();
    _lines = snapshot.lines;
    _cursor = snapshot.cursor;
    _wordCursor = snapshot.wordCursor;
    _target = snapshot.target;
    _holding = null;
    notifyListeners();
  }

  /// The draft as a timed document (offset 0). Lead lines never start before
  /// the lead line above them; a line keeps word timing only when every
  /// word was stamped. Call when [complete].
  LyricDocument build() {
    final lines = <LyricLine>[];
    var floor = 0;
    for (final draft in _lines) {
      var time = draft.timeMs ?? floor;
      if (!draft.source.isBacking) {
        if (time < floor) time = floor;
        floor = time;
      }
      final end = draft.endMs;
      lines.add(
        draft.source.copyWith(
          time: Duration(milliseconds: time),
          end: () =>
              end != null && end > time ? Duration(milliseconds: end) : null,
          words: draft.wordTimed
              ? [
                  for (final word in draft.words)
                    LyricWord(
                      text: draft.text.substring(word.start, word.end),
                      time: Duration(
                        milliseconds: word.timeMs! < time ? time : word.timeMs!,
                      ),
                      end: word.endMs == null
                          ? null
                          : Duration(milliseconds: word.endMs!),
                      start: word.start,
                    ),
                ]
              : const [],
        ),
      );
    }
    final wordTimed = lines.any((line) => line.words.isNotEmpty);
    return _doc.copyWith(
      lines: lines,
      timed: true,
      offsetMs: 0,
      format: wordTimed ? 'elrc' : 'lrc',
    );
  }
}
