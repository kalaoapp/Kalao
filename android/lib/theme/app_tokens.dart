// Derived from Mornye (https://github.com/mornyeapp/Mornye), Copyright 2026 zarzet,
// LGPL-3.0-only. Modified for Kalao.
import 'package:flutter/material.dart';

/// Design tokens shared by every screen. Widgets read spacing and radii from
/// here and colours from `Theme.of(context).colorScheme`, never literals.
class AppTokens {
  AppTokens._();

  // Brand palette (kalaoapp/branding guidelines/colour.png; BRANDING.md).
  /// Primary ("fern"): the one colour that does the work.
  static const Color brandPrimary = Color(0xFF31572C);

  /// Deep: text on the light tints.
  static const Color brandDeep = Color(0xFF182C16);

  /// Ink: the darkest neutral; dark surfaces and text on light surfaces.
  static const Color brandInk = Color(0xFF151A14);

  /// Container: light green-grey tint behind primary content.
  static const Color brandContainer = Color(0xFFDEE4DD);

  /// Light: mid tint; the primary role on dark surfaces.
  static const Color brandLight = Color(0xFFB1BFAF);

  /// Surface: the page colour in light mode.
  static const Color brandSurface = Color(0xFFF5F7F4);

  static const double space2 = 2;
  static const double space4 = 4;
  static const double space8 = 8;
  static const double space12 = 12;
  static const double space16 = 16;
  static const double space24 = 24;
  static const double space32 = 32;

  static const double radiusSmall = 8;
  static const double radiusMedium = 12;
  static const double radiusLarge = 20;
  static const double radiusFull = 999;

  /// Grouped containers: settings groups, section cards (Mornye's
  /// `radiusCard`). Rows inside a connected group keep [radiusRowInner]
  /// between them.
  static const double radiusCard = 20;
  static const double radiusRowInner = 4;

  /// Mornye's settings rows (`AppTokens.standard`).
  static const double rowPaddingH = 20;
  static const double rowPaddingV = 16;
  static const double rowPaddingVCompact = 12;
  static const double rowIconGap = 16;
  static const double rowIconDividerIndent = 56;
  static const double rowChevronSize = 24;

  /// Gap between the rows of a connected group.
  static const double rowGap = 2;

  /// Mornye's collapsing page header.
  static const double headerExpandedHeight = 120;
  static const double headerCollapsedTitleSize = 20;
  static const double headerExpandedTitleSize = 28;

  /// Readable line length for long text on tablets.
  static const double maxContentWidth = 720;

  static const Duration motionShort = Duration(milliseconds: 150);
  static const Duration motionMedium = Duration(milliseconds: 250);
}
