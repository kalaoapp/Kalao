import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// The app is portrait-only; `main` applies this before the first frame.
const appOrientations = [DeviceOrientation.portraitUp];

/// Lets the device rotate while [child] is shown (the player and the screens
/// above it), and returns to [appOrientations] when it goes away.
class AnyOrientation extends StatefulWidget {
  const AnyOrientation({super.key, required this.child});

  final Widget child;

  @override
  State<AnyOrientation> createState() => _AnyOrientationState();
}

class _AnyOrientationState extends State<AnyOrientation> {
  @override
  void initState() {
    super.initState();
    unawaited(SystemChrome.setPreferredOrientations(DeviceOrientation.values));
  }

  @override
  void dispose() {
    unawaited(SystemChrome.setPreferredOrientations(appOrientations));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
