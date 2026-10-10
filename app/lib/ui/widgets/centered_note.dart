import 'package:flutter/material.dart';

/// An icon and a sentence, dead centre — the shape every screen's
/// "nothing here / it went away" state takes.
class CenteredNote extends StatelessWidget {
  /// Create the note.
  const CenteredNote({super.key, required this.icon, required this.message});

  /// What to show above the words.
  final IconData icon;

  /// What to say, centred.
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 56),
          const SizedBox(height: 16),
          Text(message, textAlign: TextAlign.center),
        ],
      ),
    );
  }
}
