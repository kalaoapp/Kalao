import 'package:flutter/material.dart';

/// A setting adjusted in fixed steps: label, current value, − and + buttons
/// and an optional reset.
class StepperTile extends StatelessWidget {
  const StepperTile({
    super.key,
    required this.icon,
    required this.title,
    required this.value,
    required this.decreaseTooltip,
    required this.increaseTooltip,
    required this.onDecrease,
    required this.onIncrease,
    this.resetTooltip,
    this.onReset,
    this.dense = false,
  });

  final IconData icon;
  final String title;
  final String value;
  final String decreaseTooltip;
  final String increaseTooltip;

  /// Null disables the button (the value is at its limit).
  final VoidCallback? onDecrease;
  final VoidCallback? onIncrease;
  final String? resetTooltip;
  final VoidCallback? onReset;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: dense,
      leading: Icon(icon),
      title: Text(title),
      subtitle: Semantics(liveRegion: true, child: Text(value)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (resetTooltip != null)
            IconButton(
              tooltip: resetTooltip,
              icon: const Icon(Icons.restart_alt),
              onPressed: onReset,
            ),
          IconButton(
            tooltip: decreaseTooltip,
            icon: const Icon(Icons.remove),
            onPressed: onDecrease,
          ),
          IconButton(
            tooltip: increaseTooltip,
            icon: const Icon(Icons.add),
            onPressed: onIncrease,
          ),
        ],
      ),
    );
  }
}
