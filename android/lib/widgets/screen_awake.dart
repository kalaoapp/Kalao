import 'package:flutter/widgets.dart';
import 'package:kalao/services/platform_bridge.dart';

/// Keeps the screen on while [enabled] (Mornye's `lyrics_screen_awake`), and
/// lets it sleep again when disabled or removed.
class ScreenAwake extends StatefulWidget {
  const ScreenAwake({super.key, required this.enabled});

  final bool enabled;

  @override
  State<ScreenAwake> createState() => _ScreenAwakeState();
}

class _ScreenAwakeState extends State<ScreenAwake> {
  bool _awake = false;

  void _apply(bool awake) {
    if (awake == _awake) return;
    _awake = awake;
    // Not on Android (tests, desktop): nothing to keep awake.
    PlatformBridge.setScreenAwake(awake).catchError((Object _) {});
  }

  @override
  void initState() {
    super.initState();
    _apply(widget.enabled);
  }

  @override
  void didUpdateWidget(ScreenAwake old) {
    super.didUpdateWidget(old);
    _apply(widget.enabled);
  }

  @override
  void dispose() {
    _apply(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
