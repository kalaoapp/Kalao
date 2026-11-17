import 'package:kalao/models/lyrics.dart';
import 'package:kalao/models/settings.dart';
import 'package:kalao/services/library_database.dart';
import 'package:kalao/services/platform_bridge.dart';

class LyricsException implements Exception {
  const LyricsException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Lyric documents in and out of the library: import (parse, annotate,
/// store), edited versions, the per-song offset and LRC export.
class LyricsService {
  LyricsService(this.library);

  final LibraryDatabase library;

  /// Parses [raw] (LRC, enhanced LRC, TTML or plain text; [format] null to
  /// detect), generates pinyin for Chinese lines and saves a new version.
  Future<LyricDocument> importText(
    int songId,
    String raw, {
    String? format,
    String source = 'paste',
  }) async {
    final doc = LyricDocument.fromJson(
      await PlatformBridge.parseLyrics(raw, format: format),
    );
    if (doc.isEmpty) throw const LyricsException('No lyric lines found');
    return save(songId, await _annotated(doc), source: source);
  }

  /// Saves [doc] as a new version. Layers already on its lines are kept
  /// (an edit of the timing does not change the text they annotate).
  Future<LyricDocument> save(
    int songId,
    LyricDocument doc, {
    required String source,
  }) async {
    await library.saveLyrics(
      songId,
      doc,
      sourceKind: source,
      layers: {
        for (final (index, line) in doc.lines.indexed)
          if (line.layers.isNotEmpty) index: line.layers,
      },
    );
    return doc;
  }

  /// Reading layers by language: kana means Japanese (furigana and romaji),
  /// otherwise Han characters get pinyin.
  Future<LyricDocument> _annotated(LyricDocument doc) async {
    final japanese = doc.hasKana;
    if (!japanese && !doc.hasHan) return doc;
    final lines = [...doc.lines];
    final annotated = await PlatformBridge.annotateLyrics([
      for (final line in lines) line.text,
    ], layers: japanese ? const ['furigana', 'romaji'] : const ['pinyin']);
    for (final entry in annotated) {
      final kind = LyricLayerKind.values.asNameMap()[entry['kind']];
      final index = (entry['lineIndex'] as num).toInt();
      if (kind == null || index >= lines.length) continue;
      lines[index] = lines[index].withLayer(
        kind,
        LyricLayer(
          segments: [
            for (final segment in entry['segments'] as List)
              RubySegment.fromJson((segment as Map).cast<String, dynamic>()),
          ],
        ),
      );
    }
    return doc.copyWith(lines: lines, sourceLang: () => japanese ? 'ja' : 'zh');
  }

  /// [doc] with each Chinese line's text in [variant] for display. Lines
  /// whose conversion changes the length keep their own text, so readings
  /// stay aligned. Japanese and other lyrics are returned unchanged.
  Future<LyricDocument> withVariant(
    LyricDocument doc,
    ChineseVariant variant,
  ) async {
    final to = variant.conversion;
    if (to == null || doc.sourceLang != 'zh') {
      return doc.lines.any((line) => line.variantText != null)
          ? doc.withLines([
              for (final line in doc.lines)
                line.copyWith(variantText: () => null),
            ])
          : doc;
    }
    final converted = await PlatformBridge.convertChinese([
      for (final line in doc.lines) line.text,
    ], to);
    return doc.withLines([
      for (final (index, line) in doc.lines.indexed)
        line.copyWith(
          variantText: () =>
              index < converted.length &&
                  converted[index] != line.text &&
                  converted[index].length == line.text.length
              ? converted[index]
              : null,
        ),
    ]);
  }

  /// The per-song offset of the current version, clamped to ±5 s.
  Future<int> setOffset(int songId, int offsetMs) async {
    final clamped = offsetMs.clamp(
      -LyricDocument.maxOffsetMs,
      LyricDocument.maxOffsetMs,
    );
    await library.setLyricsOffset(songId, clamped);
    return clamped;
  }

  /// [doc] as LRC (`lrc`, line timing) or enhanced LRC (`elrc`, word timing,
  /// sections and voices), with [title] and [artist] tags.
  Future<String> exportText(
    LyricDocument doc,
    String format, {
    String? title,
    String? artist,
  }) => PlatformBridge.exportLyrics({
    ...doc.toJson(),
    'title': ?title,
    'artist': ?artist,
  }, format);
}
