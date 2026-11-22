// Derived from Mornye (https://github.com/mornyeapp/Mornye), Copyright 2026 zarzet, LGPL-3.0-only. Modified for Kalao.
// Ported from Mornye's `core/src/cover/folder.rs`: folder images such as
// cover.jpg for songs without embedded artwork.

/// Stems in priority order; the first stem found in a folder wins.
const _stems = ['cover', 'folder', 'front', 'album', 'albumart'];
const folderImageExtensions = ['jpg', 'jpeg', 'png', 'webp'];

/// The priority of [name] as a folder image, lower first, or null when it is
/// not one. Case is ignored. Hidden files never qualify: macOS leaves
/// AppleDouble `._cover.jpg` files beside the real image.
int? folderImageRank(String name) {
  if (name.startsWith('.')) return null;
  final dot = name.lastIndexOf('.');
  if (dot <= 0) return null;
  final stem = _stems.indexOf(name.substring(0, dot).toLowerCase());
  final extension = folderImageExtensions.indexOf(
    name.substring(dot + 1).toLowerCase(),
  );
  if (stem < 0 || extension < 0) return null;
  return stem * folderImageExtensions.length + extension;
}

/// The folder image among a directory's file [names], if any.
String? folderImage(Iterable<String> names) {
  String? best;
  int? bestRank;
  for (final name in names) {
    final rank = folderImageRank(name);
    if (rank != null && (bestRank == null || rank < bestRank)) {
      best = name;
      bestRank = rank;
    }
  }
  return best;
}

/// Whether [name] looks like one disc of a multi-disc album (`CD1`, `CD 2`,
/// `Disc 1`, `Disk 02`, `Disc 1 - Title`). Such folders often leave the
/// album picture to their parent.
bool isDiscFolder(String name) {
  final lower = name.trim().toLowerCase();
  String? rest;
  for (final prefix in const ['disc', 'disk', 'cd']) {
    if (lower.startsWith(prefix)) {
      rest = lower.substring(prefix.length);
      break;
    }
  }
  if (rest == null) return false;
  rest = rest.replaceFirst(RegExp(r'^[ _\-.]+'), '');
  final digits = RegExp(r'^\d+').firstMatch(rest)?.group(0);
  if (digits == null) return false;
  final after = rest.substring(digits.length);
  return after.isEmpty ||
      !RegExp(r'^[\p{L}\p{N}]', unicode: true).hasMatch(after);
}
