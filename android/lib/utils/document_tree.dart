/// Storage Access Framework tree URIs (`content://…/tree/primary%3AMusic`).
library;

/// The tree's document id (`primary:Music/Karaoke`).
String treeId(String treeUri) {
  final segments = Uri.parse(treeUri).pathSegments;
  final tree = segments.indexOf('tree');
  return tree >= 0 && tree + 1 < segments.length
      ? segments[tree + 1]
      : segments.lastOrNull ?? treeUri;
}

/// What the user sees for a granted folder: its path in the volume, or the
/// volume for a whole one.
String treeFolderName(String treeUri) {
  final id = treeId(treeUri);
  final colon = id.indexOf(':');
  if (colon < 0) return id;
  final path = id.substring(colon + 1);
  return path.isEmpty ? id.substring(0, colon) : path;
}

/// Whether one tree contains the other (or they are the same folder).
bool treesOverlap(String a, String b) {
  if (Uri.parse(a).authority != Uri.parse(b).authority) return false;
  final ia = treeId(a), ib = treeId(b);
  bool inside(String inner, String outer) =>
      inner == outer ||
      inner.startsWith(outer.endsWith(':') ? outer : '$outer/');
  return inside(ia, ib) || inside(ib, ia);
}
