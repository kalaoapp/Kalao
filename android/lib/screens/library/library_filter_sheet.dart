import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kalao/l10n/app_localizations.dart';
import 'package:kalao/providers/library_browse_provider.dart';
import 'package:kalao/services/library_browse.dart';
import 'package:kalao/theme/app_tokens.dart';

/// The Library's filters (FEATURES 6.11), adapted from Mornye's filter
/// sheet for karaoke: where a song came from, its format, how its lyrics are
/// timed, whether it has an instrumental, and what it is missing.
Future<SongQuery?> showLibraryFilters(BuildContext context, SongQuery query) =>
    showModalBottomSheet<SongQuery>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => _FilterSheet(initial: query),
    );

class _FilterSheet extends ConsumerStatefulWidget {
  const _FilterSheet({required this.initial});

  final SongQuery initial;

  @override
  ConsumerState<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends ConsumerState<_FilterSheet> {
  late SongQuery _query = widget.initial;

  Widget _section(String title, List<Widget> chips) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppTokens.space16,
      AppTokens.space12,
      AppTokens.space16,
      0,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: AppTokens.space8),
        Wrap(
          spacing: AppTokens.space8,
          runSpacing: AppTokens.space4,
          children: chips,
        ),
      ],
    ),
  );

  Widget _choice<T>(
    String label,
    T? value,
    T? current,
    void Function(T?) set,
  ) => ChoiceChip(
    label: Text(label),
    selected: value == current,
    onSelected: (_) => setState(() => set(value)),
  );

  Widget _toggle(String label, bool on, void Function(bool) set) => FilterChip(
    label: Text(label),
    selected: on,
    onSelected: (value) => setState(() => set(value)),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final codecs = ref.watch(libraryCodecsProvider).asData?.value ?? const [];
    final q = _query;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      builder: (context, controller) => Column(
        children: [
          Expanded(
            child: ListView(
              controller: controller,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppTokens.space16,
                  ),
                  child: Text(
                    l10n.libraryFilters,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                _section(l10n.filterOrigin, [
                  _choice<SongOrigin>(
                    l10n.filterAny,
                    null,
                    q.origin,
                    (v) => _query = q.copyWith(origin: () => v),
                  ),
                  for (final (origin, label) in [
                    (SongOrigin.imported, l10n.originImported),
                    (SongOrigin.folder, l10n.originFolder),
                    (SongOrigin.extension, l10n.originExtension),
                  ])
                    _choice<SongOrigin>(
                      label,
                      origin,
                      q.origin,
                      (v) => _query = q.copyWith(origin: () => v),
                    ),
                ]),
                if (codecs.isNotEmpty)
                  _section(l10n.filterFormat, [
                    _choice<String>(
                      l10n.filterAny,
                      null,
                      q.codec,
                      (v) => _query = q.copyWith(codec: () => v),
                    ),
                    for (final codec in codecs)
                      _choice<String>(
                        codec.toUpperCase(),
                        codec,
                        q.codec,
                        (v) => _query = q.copyWith(codec: () => v),
                      ),
                  ]),
                _section(l10n.filterLyrics, [
                  _choice<LyricsFilter>(
                    l10n.filterAny,
                    null,
                    q.lyrics,
                    (v) => _query = q.copyWith(lyrics: () => v),
                  ),
                  for (final (value, label) in [
                    (LyricsFilter.none, l10n.lyricsFilterNone),
                    (LyricsFilter.plain, l10n.lyricsFilterPlain),
                    (LyricsFilter.lines, l10n.lyricsFilterLines),
                    (LyricsFilter.words, l10n.lyricsFilterWords),
                  ])
                    _choice<LyricsFilter>(
                      label,
                      value,
                      q.lyrics,
                      (v) => _query = q.copyWith(lyrics: () => v),
                    ),
                ]),
                _section(l10n.filterInstrumental, [
                  _choice<bool>(
                    l10n.filterAny,
                    null,
                    q.hasInstrumental,
                    (v) => _query = q.copyWith(hasInstrumental: () => v),
                  ),
                  _choice<bool>(
                    l10n.instrumentalYes,
                    true,
                    q.hasInstrumental,
                    (v) => _query = q.copyWith(hasInstrumental: () => v),
                  ),
                  _choice<bool>(
                    l10n.instrumentalNo,
                    false,
                    q.hasInstrumental,
                    (v) => _query = q.copyWith(hasInstrumental: () => v),
                  ),
                ]),
                _section(l10n.filterMore, [
                  _toggle(
                    l10n.libraryFavoritesOnly,
                    q.favoritesOnly,
                    (v) => _query = q.copyWith(favoritesOnly: v),
                  ),
                  _toggle(
                    l10n.filterUnavailable,
                    q.unavailableOnly,
                    (v) => _query = q.copyWith(unavailableOnly: v),
                  ),
                  _toggle(
                    l10n.filterMissingArtwork,
                    q.missingArtwork,
                    (v) => _query = q.copyWith(missingArtwork: v),
                  ),
                  _toggle(
                    l10n.filterMissingGenre,
                    q.missingGenre,
                    (v) => _query = q.copyWith(missingGenre: v),
                  ),
                  _toggle(
                    l10n.filterMissingYear,
                    q.missingYear,
                    (v) => _query = q.copyWith(missingYear: v),
                  ),
                ]),
                const SizedBox(height: AppTokens.space16),
              ],
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(AppTokens.space16),
              child: Row(
                children: [
                  TextButton(
                    onPressed: () => setState(() => _query = q.cleared()),
                    child: Text(l10n.filterReset),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, _query),
                    child: Text(l10n.filterApply),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
