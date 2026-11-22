// Derived from Mornye (https://github.com/mornyeapp/Mornye), Copyright 2026 zarzet,
// LGPL-3.0-only. Modified for Kalao.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart' as material_ui;
import 'package:kalao/theme/app_tokens.dart';

/// Builds the Material 3 theme: Mornye's Material style (its iOS glass style
/// is not part of Kalao) over the Kalao or Material You scheme.
class AppTheme {
  AppTheme._();

  /// Kalao's own scheme, used when Material You is off or unavailable.
  /// Material's tonal palette from the brand primary fills every role; the
  /// six brand colours then pin the roles they define (BRANDING.md).
  static ColorScheme seededScheme(Brightness brightness) {
    final base = ColorScheme.fromSeed(
      seedColor: AppTokens.brandPrimary,
      brightness: brightness,
    );
    return brightness == Brightness.light
        ? base.copyWith(
            primary: AppTokens.brandPrimary,
            onPrimary: Colors.white,
            primaryContainer: AppTokens.brandContainer,
            onPrimaryContainer: AppTokens.brandDeep,
            surface: AppTokens.brandSurface,
            onSurface: AppTokens.brandInk,
            inverseSurface: AppTokens.brandInk,
            onInverseSurface: AppTokens.brandSurface,
          )
        : base.copyWith(
            primary: AppTokens.brandLight,
            onPrimary: AppTokens.brandDeep,
            primaryContainer: AppTokens.brandPrimary,
            onPrimaryContainer: AppTokens.brandContainer,
            surface: AppTokens.brandInk,
            onSurface: AppTokens.brandContainer,
            inverseSurface: AppTokens.brandSurface,
            onInverseSurface: AppTokens.brandInk,
            inversePrimary: AppTokens.brandPrimary,
          );
  }

  /// A Flutter scheme from dynamic_color's (`material_ui`) scheme, as in
  /// Mornye's `dynamic_color_wrapper.dart`.
  static ColorScheme fromDynamic(material_ui.ColorScheme scheme) =>
      ColorScheme.fromSeed(
        seedColor: scheme.primary,
        brightness: scheme.brightness,
      ).copyWith(
        primary: scheme.primary,
        onPrimary: scheme.onPrimary,
        primaryContainer: scheme.primaryContainer,
        onPrimaryContainer: scheme.onPrimaryContainer,
        secondary: scheme.secondary,
        onSecondary: scheme.onSecondary,
        secondaryContainer: scheme.secondaryContainer,
        onSecondaryContainer: scheme.onSecondaryContainer,
        tertiary: scheme.tertiary,
        onTertiary: scheme.onTertiary,
        tertiaryContainer: scheme.tertiaryContainer,
        onTertiaryContainer: scheme.onTertiaryContainer,
        error: scheme.error,
        onError: scheme.onError,
        errorContainer: scheme.errorContainer,
        onErrorContainer: scheme.onErrorContainer,
        outline: scheme.outline,
        outlineVariant: scheme.outlineVariant,
        surface: scheme.surface,
        onSurface: scheme.onSurface,
        surfaceContainerLowest: scheme.surfaceContainerLowest,
        surfaceContainerLow: scheme.surfaceContainerLow,
        surfaceContainer: scheme.surfaceContainer,
        surfaceContainerHigh: scheme.surfaceContainerHigh,
        surfaceContainerHighest: scheme.surfaceContainerHighest,
        onSurfaceVariant: scheme.onSurfaceVariant,
        inverseSurface: scheme.inverseSurface,
        onInverseSurface: scheme.onInverseSurface,
        inversePrimary: scheme.inversePrimary,
        shadow: scheme.shadow,
        surfaceTint: scheme.surfaceTint,
        scrim: scheme.scrim,
      );

  /// Mornye's Material component themes (`lib/theme/app_theme.dart`):
  /// stadium buttons, filled borderless fields, 20dp cards, 28dp sheets and
  /// dialogs, a container-toned navigation bar and floating snack bars.
  static ThemeData build(ColorScheme scheme) {
    final dark = scheme.brightness == Brightness.dark;
    final control = BorderRadius.circular(AppTokens.radiusControl);
    const stadiumPadding = EdgeInsets.symmetric(horizontal: 24, vertical: 12);
    OutlineInputBorder field([BorderSide side = BorderSide.none]) =>
        OutlineInputBorder(borderRadius: control, borderSide: side);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 3,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: scheme.surfaceTint,
        centerTitle: false,
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
          systemNavigationBarColor: scheme.surfaceContainer,
          systemNavigationBarIconBrightness: dark
              ? Brightness.light
              : Brightness.dark,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLow,
        surfaceTintColor: scheme.surfaceTint,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusCard),
        ),
        margin: EdgeInsets.zero,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          elevation: 1,
          shape: const StadiumBorder(),
          padding: stadiumPadding,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: const StadiumBorder(),
          padding: stadiumPadding,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: const StadiumBorder(),
          padding: stadiumPadding,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        elevation: 3,
        shape: RoundedRectangleBorder(borderRadius: control),
        backgroundColor: scheme.primaryContainer,
        foregroundColor: scheme.onPrimaryContainer,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHigh,
        border: field(),
        enabledBorder: field(),
        focusedBorder: field(BorderSide(color: scheme.primary, width: 2)),
        errorBorder: field(BorderSide(color: scheme.error)),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 20,
          vertical: 16,
        ),
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: control),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppTokens.space16,
          vertical: AppTokens.space4,
        ),
      ),
      dialogTheme: DialogThemeData(
        elevation: 6,
        backgroundColor: scheme.surfaceContainerHigh,
        surfaceTintColor: scheme.surfaceTint,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusSheet),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        constraints: BoxConstraints(maxWidth: 640),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppTokens.radiusSheet),
          ),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        elevation: 0,
        backgroundColor: scheme.surfaceContainer,
        indicatorColor: scheme.secondaryContainer,
        surfaceTintColor: scheme.surfaceTint,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: control),
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: TextStyle(color: scheme.onInverseSurface),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.surfaceContainerHighest,
        circularTrackColor: scheme.surfaceContainerHighest,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.onPrimary
              : scheme.outline,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.primary
              : scheme.surfaceContainerHighest,
        ),
        thumbIcon: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? Icon(Icons.check, color: scheme.primary)
              : null,
        ),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTokens.radiusCard),
        ),
        backgroundColor: scheme.surfaceContainerLow,
        selectedColor: scheme.secondaryContainer,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        elevation: 3,
        shape: RoundedRectangleBorder(borderRadius: control),
        menuPadding: const EdgeInsets.symmetric(vertical: AppTokens.space8),
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerLow),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          elevation: const WidgetStatePropertyAll(3),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.all(AppTokens.space4),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: control),
          ),
        ),
      ),
      tabBarTheme: TabBarThemeData(
        indicatorSize: TabBarIndicatorSize.label,
        indicator: UnderlineTabIndicator(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
          borderSide: BorderSide(color: scheme.primary, width: 3),
        ),
        labelStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: 1,
      ),
      searchBarTheme: SearchBarThemeData(
        elevation: const WidgetStatePropertyAll(0),
        backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerHigh),
        shape: const WidgetStatePropertyAll(StadiumBorder()),
      ),
    );
  }
}
