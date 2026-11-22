// A paged Library list with Mornye's fast scroller (`library_fast_scroller
// .dart`): a draggable thumb whose bubble names the section under it (a
// letter, a year or a month), over pages read on demand.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:kalao/models/song.dart';
import 'package:kalao/providers/library_browse_provider.dart';
import 'package:kalao/services/library_browse.dart';
import 'package:kalao/theme/app_tokens.dart';
import 'package:kalao/widgets/song_widgets.dart';

/// List rows have a fixed height, so the scroller maps offsets to rows.
const _rowExtent = 72.0;

/// The songs of [query], read [libraryPageSize] at a time.
class PagedSongList extends ConsumerStatefulWidget {
  const PagedSongList({
    super.key,
    required this.query,
    this.grid = false,
    this.selected = const {},
    this.onTap,
    this.onLongPress,
    this.header,
  });

  final SongQuery query;
  final bool grid;
  final Set<int> selected;
  final void Function(Song song)? onTap;
  final void Function(Song song)? onLongPress;

  /// Shown above the songs (an album's actions).
  final Widget? header;

  @override
  ConsumerState<PagedSongList> createState() => _PagedSongListState();
}

class _PagedSongListState extends ConsumerState<PagedSongList> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Song? _songAt(int index) => ref
      .read(
        songPageProvider((query: widget.query, page: index ~/ libraryPageSize)),
      )
      .asData
      ?.value
      .elementAtOrNull(index % libraryPageSize);

  /// The bubble's text for row [index] under the current sort.
  String? _label(int index) {
    final song = _songAt(index);
    if (song == null) return null;
    String initial(String text) =>
        text.trim().isEmpty ? '#' : text.trim().characters.first.toUpperCase();
    return switch (widget.query.sort) {
      LibrarySort.title => initial(song.title),
      LibrarySort.artist => initial(song.artist),
      LibrarySort.album => initial(song.album),
      LibrarySort.genre => song.genre ?? '#',
      LibrarySort.year => song.year?.toString() ?? '#',
      LibrarySort.latest || LibrarySort.oldest => DateFormat.yMMM(
        Localizations.localeOf(context).toLanguageTag(),
      ).format(song.addedAt),
      LibrarySort.size => null,
    };
  }

  Widget _item(int index) {
    final page = ref.watch(
      songPageProvider((query: widget.query, page: index ~/ libraryPageSize)),
    );
    final song = page.asData?.value.elementAtOrNull(index % libraryPageSize);
    if (song == null) {
      return widget.grid
          ? const SizedBox.shrink()
          : const SizedBox(height: _rowExtent);
    }
    if (widget.grid) {
      return LayoutBuilder(
        builder: (context, constraints) => SongCard(
          song: song,
          width: constraints.maxWidth - AppTokens.space8,
          selected: widget.selected.contains(song.id),
          onTap: () => widget.onTap?.call(song),
          onLongPress: () => widget.onLongPress?.call(song),
        ),
      );
    }
    return SongListTile(
      song: song,
      selectionMode: widget.selected.isNotEmpty,
      selected: widget.selected.contains(song.id),
      onTap: () => widget.onTap?.call(song),
      onLongPress: () => widget.onLongPress?.call(song),
    );
  }

  @override
  Widget build(BuildContext context) {
    final count = ref.watch(songCountProvider(widget.query)).asData?.value;
    if (count == null) return const Center(child: CircularProgressIndicator());
    final header = widget.header;
    final slivers = <Widget>[
      if (header != null) SliverToBoxAdapter(child: header),
      if (widget.grid)
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            AppTokens.space12,
            AppTokens.space8,
            AppTokens.space12,
            96,
          ),
          sliver: SliverGrid.builder(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 180,
              childAspectRatio: 0.72,
            ),
            itemCount: count,
            itemBuilder: (context, index) => _item(index),
          ),
        )
      else ...[
        SliverFixedExtentList.builder(
          itemExtent: _rowExtent,
          itemCount: count,
          itemBuilder: (context, index) => _item(index),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 96)),
      ],
    ];
    return LibraryFastScroller(
      controller: _scroll,
      itemCount: count,
      labelAt: widget.grid ? (_) => null : _label,
      child: CustomScrollView(controller: _scroll, slivers: slivers),
    );
  }
}

/// A thumb on the right edge of a long list: dragging it jumps through the
/// list and a bubble names the section under it.
class LibraryFastScroller extends StatefulWidget {
  const LibraryFastScroller({
    super.key,
    required this.controller,
    required this.itemCount,
    required this.labelAt,
    required this.child,
  });

  final ScrollController controller;
  final int itemCount;
  final String? Function(int index) labelAt;
  final Widget child;

  /// Shorter lists scroll fine without it.
  static const minItems = 50;

  @override
  State<LibraryFastScroller> createState() => _LibraryFastScrollerState();
}

class _LibraryFastScrollerState extends State<LibraryFastScroller> {
  double _fraction = 0;
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onScroll);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() {
    if (_dragging || !widget.controller.hasClients) return;
    final position = widget.controller.position;
    final max = position.maxScrollExtent;
    setState(() => _fraction = max <= 0 ? 0 : position.pixels / max);
  }

  void _drag(double dy, double height) {
    if (!widget.controller.hasClients) return;
    final fraction = (dy / height).clamp(0.0, 1.0);
    final position = widget.controller.position;
    widget.controller.jumpTo(fraction * position.maxScrollExtent);
    setState(() => _fraction = fraction);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.itemCount < LibraryFastScroller.minItems) return widget.child;
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        const thumb = 48.0;
        final height = constraints.maxHeight;
        final top = (_fraction * (height - thumb)).clamp(0.0, height - thumb);
        final label = _dragging
            ? widget.labelAt((_fraction * (widget.itemCount - 1)).round())
            : null;
        return Stack(
          children: [
            widget.child,
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              width: 28,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onVerticalDragStart: (details) {
                  setState(() => _dragging = true);
                  _drag(details.localPosition.dy, height);
                },
                onVerticalDragUpdate: (details) =>
                    _drag(details.localPosition.dy, height),
                onVerticalDragEnd: (_) => setState(() => _dragging = false),
                child: Stack(
                  children: [
                    Positioned(
                      right: 4,
                      top: top,
                      child: Container(
                        width: 6,
                        height: thumb,
                        decoration: BoxDecoration(
                          color: _dragging
                              ? scheme.primary
                              : scheme.onSurfaceVariant.withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (label != null)
              Positioned(
                right: 40,
                top: top,
                child: IgnorePointer(
                  child: Material(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(AppTokens.radiusMedium),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppTokens.space16,
                        vertical: AppTokens.space8,
                      ),
                      child: Text(
                        label,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: scheme.onPrimaryContainer,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
