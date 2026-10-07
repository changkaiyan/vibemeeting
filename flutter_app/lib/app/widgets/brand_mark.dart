import 'package:flutter/material.dart';

class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.fontSize = 20});

  final double fontSize;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Image.network(
              '/static/brand/vibemeeting-logo.png',
              width: 28,
              height: 28,
              semanticLabel: 'VibeMeeting Logo',
              errorBuilder: (_, __, ___) => const SizedBox(
                width: 28,
                height: 28,
                child: Center(
                    child:
                        Text('V', style: TextStyle(color: Color(0xff1d5ee7)))),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              'VibeMeeting',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: fontSize,
                  fontWeight: FontWeight.w700,
                  color: Colors.white),
            ),
          ),
        ],
      );
}
