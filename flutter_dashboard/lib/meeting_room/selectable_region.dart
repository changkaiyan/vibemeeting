import 'package:flutter/material.dart';

class MeetingSelectableRegion extends StatelessWidget {
  final Widget child;

  const MeetingSelectableRegion({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return SelectionArea(child: child);
  }
}

class _MeetingSelectableText extends StatelessWidget {
  final String data;
  final TextStyle? style;
  final int? minLines;
  final int? maxLines;
  final TextAlign? textAlign;

  const _MeetingSelectableText(
    this.data, {
    super.key,
    this.style,
    this.minLines,
    this.maxLines,
    this.textAlign,
  });

  @override
  Widget build(BuildContext context) {
    return SelectableText(
      data,
      style: style,
      minLines: minLines,
      maxLines: maxLines,
      textAlign: textAlign,
    );
  }
}

class MeetingTitleText extends StatelessWidget {
  final String data;
  final TextStyle? style;
  final int? minLines;
  final int? maxLines;
  final TextAlign? textAlign;

  const MeetingTitleText(
    this.data, {
    super.key,
    this.style,
    this.minLines,
    this.maxLines,
    this.textAlign,
  });

  @override
  Widget build(BuildContext context) {
    return _MeetingSelectableText(
      data,
      style: style,
      minLines: minLines,
      maxLines: maxLines,
      textAlign: textAlign,
    );
  }
}

class MeetingBodyText extends StatelessWidget {
  final String data;
  final TextStyle? style;
  final int? minLines;
  final int? maxLines;
  final TextAlign? textAlign;

  const MeetingBodyText(
    this.data, {
    super.key,
    this.style,
    this.minLines,
    this.maxLines,
    this.textAlign,
  });

  @override
  Widget build(BuildContext context) {
    return _MeetingSelectableText(
      data,
      style: style,
      minLines: minLines,
      maxLines: maxLines,
      textAlign: textAlign,
    );
  }
}

class MeetingMetaText extends StatelessWidget {
  final String data;
  final TextStyle? style;
  final int? minLines;
  final int? maxLines;
  final TextAlign? textAlign;

  const MeetingMetaText(
    this.data, {
    super.key,
    this.style,
    this.minLines,
    this.maxLines,
    this.textAlign,
  });

  @override
  Widget build(BuildContext context) {
    return _MeetingSelectableText(
      data,
      style: style,
      minLines: minLines,
      maxLines: maxLines,
      textAlign: textAlign,
    );
  }
}

class MeetingStatusText extends StatelessWidget {
  final String data;
  final TextStyle? style;
  final int? minLines;
  final int? maxLines;
  final TextAlign? textAlign;

  const MeetingStatusText(
    this.data, {
    super.key,
    this.style,
    this.minLines,
    this.maxLines,
    this.textAlign,
  });

  @override
  Widget build(BuildContext context) {
    return _MeetingSelectableText(
      data,
      style: style,
      minLines: minLines,
      maxLines: maxLines,
      textAlign: textAlign,
    );
  }
}

class MeetingErrorText extends StatelessWidget {
  final String data;
  final TextStyle? style;
  final int? minLines;
  final int? maxLines;
  final TextAlign? textAlign;

  const MeetingErrorText(
    this.data, {
    super.key,
    this.style,
    this.minLines,
    this.maxLines,
    this.textAlign,
  });

  @override
  Widget build(BuildContext context) {
    return _MeetingSelectableText(
      data,
      style: style,
      minLines: minLines,
      maxLines: maxLines,
      textAlign: textAlign,
    );
  }
}

class MeetingDebugText extends StatelessWidget {
  final String data;
  final TextStyle? style;
  final int? minLines;
  final int? maxLines;
  final TextAlign? textAlign;

  const MeetingDebugText(
    this.data, {
    super.key,
    this.style,
    this.minLines,
    this.maxLines,
    this.textAlign,
  });

  @override
  Widget build(BuildContext context) {
    return _MeetingSelectableText(
      data,
      style: style,
      minLines: minLines,
      maxLines: maxLines,
      textAlign: textAlign,
    );
  }
}
