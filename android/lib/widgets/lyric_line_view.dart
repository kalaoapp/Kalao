import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:kalao/models/lyrics.dart';
import 'package:kalao/models/settings.dart';
import 'package:kalao/widgets/ruby_lyric_line.dart';

/// The reading layer shown above [line] under [settings]: furigana for
/// Japanese lines, pinyin for Chinese ones, or null.
LyricLayerKind? rubyLayerFor(LyricLine line, AppSettings settings) {
  if (settings.showFurigana &&
      line.layers.containsKey(LyricLayerKind.furigana)) {
    return LyricLayerKind.furigana;
  }
  if (settings.showPinyin && line.layers.containsKey(LyricLayerKind.pinyin)) {
    return LyricLayerKind.pinyin;
  }
  return null;
}

/// A line's romaji as one string (one word per token), or null.
String? romajiOf(LyricLine line) {
  final segments = line.layers[LyricLayerKind.romaji]?.segments;
  if (segments == null || segments.isEmpty) return null;
  return [for (final segment in segments) segment.reading].join(' ');
}

/// One lyric line as displayed (IMPLEMENTATION.md §4 "Display"): the reading
/// above the text, romaji below, then the translation. Shared by the
/// scrolling Learn view and the Karaoke view.
class LyricLineView extends StatelessWidget {
  const LyricLineView({
    super.key,
    required this.line,
    required this.style,
    required this.settings,
    this.textAlign = TextAlign.center,
    this.swept,
    this.sweepColor,
  });

  final LyricLine line;
  final TextStyle style;
  final AppSettings settings;
  final TextAlign textAlign;

  /// Sung UTF-16 units of the line for the karaoke sweep, or null.
  final ValueListenable<double>? swept;
  final Color? sweepColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontSize: (style.fontSize ?? 20) * 0.55,
    );
    final romaji = settings.showRomaji ? romajiOf(line) : null;
    final translation = settings.showTranslation ? line.translation : null;
    final ruby = RubyLyricLine(
      line: line,
      style: style,
      layer: rubyLayerFor(line, settings),
      textAlign: textAlign,
      swept: swept,
      sweepColor: sweepColor,
    );
    if (romaji == null && translation == null) return ruby;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: switch (textAlign) {
        TextAlign.start || TextAlign.left => CrossAxisAlignment.start,
        TextAlign.end || TextAlign.right => CrossAxisAlignment.end,
        _ => CrossAxisAlignment.center,
      },
      children: [
        ruby,
        if (romaji != null) Text(romaji, style: small, textAlign: textAlign),
        if (translation != null)
          Text(translation, style: small, textAlign: textAlign),
      ],
    );
  }
}
