import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:kalao/models/lyrics.dart';

/// One lyric line with readings (pinyin) above the characters they annotate
/// (IMPLEMENTATION.md §4 "Display"). The line is split into units: each ruby
/// segment is one unit (reading over its characters); unannotated text is
/// split at spaces so Latin words wrap normally. Every unit reserves the
/// reading row, so annotated and plain text share one baseline.
///
/// With [swept] the line is a karaoke sweep: the first `swept.value` UTF-16
/// units of the text are painted in [sweepColor], the boundary moving inside
/// a character as the value's fraction grows.
class RubyLyricLine extends StatelessWidget {
  const RubyLyricLine({
    super.key,
    required this.line,
    required this.style,
    this.layer,
    this.textAlign = TextAlign.center,
    this.swept,
    this.sweepColor,
  });

  final LyricLine line;
  final TextStyle style;

  /// The layer to show above the text, or null for plain text.
  final LyricLayerKind? layer;
  final TextAlign textAlign;

  /// How many UTF-16 units of the text have been sung, or null for no sweep.
  final ValueListenable<double>? swept;
  final Color? sweepColor;

  /// Units of [text] for [segments]: (base, reading?) pairs.
  @visibleForTesting
  static List<(String, String?)> units(
    String text,
    List<RubySegment> segments,
  ) {
    final out = <(String, String?)>[];
    void plain(String chunk) {
      // Keep each space with the word before it so wrapping happens at spaces.
      final words = RegExp(r'\S+\s*|\s+').allMatches(chunk);
      for (final word in words) {
        out.add((word.group(0)!, null));
      }
    }

    var cursor = 0;
    final sorted = [...segments]..sort((a, b) => a.start.compareTo(b.start));
    for (final segment in sorted) {
      if (segment.start < cursor || segment.end > text.length) continue;
      if (segment.start > cursor) plain(text.substring(cursor, segment.start));
      out.add((text.substring(segment.start, segment.end), segment.reading));
      cursor = segment.end;
    }
    if (cursor < text.length) plain(text.substring(cursor));
    return out;
  }

  Widget _text(String text, int offset, {bool wrap = true}) {
    final swept = this.swept;
    final color = sweepColor;
    if (swept == null || color == null) {
      return Text(
        text,
        style: style,
        textAlign: wrap ? textAlign : null,
        maxLines: wrap ? null : 1,
        softWrap: wrap,
      );
    }
    return SweepText(
      text: text,
      style: style,
      sweepColor: color,
      swept: swept,
      offset: offset,
      textAlign: wrap ? textAlign : TextAlign.start,
      wrap: wrap,
    );
  }

  @override
  Widget build(BuildContext context) {
    final segments = layer == null
        ? const <RubySegment>[]
        : line.layers[layer]?.segments ?? const <RubySegment>[];
    final text = line.display;
    if (segments.isEmpty) return _text(text, 0);
    final readingStyle = style.copyWith(
      fontSize: (style.fontSize ?? 20) * 0.5,
      fontWeight: FontWeight.w500,
      height: 1.1,
      color: style.color,
    );
    final readings = [
      for (final segment in segments) segment.reading,
    ].join(' ');
    final children = <Widget>[];
    var offset = 0;
    for (final (base, reading) in units(text, segments)) {
      children.add(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              reading ?? ' ',
              style: readingStyle,
              maxLines: 1,
              softWrap: false,
            ),
            _text(base, offset, wrap: false),
          ],
        ),
      );
      offset += base.length;
    }
    return Semantics(
      label: '$text, $readings',
      excludeSemantics: true,
      child: Wrap(
        alignment: switch (textAlign) {
          TextAlign.left || TextAlign.start => WrapAlignment.start,
          TextAlign.right || TextAlign.end => WrapAlignment.end,
          _ => WrapAlignment.center,
        },
        crossAxisAlignment: WrapCrossAlignment.end,
        children: children,
      ),
    );
  }
}

/// Text whose first characters are painted in [sweepColor]. [swept] counts
/// UTF-16 units of a longer string in which this text starts at [offset];
/// only the clip follows [swept], so a sweep repaints without rebuilding.
class SweepText extends StatelessWidget {
  const SweepText({
    super.key,
    required this.text,
    required this.style,
    required this.sweepColor,
    required this.swept,
    this.offset = 0,
    this.textAlign = TextAlign.center,
    this.wrap = true,
  });

  final String text;
  final TextStyle style;
  final Color sweepColor;
  final ValueListenable<double> swept;
  final int offset;
  final TextAlign textAlign;
  final bool wrap;

  @override
  Widget build(BuildContext context) {
    Widget layer(TextStyle style) => Text(
      text,
      style: style,
      textAlign: textAlign,
      maxLines: wrap ? null : 1,
      softWrap: wrap,
    );
    return Stack(
      children: [
        layer(style),
        Positioned.fill(
          child: ExcludeSemantics(
            child: ClipPath(
              clipper: _SweepClipper(
                text: text,
                style: DefaultTextStyle.of(context).style.merge(style),
                swept: swept,
                offset: offset,
                textAlign: textAlign,
                textDirection: Directionality.of(context),
                textScaler: MediaQuery.textScalerOf(context),
                wrap: wrap,
              ),
              child: layer(style.copyWith(color: sweepColor)),
            ),
          ),
        ),
      ],
    );
  }
}

/// Clips to the boxes of the sung characters, laid out exactly as the text
/// widgets above lay them out.
class _SweepClipper extends CustomClipper<Path> {
  _SweepClipper({
    required this.text,
    required this.style,
    required this.swept,
    required this.offset,
    required this.textAlign,
    required this.textDirection,
    required this.textScaler,
    required this.wrap,
  }) : super(reclip: swept);

  final String text;
  final TextStyle style;
  final ValueListenable<double> swept;
  final int offset;
  final TextAlign textAlign;
  final TextDirection textDirection;
  final TextScaler textScaler;
  final bool wrap;

  TextPainter? _painter;
  double? _width;

  TextPainter _layout(double width) {
    final cached = _painter;
    if (cached != null && _width == width) return cached;
    _painter?.dispose();
    _width = width;
    return _painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textAlign: textAlign,
      textDirection: textDirection,
      textScaler: textScaler,
      maxLines: wrap ? null : 1,
    )..layout(minWidth: width, maxWidth: wrap ? width : double.infinity);
  }

  @override
  Path getClip(Size size) {
    final path = Path();
    final chars = (swept.value - offset).clamp(0.0, text.length.toDouble());
    if (chars <= 0) return path;
    final painter = _layout(size.width);
    final whole = chars.floor();
    for (final box in painter.getBoxesForSelection(
      TextSelection(baseOffset: 0, extentOffset: whole),
    )) {
      path.addRect(box.toRect());
    }
    final fraction = chars - whole;
    if (fraction > 0 && whole < text.length) {
      final boxes = painter.getBoxesForSelection(
        TextSelection(baseOffset: whole, extentOffset: whole + 1),
      );
      if (boxes.isNotEmpty) {
        final rect = boxes.first.toRect();
        path.addRect(
          boxes.first.direction == TextDirection.rtl
              ? Rect.fromLTRB(
                  rect.right - rect.width * fraction,
                  rect.top,
                  rect.right,
                  rect.bottom,
                )
              : Rect.fromLTRB(
                  rect.left,
                  rect.top,
                  rect.left + rect.width * fraction,
                  rect.bottom,
                ),
        );
      }
    }
    return path;
  }

  @override
  bool shouldReclip(_SweepClipper old) =>
      old.text != text ||
      old.style != style ||
      old.swept != swept ||
      old.offset != offset ||
      old.textAlign != textAlign ||
      old.textDirection != textDirection ||
      old.textScaler != textScaler ||
      old.wrap != wrap;
}
