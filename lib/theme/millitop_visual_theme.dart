import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

enum MillitopLayoutPreset {
  cinematicTopBar,
  streamRail,
  commandDeck,
  haloSplit,
  emberStack,
}

enum MillitopThemeId {
  auroraGlass,
  velocityRedline,
  cobaltHorizon,
  embyEmerald,
  satelliteCommand,
  emberCanvas,
}

class MillitopThemeSpec {
  final MillitopThemeId id;
  final String label;
  final String summary;
  final MillitopLayoutPreset layoutPreset;
  final Color background;
  final Color surface;
  final Color surfaceVariant;
  final Color accent;
  final Color muted;
  final double cardRadius;
  final double buttonRadius;
  final String fontFamily;

  const MillitopThemeSpec({
    required this.id,
    required this.label,
    required this.summary,
    required this.layoutPreset,
    required this.background,
    required this.surface,
    required this.surfaceVariant,
    required this.accent,
    required this.muted,
    required this.cardRadius,
    required this.buttonRadius,
    required this.fontFamily,
  });

  ThemeData toThemeData() {
    final scheme = ColorScheme.dark(
      primary: accent,
      secondary: accent.withAlpha(220),
      surface: surface,
      onSurface: Colors.white,
      onPrimary: const Color(0xFF08161C),
    );
    final cardShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(cardRadius),
      side: BorderSide(color: Colors.white.withAlpha(16)),
    );
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: background,
      colorScheme: scheme,
      fontFamily: fontFamily,
      dividerColor: Colors.white.withAlpha(18),
      cardTheme: CardThemeData(
        color: surface,
        shape: cardShape,
        elevation: 1,
        margin: EdgeInsets.zero,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: surface.withAlpha(245),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        titleTextStyle: const TextStyle(
          color: Colors.white,
          fontSize: 22,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceVariant,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(buttonRadius),
          borderSide: BorderSide(color: Colors.white.withAlpha(22)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(buttonRadius),
          borderSide: BorderSide(color: Colors.white.withAlpha(22)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(buttonRadius),
          borderSide: BorderSide(color: accent, width: 1.8),
        ),
      ),
    );
    return base.copyWith(
      extensions: [MillitopThemeTokens.fromSpec(this)],
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: const Color(0xFF091920),
          minimumSize: const Size(0, 52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(buttonRadius),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 52),
          side: BorderSide(color: Colors.white.withAlpha(26)),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(buttonRadius),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(buttonRadius),
          ),
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        selectedColor: accent.withAlpha(40),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(buttonRadius),
        ),
        side: BorderSide(color: Colors.white.withAlpha(24)),
      ),
      listTileTheme: const ListTileThemeData(iconColor: Colors.white70),
    );
  }
}

class MillitopThemeTokens extends ThemeExtension<MillitopThemeTokens> {
  final Color panelColor;
  final Color accentColor;
  final Color mutedColor;
  final Color softBorder;
  final Color panelBorder;
  final Color selectedSurface;
  final MillitopLayoutPreset layoutPreset;
  final double cardRadius;
  final double buttonRadius;

  const MillitopThemeTokens({
    required this.panelColor,
    required this.accentColor,
    required this.mutedColor,
    required this.softBorder,
    required this.panelBorder,
    required this.selectedSurface,
    required this.layoutPreset,
    required this.cardRadius,
    required this.buttonRadius,
  });

  factory MillitopThemeTokens.fromSpec(MillitopThemeSpec spec) {
    return MillitopThemeTokens(
      panelColor: spec.surfaceVariant,
      accentColor: spec.accent,
      mutedColor: spec.muted,
      softBorder: Colors.white.withAlpha(12),
      panelBorder: spec.accent.withAlpha(78),
      selectedSurface: spec.accent.withAlpha(44),
      layoutPreset: spec.layoutPreset,
      cardRadius: spec.cardRadius,
      buttonRadius: spec.buttonRadius,
    );
  }

  static const fallback = MillitopThemeTokens(
    panelColor: Color(0xFF16243A),
    accentColor: Color(0xFF63DFCB),
    mutedColor: Color(0xFFA4B3C8),
    softBorder: Color(0x22FFFFFF),
    panelBorder: Color(0x3348D1CC),
    selectedSurface: Color(0x3323D5C8),
    layoutPreset: MillitopLayoutPreset.cinematicTopBar,
    cardRadius: 18,
    buttonRadius: 16,
  );

  @override
  ThemeExtension<MillitopThemeTokens> copyWith({
    Color? panelColor,
    Color? accentColor,
    Color? mutedColor,
    Color? softBorder,
    Color? panelBorder,
    Color? selectedSurface,
    MillitopLayoutPreset? layoutPreset,
    double? cardRadius,
    double? buttonRadius,
  }) {
    return MillitopThemeTokens(
      panelColor: panelColor ?? this.panelColor,
      accentColor: accentColor ?? this.accentColor,
      mutedColor: mutedColor ?? this.mutedColor,
      softBorder: softBorder ?? this.softBorder,
      panelBorder: panelBorder ?? this.panelBorder,
      selectedSurface: selectedSurface ?? this.selectedSurface,
      layoutPreset: layoutPreset ?? this.layoutPreset,
      cardRadius: cardRadius ?? this.cardRadius,
      buttonRadius: buttonRadius ?? this.buttonRadius,
    );
  }

  @override
  ThemeExtension<MillitopThemeTokens> lerp(
    covariant ThemeExtension<MillitopThemeTokens>? other,
    double t,
  ) {
    if (other is! MillitopThemeTokens) {
      return this;
    }
    return MillitopThemeTokens(
      panelColor: Color.lerp(panelColor, other.panelColor, t) ?? panelColor,
      accentColor: Color.lerp(accentColor, other.accentColor, t) ?? accentColor,
      mutedColor: Color.lerp(mutedColor, other.mutedColor, t) ?? mutedColor,
      softBorder: Color.lerp(softBorder, other.softBorder, t) ?? softBorder,
      panelBorder: Color.lerp(panelBorder, other.panelBorder, t) ?? panelBorder,
      selectedSurface:
          Color.lerp(selectedSurface, other.selectedSurface, t) ??
          selectedSurface,
      layoutPreset: t < 0.5 ? layoutPreset : other.layoutPreset,
      cardRadius: lerpDouble(cardRadius, other.cardRadius, t) ?? cardRadius,
      buttonRadius:
          lerpDouble(buttonRadius, other.buttonRadius, t) ?? buttonRadius,
    );
  }
}

class MillitopThemeController extends ChangeNotifier {
  MillitopThemeController._();
  static final MillitopThemeController instance = MillitopThemeController._();

  static const List<MillitopThemeSpec> themes = [
    MillitopThemeSpec(
      id: MillitopThemeId.auroraGlass,
      label: 'Aurora Glass',
      summary: 'Glass panels, floating focus, cinematic spacing.',
      layoutPreset: MillitopLayoutPreset.cinematicTopBar,
      background: Color(0xFF0A1426),
      surface: Color(0xFF101D31),
      surfaceVariant: Color(0xFF152742),
      accent: Color(0xFF6EEDE0),
      muted: Color(0xFFA9BCD3),
      cardRadius: 22,
      buttonRadius: 18,
      fontFamily: 'Segoe UI',
    ),
    MillitopThemeSpec(
      id: MillitopThemeId.velocityRedline,
      label: 'Velocity Redline',
      summary: 'Broadcast-style rails with high-contrast action cues.',
      layoutPreset: MillitopLayoutPreset.streamRail,
      background: Color(0xFF0A0F18),
      surface: Color(0xFF111826),
      surfaceVariant: Color(0xFF161F31),
      accent: Color(0xFFFF3D4E),
      muted: Color(0xFFB4BFCC),
      cardRadius: 14,
      buttonRadius: 12,
      fontFamily: 'Segoe UI',
    ),
    MillitopThemeSpec(
      id: MillitopThemeId.cobaltHorizon,
      label: 'Cobalt Horizon',
      summary: 'Structured side navigation with calm information density.',
      layoutPreset: MillitopLayoutPreset.commandDeck,
      background: Color(0xFF041230),
      surface: Color(0xFF0B2A5C),
      surfaceVariant: Color(0xFF123874),
      accent: Color(0xFF5FD0FF),
      muted: Color(0xFFC3D8F4),
      cardRadius: 12,
      buttonRadius: 10,
      fontFamily: 'Segoe UI',
    ),
    MillitopThemeSpec(
      id: MillitopThemeId.embyEmerald,
      label: 'Emby Emerald',
      summary: 'Crisp emerald highlights with modern media-panel balance.',
      layoutPreset: MillitopLayoutPreset.commandDeck,
      background: Color(0xFF07140F),
      surface: Color(0xFF0E231C),
      surfaceVariant: Color(0xFF163229),
      accent: Color(0xFF5FE3A0),
      muted: Color(0xFFBEDCCB),
      cardRadius: 12,
      buttonRadius: 10,
      fontFamily: 'Segoe UI',
    ),
    MillitopThemeSpec(
      id: MillitopThemeId.satelliteCommand,
      label: 'Satellite Command',
      summary: 'Dense utility-first controls with command-line rhythm.',
      layoutPreset: MillitopLayoutPreset.haloSplit,
      background: Color(0xFF101119),
      surface: Color(0xFF181A26),
      surfaceVariant: Color(0xFF222739),
      accent: Color(0xFF83D5FF),
      muted: Color(0xFFAAB5C8),
      cardRadius: 9,
      buttonRadius: 8,
      fontFamily: 'Segoe UI',
    ),
    MillitopThemeSpec(
      id: MillitopThemeId.emberCanvas,
      label: 'Ember Canvas',
      summary: 'Warm gradient highlights with bold card-first navigation.',
      layoutPreset: MillitopLayoutPreset.emberStack,
      background: Color(0xFF160E16),
      surface: Color(0xFF25142A),
      surfaceVariant: Color(0xFF331D37),
      accent: Color(0xFFFF8F5A),
      muted: Color(0xFFD5BECC),
      cardRadius: 20,
      buttonRadius: 16,
      fontFamily: 'Segoe UI',
    ),
  ];

  MillitopThemeSpec _current = themes.first;

  MillitopThemeSpec get current => _current;

  ThemeData get materialTheme => _current.toThemeData();

  void setTheme(MillitopThemeId id) {
    final next = themes.firstWhere(
      (theme) => theme.id == id,
      orElse: () => themes.first,
    );
    if (identical(next, _current)) {
      return;
    }
    _current = next;
    notifyListeners();
  }

  static MillitopThemeId fromStorage(String? raw) {
    switch (raw?.trim()) {
      case 'velocity-redline':
        return MillitopThemeId.velocityRedline;
      case 'cobalt-horizon':
        return MillitopThemeId.cobaltHorizon;
      case 'emby-emerald':
        return MillitopThemeId.embyEmerald;
      case 'satellite-command':
        return MillitopThemeId.satelliteCommand;
      case 'ember-canvas':
        return MillitopThemeId.emberCanvas;
      case 'aurora-glass':
      default:
        return MillitopThemeId.auroraGlass;
    }
  }

  static String toStorage(MillitopThemeId id) {
    switch (id) {
      case MillitopThemeId.auroraGlass:
        return 'aurora-glass';
      case MillitopThemeId.velocityRedline:
        return 'velocity-redline';
      case MillitopThemeId.cobaltHorizon:
        return 'cobalt-horizon';
      case MillitopThemeId.embyEmerald:
        return 'emby-emerald';
      case MillitopThemeId.satelliteCommand:
        return 'satellite-command';
      case MillitopThemeId.emberCanvas:
        return 'ember-canvas';
    }
  }
}

extension MillitopThemeContext on BuildContext {
  MillitopThemeTokens get millitopTheme =>
      Theme.of(this).extension<MillitopThemeTokens>() ??
      MillitopThemeTokens.fallback;
}
