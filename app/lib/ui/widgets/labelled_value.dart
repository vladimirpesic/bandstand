import 'package:bandstand/ui/theme/bandstand_theme.dart';
import 'package:flutter/material.dart';

/// A label above a value, used for every read-only fact in the app.
class LabelledValue extends StatelessWidget {
  const LabelledValue({
    required this.label,
    required this.value,
    this.emphasis = false,
    super.key,
  });

  /// What the value is.
  final String label;

  /// The value itself.
  final String value;

  /// Whether to render the value larger, for the handful of readouts that are
  /// glanced at rather than read.
  final bool emphasis;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          label.toUpperCase(),
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style:
              (emphasis
                      ? theme.textTheme.headlineSmall
                      : theme.textTheme.bodyLarge)
                  ?.merge(BandstandTheme.numeric),
        ),
      ],
    );
  }
}
