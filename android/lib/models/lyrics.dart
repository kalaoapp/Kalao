import 'package:flutter/foundation.dart';

/// Reading layers over lyric text (DATA_MODEL.md §1).
/// The Chinese variant is applied for display, not stored as a layer
/// (`LyricLine.variantText`).
enum LyricLayerKind { pinyin, furigana, romaji }

/// Who produced a layer. `human` layers are never regenerated.
enum LayerOrigin { auto, human, translator }

/// The voice of a backing-vocal line.
const backingVoice = 'bg';

/// A reading over the UTF-16 range [start, end) of a line's text.
@immutable
class RubySegment {
  const RubySegment(this.start, this.end, this.reading);

  factory RubySegment.fromJson(Map<String, dynamic> json) => RubySegment(
    (json['start'] as num).toInt(),
    (json['end'] as num).toInt(),
    json['reading'] as String? ?? '',
  );

  final int start;
  final int end;
  final String reading;

  Map<String, dynamic> toJson() => {
    'start': start,
    'end': end,
    'reading': reading,
  };

  @override
  bool operator ==(Object other) =>
      other is RubySegment &&
      other.start == start &&
      other.end == end &&
      other.reading == reading;

  @override
  int get hashCode => Object.hash(start, end, reading);
}

@immutable
class LyricLayer {
  const LyricLayer({required this.segments, this.origin = LayerOrigin.auto});

  final List<RubySegment> segments;
  final LayerOrigin origin;
}

/// One timed word: sung from [time] to [end], covering the UTF-16 range
/// [start, start + text.length) of its line's text.
@immutable
class LyricWord {
  const LyricWord({
    required this.text,
    required this.time,
    this.end,
    this.start = 0,
  });

  final String text;
  final Duration time;
  final Duration? end;
  final int start;

  Map<String, dynamic> toJson() => {
    'timeMs': time.inMilliseconds,
    if (end != null) 'endMs': end!.inMilliseconds,
    'text': text,
    'start': start,
  };

  @override
  bool operator ==(Object other) =>
      other is LyricWord &&
      other.text == text &&
      other.time == time &&
      other.end == end &&
      other.start == start;

  @override
  int get hashCode => Object.hash(text, time, end, start);
}

/// One lyric line. `time` is zero for every line of an untimed document.
@immutable
class LyricLine {
  const LyricLine({
    required this.text,
    this.time = Duration.zero,
    this.end,
    this.words = const [],
    this.voice,
    this.translation,
    this.section,
    this.sectionBreakBefore = false,
    this.layers = const {},
    this.variantText,
  });

  factory LyricLine.fromJson(Map<String, dynamic> json) {
    final text = json['text'] as String? ?? '';
    // `parseLyrics` gives each word's offset. Documents saved before it did
    // find the words in the text in order; one that is not there is dropped.
    final words = <LyricWord>[];
    var cursor = 0;
    for (final item in json['words'] as List<dynamic>? ?? const []) {
      final word = (item as Map).cast<String, dynamic>();
      final wordText = word['text'] as String? ?? '';
      final given = (word['start'] as num?)?.toInt();
      final start = wordText.isEmpty
          ? -1
          : given != null && text.startsWith(wordText, given)
          ? given
          : text.indexOf(wordText, cursor);
      if (start < 0) continue;
      cursor = start + wordText.length;
      words.add(
        LyricWord(
          text: wordText,
          time: Duration(milliseconds: (word['timeMs'] as num?)?.toInt() ?? 0),
          end: word['endMs'] == null
              ? null
              : Duration(milliseconds: (word['endMs'] as num).toInt()),
          start: start,
        ),
      );
    }
    return LyricLine(
      text: text,
      time: Duration(milliseconds: (json['timeMs'] as num?)?.toInt() ?? 0),
      end: json['endMs'] == null
          ? null
          : Duration(milliseconds: (json['endMs'] as num).toInt()),
      words: words,
      voice: json['voice'] as String?,
      translation: json['translation'] as String?,
      section: json['section'] as String?,
      sectionBreakBefore: json['sectionBreakBefore'] as bool? ?? false,
    );
  }

  final String text;
  final Duration time;
  final Duration? end;

  /// Word timing in text order; empty for a line-timed line.
  final List<LyricWord> words;

  /// `v1`, `v2`, … in a duet, [backingVoice] for backing vocals, or null.
  final String? voice;
  final String? translation;

  /// `verse`, `chorus`, `preChorus`, `bridge`, `intro`, `outro`, … or null.
  final String? section;
  final bool sectionBreakBefore;
  final Map<LyricLayerKind, LyricLayer> layers;

  /// [text] in the Chinese variant chosen in settings (same length, so
  /// readings and word ranges still apply), or null. Display only: it is
  /// never stored.
  final String? variantText;

  /// What to show for this line.
  String get display => variantText ?? text;

  bool get isBacking => voice == backingVoice;

  LyricLine copyWith({
    Duration? time,
    Duration? Function()? end,
    List<LyricWord>? words,
    Map<LyricLayerKind, LyricLayer>? layers,
    String? Function()? variantText,
  }) => LyricLine(
    text: text,
    time: time ?? this.time,
    end: end != null ? end() : this.end,
    words: words ?? this.words,
    voice: voice,
    translation: translation,
    section: section,
    sectionBreakBefore: sectionBreakBefore,
    layers: layers ?? this.layers,
    variantText: variantText != null ? variantText() : this.variantText,
  );

  LyricLine withLayer(LyricLayerKind kind, LyricLayer layer) =>
      copyWith(layers: {...layers, kind: layer});

  Map<String, dynamic> toJson() => {
    'timeMs': time.inMilliseconds,
    if (end != null) 'endMs': end!.inMilliseconds,
    'text': text,
    if (words.isNotEmpty) 'words': [for (final word in words) word.toJson()],
    if (voice != null) 'voice': voice,
    if (translation != null) 'translation': translation,
    if (section != null) 'section': section,
    'sectionBreakBefore': sectionBreakBefore,
  };
}

/// A lyric document: text and timing. Layers are stored separately
/// (`lyric_annotation`) and merged into [lines] when loaded.
@immutable
class LyricDocument {
  const LyricDocument({
    required this.lines,
    this.timed = false,
    this.offsetMs = 0,
    this.format = 'plain',
    this.sourceLang,
  });

  factory LyricDocument.fromJson(Map<String, dynamic> json) => LyricDocument(
    lines: [
      for (final line in json['lines'] as List<dynamic>? ?? const [])
        LyricLine.fromJson((line as Map).cast<String, dynamic>()),
    ],
    timed: json['timed'] as bool? ?? false,
    offsetMs: (json['offsetMs'] as num?)?.toInt() ?? 0,
    format: json['format'] as String? ?? 'plain',
    sourceLang: json['sourceLang'] as String?,
  );

  /// The per-song offset range and step (IMPLEMENTATION.md §4).
  static const maxOffsetMs = 5000;
  static const offsetStepMs = 50;

  final List<LyricLine> lines;
  final bool timed;

  /// Added to the playback position before looking up the line: positive
  /// values show lyrics earlier (as LRC's `[offset:]`).
  final int offsetMs;

  /// `plain`, `lrc`, `elrc` (word-timed) or `ttml`.
  final String format;
  final String? sourceLang;

  bool get isEmpty => lines.isEmpty;

  bool get hasWordTiming => lines.any((line) => line.words.isNotEmpty);

  Map<String, dynamic> toJson() => {
    'version': 2,
    'format': format,
    'timed': timed,
    'offsetMs': offsetMs,
    if (sourceLang != null) 'sourceLang': sourceLang,
    'lines': [for (final line in lines) line.toJson()],
  };

  LyricDocument copyWith({
    List<LyricLine>? lines,
    bool? timed,
    int? offsetMs,
    String? format,
    String? Function()? sourceLang,
  }) => LyricDocument(
    lines: lines ?? this.lines,
    timed: timed ?? this.timed,
    offsetMs: offsetMs ?? this.offsetMs,
    format: format ?? this.format,
    sourceLang: sourceLang != null ? sourceLang() : this.sourceLang,
  );

  LyricDocument withLines(List<LyricLine> next) => copyWith(lines: next);

  /// The lead line playing at [position] for a timed document (binary search
  /// over start times, with the per-song offset), or null before the first
  /// line. Backing lines follow their lead line and are never the answer.
  int? activeLineAt(Duration position) {
    if (!timed || lines.isEmpty) return null;
    final ms = position.inMilliseconds + offsetMs;
    var low = 0;
    var high = lines.length - 1;
    var found = -1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      if (lines[mid].time.inMilliseconds <= ms) {
        found = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    while (found >= 0 && lines[found].isBacking) {
      found--;
    }
    return found < 0 ? null : found;
  }
}
