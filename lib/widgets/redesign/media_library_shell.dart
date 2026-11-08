import 'package:flutter/material.dart';

enum LibrarySection { home, movies, series }

/// Presentation-only: parent owns catalog, filtering, search and persistence.
class MediaLibraryShell extends StatelessWidget {
  const MediaLibraryShell({
    super.key,
    required this.section,
    required this.onSectionChanged,
    required this.searchController,
    this.searchFocusNode,
    required this.onSearchChanged,
    required this.libraryName,
    required this.onChooseLibrary,
    required this.summary,
    required this.genreLabel,
    required this.onChooseGenre,
    required this.sortLabel,
    required this.onChooseSort,
    required this.filtersOpen,
    required this.onToggleFilters,
    required this.onCloseFilters,
    required this.filters,
    required this.content,
    this.collections = const [],
    this.alphabetRail,
    this.onBack,
    this.onVoiceSearch,
    this.appBarActions = const [],
    this.embedInScaffold = true,
  });
  final LibrarySection section;
  final ValueChanged<LibrarySection> onSectionChanged;
  final TextEditingController searchController;
  final FocusNode? searchFocusNode;
  final ValueChanged<String> onSearchChanged;
  final String libraryName, summary, genreLabel, sortLabel;
  final VoidCallback onChooseLibrary, onChooseGenre, onChooseSort;
  final bool filtersOpen;
  final VoidCallback onToggleFilters, onCloseFilters;
  final Widget filters, content;
  final List<Widget> collections;
  final Widget? alphabetRail;
  final VoidCallback? onBack, onVoiceSearch;
  final List<Widget> appBarActions;
  final bool embedInScaffold;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = switch (section) {
      LibrarySection.home => 'Your library',
      LibrarySection.movies => 'Browse movies',
      LibrarySection.series => 'Browse series',
    };
    final body = LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth >= 1100;
        final header = Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: searchController,
                onChanged: onSearchChanged,
                focusNode: searchFocusNode,
                decoration: InputDecoration(
                  hintText: section == LibrarySection.series
                      ? 'Search series'
                      : 'Search movies and shows',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: onVoiceSearch == null
                      ? null
                      : IconButton(
                          tooltip: 'Voice search',
                          onPressed: onVoiceSearch,
                          icon: const Icon(Icons.mic_none),
                        ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 16,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        SegmentedButton<LibrarySection>(
                          segments: const [
                            ButtonSegment(
                              value: LibrarySection.home,
                              label: Text('Home'),
                            ),
                            ButtonSegment(
                              value: LibrarySection.movies,
                              label: Text('Movies'),
                            ),
                            ButtonSegment(
                              value: LibrarySection.series,
                              label: Text('Series'),
                            ),
                          ],
                          selected: {section},
                          showSelectedIcon: false,
                          onSelectionChanged: (v) => onSectionChanged(v.first),
                        ),
                        OutlinedButton.icon(
                          onPressed: onChooseLibrary,
                          icon: const Icon(Icons.video_library_outlined),
                          label: Text('$libraryName ▾'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(title, style: theme.textTheme.titleLarge),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton(
                        onPressed: onChooseGenre,
                        child: Text(genreLabel),
                      ),
                      OutlinedButton(
                        onPressed: onChooseSort,
                        child: Text(sortLabel),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: onToggleFilters,
                        icon: const Icon(Icons.tune),
                        label: Text(filtersOpen ? 'Close filters' : 'Filters'),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(summary, style: theme.textTheme.bodySmall),
              if (collections.isNotEmpty) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [const Text('Collections'), ...collections],
                ),
              ],
            ],
          ),
        );
        final panel = Material(
          elevation: 6,
          color: theme.colorScheme.surface,
          child: SizedBox(
            width: wide ? 320 : double.infinity,
            child: SafeArea(
              child: Column(
                children: [
                  ListTile(
                    title: const Text('Filters'),
                    trailing: IconButton(
                      tooltip: 'Close filters',
                      onPressed: onCloseFilters,
                      icon: const Icon(Icons.close),
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(20),
                      child: filters,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        return Stack(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Column(
                    children: [
                      // Header scrolls independently at small heights; catalog stays lazy.
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: box.maxHeight * .48,
                        ),
                        child: SingleChildScrollView(child: header),
                      ),
                      Expanded(
                        child: Row(
                          children: [
                            Expanded(child: content),
                            if (alphabetRail != null)
                              SizedBox(width: 48, child: alphabetRail!),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (filtersOpen && wide) panel,
              ],
            ),
            if (filtersOpen && !wide) ...[
              Positioned.fill(
                child: ModalBarrier(
                  dismissible: true,
                  onDismiss: onCloseFilters,
                  color: Colors.black54,
                ),
              ),
              Positioned(
                top: 0,
                bottom: 0,
                right: 0,
                width: box.maxWidth < 380 ? box.maxWidth : 360,
                child: panel,
              ),
            ],
          ],
        );
      },
    );
    if (!embedInScaffold) {
      return body;
    }
    return Scaffold(
      appBar: AppBar(
        leading: onBack == null ? null : BackButton(onPressed: onBack),
        title: const Text('Movies & Series'),
        actions: appBarActions,
      ),
      body: body,
    );
  }
}

/// Receives only available letters from the parent. All buttons remain focusable.
/// The parent implements jumps using its existing lazy grid's controller/index.
class AlphabetRail extends StatelessWidget {
  const AlphabetRail({
    super.key,
    required this.selected,
    required this.available,
    required this.onJump,
  });
  final String? selected;
  final Set<String> available;
  final ValueChanged<String> onJump;
  static const letters = [
    '#',
    'A',
    'B',
    'C',
    'D',
    'E',
    'F',
    'G',
    'H',
    'I',
    'J',
    'K',
    'L',
    'M',
    'N',
    'O',
    'P',
    'Q',
    'R',
    'S',
    'T',
    'U',
    'V',
    'W',
    'X',
    'Y',
    'Z',
  ];
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxHeight < 760) {
        return Column(
          children: [
            const SizedBox(height: 8),
            IconButton(
              tooltip: 'Open alphabet picker',
              onPressed: () async {
                final picked = await showDialog<String>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Jump to letter'),
                    content: SizedBox(
                      width: 340,
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final letter in letters)
                            OutlinedButton(
                              onPressed: available.contains(letter)
                                  ? () => Navigator.pop(ctx, letter)
                                  : null,
                              child: Text(letter),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
                if (picked != null) {
                  onJump(picked);
                }
              },
              icon: const Icon(Icons.sort_by_alpha),
            ),
          ],
        );
      }
      return ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          for (final letter in letters)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1, horizontal: 2),
              child: TextButton(
                style: TextButton.styleFrom(
                  minimumSize: const Size(44, 44),
                  padding: EdgeInsets.zero,
                  backgroundColor: selected == letter
                      ? Theme.of(context).colorScheme.primary
                      : null,
                  foregroundColor: selected == letter
                      ? Theme.of(context).colorScheme.onPrimary
                      : null,
                ),
                onPressed: available.contains(letter)
                    ? () => onJump(letter)
                    : null,
                child: Semantics(
                  label: 'Jump to titles starting with $letter',
                  child: Text(letter),
                ),
              ),
            ),
        ],
      );
    },
  );
}

/// Keep sort keys and letter grouping consistent; this policy groups non-ASCII
/// initial characters and digits under #. Change both together for locale rules.
String mediaSortKey(String title) => title.trim().toUpperCase();
String mediaLetter(String title) {
  final key = mediaSortKey(title);
  if (key.isEmpty) return '#';
  final c = key.codeUnitAt(0);
  return c >= 65 && c <= 90 ? key[0] : '#';
}
