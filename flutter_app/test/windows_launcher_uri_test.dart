import 'package:flutter_test/flutter_test.dart';
import 'package:smart_meeting_app/windows_launcher/launch_uri.dart';

void main() {
  group('parseLauncherBaseUri', () {
    test('falls back to localhost when input is empty', () {
      expect(
        parseLauncherBaseUri('').toString(),
        'http://127.0.0.1:8000',
      );
    });

    test('adds http scheme when missing', () {
      expect(
        parseLauncherBaseUri('10.0.0.8:8000').toString(),
        'http://10.0.0.8:8000',
      );
    });
  });

  group('buildLauncherTargetUri', () {
    final base = parseLauncherBaseUri('https://meeting.example.com');

    test('uses login page when target is empty', () {
      expect(
        buildLauncherTargetUri(baseUri: base, targetInput: '').toString(),
        'https://meeting.example.com/accounts/login',
      );
    });

    test('resolves relative meeting path against base url', () {
      expect(
        buildLauncherTargetUri(
          baseUri: base,
          targetInput: 'm/demo-share?autojoin=1',
        ).toString(),
        'https://meeting.example.com/m/demo-share?autojoin=1',
      );
    });

    test('keeps absolute target url', () {
      expect(
        buildLauncherTargetUri(
          baseUri: base,
          targetInput: 'https://other.example.com/meetings/12?autojoin=1',
        ).toString(),
        'https://other.example.com/meetings/12?autojoin=1',
      );
    });
  });

  group('canOpenInEmbeddedWebView', () {
    test('accepts http and https urls', () {
      expect(
        canOpenInEmbeddedWebView(Uri.parse('http://127.0.0.1:8000/dashboard')),
        isTrue,
      );
      expect(
        canOpenInEmbeddedWebView(Uri.parse('https://meeting.example.com/m/demo')),
        isTrue,
      );
    });

    test('rejects non-web schemes', () {
      expect(
        canOpenInEmbeddedWebView(Uri.parse('mailto:test@example.com')),
        isFalse,
      );
      expect(
        canOpenInEmbeddedWebView(Uri.parse('file:///C:/tmp/index.html')),
        isFalse,
      );
    });
  });

  group('normalizeDesktopTargetInput', () {
    test('defaults to login route when input is empty', () {
      expect(normalizeDesktopTargetInput(''), '/accounts/login');
    });

    test('treats plain meeting code as share route', () {
      expect(normalizeDesktopTargetInput('demo-share'), '/m/demo-share');
    });

    test('keeps explicit relative route with slash', () {
      expect(
        normalizeDesktopTargetInput('meetings/12?autojoin=1'),
        '/meetings/12?autojoin=1',
      );
    });

    test('keeps absolute url unchanged', () {
      expect(
        normalizeDesktopTargetInput('https://meeting.example.com/dashboard'),
        'https://meeting.example.com/dashboard',
      );
    });
  });
}
