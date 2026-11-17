import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:kalao/models/lyrics.dart';
import 'package:kalao/providers/library_provider.dart';
import 'package:kalao/services/history_database.dart';
import 'package:kalao/services/library_search.dart';

/// What a POC import changed (FEATURES 7.6).
@immutable
class PocImportResult {
  const PocImportResult({
    required this.matched,
    required this.lyrics,
    required this.favorites,
    required this.plays,
    required this.unmatched,
  });

  final int matched;
  final int lyrics;
  final int favorites;
  final int plays;

  /// "Title · Artist" of POC songs with no library song to attach to.
  final List<String> unmatched;
}

class PocImportException implements Exception {
  const PocImportException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// One-off import of a `kalao-poc.json` export from the old web POC
/// (IMPLEMENTATION.md §12). The POC's audio never moves (it was not the
/// user's to share), so its songs are matched to songs already imported here
/// by title and artist, and gain the POC's lyrics, translations, furigana,
/// favorites and plays. POC furigana and translations are hand-made, so they
/// are kept as `human`.
class PocImportService {
  PocImportService(this.services);

  final LibraryServices services;

  static String _key(String title, String artist) =>
      '${normalizeSearchText(title)}|${normalizeSearchText(artist)}';

  Future<PocImportResult> importJson(String text) async {
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      throw const PocImportException('This is not a Kalao POC export');
    }
    if (json is! Map ||
        json['format'] != 'kalao-poc' ||
        json['version'] != 1 ||
        json['songs'] is! List) {
      throw const PocImportException('This is not a Kalao POC export');
    }

    final library = services.library;
    final byKey = <String, ({int id, String songKey})>{};
    for (final song in await library.songs()) {
      byKey.putIfAbsent(
        _key(song.title, song.artist),
        () => (id: song.id, songKey: song.songKey),
      );
    }

    var matched = 0, lyrics = 0, favorites = 0, plays = 0;
    final unmatched = <String>[];
    for (final raw in json['songs'] as List) {
      if (raw is! Map) continue;
      final title = raw['title'] as String? ?? '';
      final artist = raw['artist'] as String? ?? '';
      final target = byKey[_key(title, artist)];
      if (target == null) {
        unmatched.add(artist.isEmpty ? title : '$title · $artist');
        continue;
      }
      matched++;

      final doc = _document(raw['lines']);
      if (doc != null) {
        await services.lyrics.save(
          target.id,
          await _withPocLayers(doc, raw['lines'] as List<Object?>),
          source: 'poc',
        );
        lyrics++;
      }
      if (raw['favorite'] == true) {
        await library.setFavorite(target.id, true);
        favorites++;
      }
      plays += await _importPlays(target, raw['plays']);
    }
    return PocImportResult(
      matched: matched,
      lyrics: lyrics,
      favorites: favorites,
      plays: plays,
      unmatched: unmatched,
    );
  }

  /// `{text, translation?, sectionBreak?}` lines → a plain (untimed) document.
  static LyricDocument? _document(Object? lines) {
    if (lines is! List) return null;
    final result = <LyricLine>[];
    for (final line in lines) {
      if (line is! Map) continue;
      final text = (line['text'] as String? ?? '').trim();
      if (text.isEmpty) continue;
      final translation = (line['translation'] as String? ?? '').trim();
      result.add(
        LyricLine(
          text: text,
          translation: translation.isEmpty || translation == text
              ? null
              : translation,
          sectionBreakBefore: line['sectionBreak'] == true,
        ),
      );
    }
    return result.isEmpty ? null : LyricDocument(lines: result);
  }

  /// Generated readings, with the POC's hand-typed furigana (a reading of the
  /// whole line) in place of the generated one where it has some.
  Future<LyricDocument> _withPocLayers(
    LyricDocument doc,
    List<Object?> raw,
  ) async {
    final annotated = await services.lyrics.annotate(doc);
    final furigana = [
      for (final line in raw)
        if (line is Map && (line['text'] as String? ?? '').trim().isNotEmpty)
          (line['furigana'] as String? ?? '').trim(),
    ];
    return annotated.withLines([
      for (final (index, line) in annotated.lines.indexed)
        if (index < furigana.length && furigana[index].isNotEmpty)
          line.withLayer(
            LyricLayerKind.furigana,
            LyricLayer(
              segments: [RubySegment(0, line.text.length, furigana[index])],
              origin: LayerOrigin.human,
            ),
          )
        else
          line,
    ]);
  }

  /// Plays `{at, track}`; one already in the history is not added again.
  Future<int> _importPlays(
    ({int id, String songKey}) song,
    Object? plays,
  ) async {
    if (plays is! List) return 0;
    final db = services.history.db;
    var added = 0;
    for (final play in plays) {
      final at = play is Map
          ? DateTime.tryParse(play['at'] as String? ?? '')
          : null;
      if (at == null) continue;
      final existing = await db.query(
        'play',
        where: 'started_at = ? AND song_key = ?',
        whereArgs: [at.millisecondsSinceEpoch, song.songKey],
      );
      if (existing.isNotEmpty) continue;
      await services.history.startPlay(
        songId: song.id,
        songKey: song.songKey,
        mode: (play as Map)['track'] == 'instrumental'
            ? PlayMode.karaoke
            : PlayMode.listen,
        now: at,
      );
      added++;
    }
    return added;
  }
}
