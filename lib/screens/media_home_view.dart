import 'package:flutter/material.dart';

/// Source badge colors shared by the Home hub and poster cards.
class MediaSourceColors {
  static const jellyfin = Color(0xFF7C3AED);
  static const iptv = Color(0xFFF59E0B);
  static const nas = Color(0xFF0EA5E9);
  static const dvr = Color(0xFFE53935);
  static const accent = Color(0xFF63DFCB);
  static const muted = Color(0xFF8FA3BF);
  static const panel = Color(0xFF16243A);
}

class MediaHomeCard {
  final String id;
  final String title;
  final String? subtitle;
  final String? imageUrl;
  final double? progress;
  final String? badge;
  final Color? badgeColor;
  final IconData? icon;
  final VoidCallback onTap;
  final ValueChanged<Offset>? onMoreAt;
  const MediaHomeCard({
    required this.id,
    required this.title,
    this.subtitle,
    this.imageUrl,
    this.progress,
    this.badge,
    this.badgeColor,
    this.icon,
    required this.onTap,
    this.onMoreAt,
  });
}

enum MediaHomeCardShape { poster, landscape, tile }

class MediaHomeRow {
  final String title;
  final List<MediaHomeCard> cards;
  final MediaHomeCardShape shape;
  final String? actionLabel;
  final VoidCallback? onAction;
  const MediaHomeRow({
    required this.title,
    required this.cards,
    this.shape = MediaHomeCardShape.poster,
    this.actionLabel,
    this.onAction,
  });
}

class MediaHomeHero {
  final String title;
  final String? overview;
  final String? meta;
  final String? backdropUrl;
  final String? badge;
  final Color? badgeColor;
  final String playLabel;
  final double? progress;
  final VoidCallback onPlay;
  final VoidCallback onDetails;
  const MediaHomeHero({
    required this.title,
    this.overview,
    this.meta,
    this.backdropUrl,
    this.badge,
    this.badgeColor,
    this.playLabel = 'Play',
    this.progress,
    required this.onPlay,
    required this.onDetails,
  });
}

/// Movies & Series landing page: hero, then horizontal rows like Jellyfin
/// or Emby's home screen. Works with a TV remote (every card is focusable).
class MediaHomeView extends StatelessWidget {
  final MediaHomeHero? hero;
  final List<MediaHomeRow> rows;
  final Widget? emptyState;
  const MediaHomeView({
    super.key,
    this.hero,
    required this.rows,
    this.emptyState,
  });

  @override
  Widget build(BuildContext context) {
    final visibleRows = rows.where((row) => row.cards.isNotEmpty).toList();
    if (hero == null && visibleRows.isEmpty) {
      return emptyState ??
          const Center(child: Text('Nothing to show yet. Add a source.'));
    }
    return ListView(
      key: const ValueKey('media-home'),
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        if (hero != null) _HeroBanner(hero: hero!),
        for (final row in visibleRows) _HomeRow(row: row),
      ],
    );
  }
}

class _HeroBanner extends StatelessWidget {
  final MediaHomeHero hero;
  const _HeroBanner({required this.hero});

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final phone = width < 600;
    final height = phone ? 260.0 : 320.0;
    return Container(
      height: height,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: MediaSourceColors.panel,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (hero.backdropUrl != null && hero.backdropUrl!.isNotEmpty)
            Image.network(
              hero.backdropUrl!,
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  Color(0xF00A1426),
                  Color(0x990A1426),
                  Color(0x000A1426),
                ],
                stops: [0, 0.5, 1],
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.all(phone ? 16 : 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (hero.badge != null)
                    _Badge(label: hero.badge!, color: hero.badgeColor),
                  const SizedBox(height: 8),
                  Text(
                    hero.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: phone ? 24 : 30,
                      fontWeight: FontWeight.w800,
                      height: 1.1,
                    ),
                  ),
                  if (hero.meta != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      hero.meta!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: MediaSourceColors.muted),
                    ),
                  ],
                  if (hero.overview != null && width >= 600) ...[
                    const SizedBox(height: 8),
                    Text(
                      hero.overview!,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        key: const ValueKey('media-home-hero-play'),
                        autofocus: true,
                        onPressed: hero.onPlay,
                        icon: const Icon(Icons.play_arrow),
                        label: Text(hero.playLabel),
                      ),
                      OutlinedButton.icon(
                        onPressed: hero.onDetails,
                        icon: const Icon(Icons.info_outline),
                        label: const Text('More info'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (hero.progress != null && hero.progress! > 0)
            Align(
              alignment: Alignment.bottomCenter,
              child: LinearProgressIndicator(
                value: hero.progress,
                minHeight: 4,
                color: MediaSourceColors.accent,
                backgroundColor: Colors.white24,
              ),
            ),
        ],
      ),
    );
  }
}

class _HomeRow extends StatelessWidget {
  final MediaHomeRow row;
  const _HomeRow({required this.row});

  @override
  Widget build(BuildContext context) {
    final (cardWidth, cardHeight) = switch (row.shape) {
      MediaHomeCardShape.poster => (140.0, 252.0),
      MediaHomeCardShape.landscape => (260.0, 196.0),
      MediaHomeCardShape.tile => (200.0, 96.0),
    };
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    row.title,
                    style: const TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (row.actionLabel != null && row.onAction != null)
                  TextButton(
                    onPressed: row.onAction,
                    child: Text(row.actionLabel!),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: cardHeight,
            child: FocusTraversalGroup(
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: row.cards.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (context, index) => SizedBox(
                  width: cardWidth,
                  child: _HomeCard(card: row.cards[index], shape: row.shape),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HomeCard extends StatefulWidget {
  final MediaHomeCard card;
  final MediaHomeCardShape shape;
  const _HomeCard({required this.card, required this.shape});

  @override
  State<_HomeCard> createState() => _HomeCardState();
}

class _HomeCardState extends State<_HomeCard> {
  bool focused = false;
  final GlobalKey _moreButtonKey = GlobalKey();

  void _openMoreMenu() {
    final callback = widget.card.onMoreAt;
    if (callback == null) {
      return;
    }
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) {
      return;
    }
    final center = box.localToGlobal(box.size.center(Offset.zero));
    callback(center);
  }

  void _openMoreMenuFromButton() {
    final callback = widget.card.onMoreAt;
    final ctx = _moreButtonKey.currentContext;
    if (callback == null || ctx == null) {
      _openMoreMenu();
      return;
    }
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null) {
      _openMoreMenu();
      return;
    }
    final center = box.localToGlobal(box.size.center(Offset.zero));
    callback(center);
  }

  @override
  Widget build(BuildContext context) {
    final card = widget.card;
    final border = BorderSide(
      color: focused ? MediaSourceColors.accent : Colors.white.withAlpha(18),
      width: focused ? 3 : 1,
    );
    if (widget.shape == MediaHomeCardShape.tile) {
      return InkWell(
        key: ValueKey('media-home-card-${card.id}'),
        onTap: card.onTap,
        onFocusChange: (value) => setState(() => focused = value),
        borderRadius: BorderRadius.circular(14),
        child: Ink(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.fromBorderSide(border),
            gradient: LinearGradient(
              colors: [
                (card.badgeColor ?? MediaSourceColors.accent).withAlpha(90),
                MediaSourceColors.panel,
              ],
            ),
          ),
          child: Row(
            children: [
              Icon(card.icon ?? Icons.video_library_outlined, size: 30),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      card.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    if (card.subtitle != null)
                      Text(
                        card.subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: MediaSourceColors.muted,
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
              ),
              if (card.onMoreAt != null)
                IconButton(
                  key: _moreButtonKey,
                  tooltip: 'More actions',
                  onPressed: _openMoreMenuFromButton,
                  icon: const Icon(Icons.more_vert),
                ),
            ],
          ),
        ),
      );
    }
    return InkWell(
      key: ValueKey('media-home-card-${card.id}'),
      onTap: card.onTap,
      onFocusChange: (value) => setState(() => focused = value),
      borderRadius: BorderRadius.circular(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Image fills whatever the row height leaves after the text, so
          // larger text scales never overflow the card.
          Expanded(
            child: Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: MediaSourceColors.panel,
                borderRadius: BorderRadius.circular(12),
                border: Border.fromBorderSide(border),
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (card.imageUrl != null && card.imageUrl!.isNotEmpty)
                    Image.network(
                      card.imageUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => _placeholder(card),
                    )
                  else
                    _placeholder(card),
                  if (card.badge != null)
                    Positioned(
                      left: 6,
                      top: 6,
                      child: _Badge(label: card.badge!, color: card.badgeColor),
                    ),
                  if (card.onMoreAt != null)
                    Positioned(
                      right: 4,
                      top: 4,
                      child: Material(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(20),
                        child: IconButton(
                          key: _moreButtonKey,
                          tooltip: 'More actions',
                          visualDensity: VisualDensity.compact,
                          iconSize: 18,
                          onPressed: _openMoreMenuFromButton,
                          icon: const Icon(Icons.more_vert),
                        ),
                      ),
                    ),
                  if (card.progress != null && card.progress! > 0)
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: LinearProgressIndicator(
                        value: card.progress!.clamp(0.0, 1.0),
                        minHeight: 4,
                        color: MediaSourceColors.accent,
                        backgroundColor: Colors.black54,
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            card.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          if (card.subtitle != null)
            Text(
              card.subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: MediaSourceColors.muted,
                fontSize: 12,
              ),
            ),
        ],
      ),
    );
  }

  Widget _placeholder(MediaHomeCard card) => Center(
    child: Padding(
      padding: const EdgeInsets.all(8),
      child: Icon(
        card.icon ?? Icons.movie_outlined,
        size: 36,
        color: MediaSourceColors.muted,
      ),
    ),
  );
}

class _Badge extends StatelessWidget {
  final String label;
  final Color? color;
  const _Badge({required this.label, this.color});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: color ?? MediaSourceColors.accent,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      label,
      style: const TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w800,
        color: Colors.white,
        letterSpacing: .4,
      ),
    ),
  );
}
