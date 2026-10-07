import 'package:flutter/material.dart';

/// A quiet attribution for account pages and invitation dialogs.
class CopyrightNotice extends StatelessWidget {
  const CopyrightNotice({super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Center(
          heightFactor: 1,
          child: Text(
            '© 2026 VibeMeeting contributors',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11,
              height: 1.4,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
}
