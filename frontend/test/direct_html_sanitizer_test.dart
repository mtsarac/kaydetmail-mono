import 'package:flutter_test/flutter_test.dart';
import 'package:kaydetmail/services/direct/html_sanitizer.dart';

// Mirrors backend/tests/MailClient.Tests/MailBodySecurityTests.cs: a message
// must be made safe in the same way whichever way its account connects.
void main() {
  SanitizedHtml sanitize(
    String raw, {
    bool allowRemoteImages = false,
    Map<String, String> cids = const {},
  }) => MailHtmlSanitizer.sanitize(
    raw,
    allowRemoteImages: allowRemoteImages,
    cidImages: cids,
  );

  group('removes active content', () {
    test('scripts, frames, objects, forms and event handlers', () {
      final html = sanitize(
        '<p>ok</p><script>alert(1)</script>'
        '<iframe src="https://evil.test"></iframe><object data="x"></object>'
        '<embed src="x"><div onclick="alert(1)">tıkla</div>'
        '<form action="steal"><input/></form>',
      ).html.toLowerCase();
      expect(html, contains('ok'));
      for (final bad in [
        '<script',
        '<iframe',
        '<object',
        '<embed',
        'onclick',
        '<form',
        '<input',
        'alert(1)',
      ]) {
        expect(html, isNot(contains(bad)), reason: bad);
      }
      expect(html, contains('tıkla'));
    });

    for (final href in [
      'javascript:alert(1)',
      'file:///etc/passwd',
      'vbscript:msg',
      'data:text/html;base64,PHNjcmlwdD4=',
      ' JaVa\nScRiPt:alert(1)',
      'java\tscript:alert(1)',
    ]) {
      test('drops the scheme of ${href.replaceAll('\n', r'\n')}', () {
        final html = sanitize('<a href="$href">tıkla</a>').html.toLowerCase();
        expect(html, isNot(contains('javascript')));
        expect(html, isNot(contains('vbscript')));
        expect(html, isNot(contains('file:')));
        expect(html, isNot(contains('data:')));
        expect(html, contains('tıkla'));
      });
    }

    test('removes svg, math, video, comments and the style attribute', () {
      final html = sanitize(
        '<svg><script>x</script></svg><math></math><video src="https://v.test"></video>'
        '<!-- <b>hidden</b> --><div style="background:url(https://track.test/px.png)">x</div>'
        '<style>p{background:url(https://t.test)}</style>',
      );
      expect(html.html, isNot(contains('<svg')));
      expect(html.html, isNot(contains('video')));
      expect(html.html, isNot(contains('hidden')));
      expect(html.html, isNot(contains('style')));
      expect(html.html, isNot(contains('url(')));
      expect(html.hasRemoteContent, isFalse);
    });

    test('keeps formatting the app can show', () {
      final html = sanitize(
        '<table><tr><td colspan="2"><b>kalın</b> <i>eğik</i></td></tr></table>'
        '<ul><li>bir</li></ul><blockquote>alıntı</blockquote>',
      ).html;
      expect(html, contains('<table>'));
      expect(html, contains('colspan="2"'));
      expect(html, contains('<b>kalın</b>'));
      expect(html, contains('<ul>'));
      expect(html, contains('<blockquote>'));
    });

    test('empty input gives an empty result', () {
      expect(sanitize('').html, isEmpty);
      expect(sanitize('   ').hasRemoteContent, isFalse);
      expect(MailHtmlSanitizer.sanitize(null).html, isEmpty);
    });
  });

  group('remote content', () {
    test('a remote image is detected and not loaded', () {
      final r = sanitize(
        '<p>merhaba</p><img src="https://tracker.example/pixel.png">',
      );
      expect(r.hasRemoteContent, isTrue);
      expect(r.remoteHosts, contains('tracker.example'));
      expect(r.remoteImageHosts, ['tracker.example']);
      expect(r.html, isNot(contains(' src="https://')));
      expect(r.html, contains('data-remote-src'));
    });

    test('protocol-relative images count as remote', () {
      final r = sanitize('<img src="//tracker.example/pixel.png">');
      expect(r.hasRemoteContent, isTrue);
      expect(r.remoteHosts, contains('tracker.example'));
    });

    test('protocol-relative src and href are neutralised', () {
      final r = sanitize('<a href="//bad.example/landing">yönlendir</a>');
      expect(r.html, contains('data-remote-href="//bad.example/landing"'));
      expect(r.html, isNot(contains(' href="//')));
    });

    test('links are kept for the app to restore, like the backend does', () {
      final r = sanitize('<a href="https://site.example/x">git</a>');
      expect(r.html, contains('data-remote-href="https://site.example/x"'));
      expect(r.hasRemoteContent, isTrue);
    });

    test('mailto and relative links are not remote', () {
      final r = sanitize(
        '<a href="mailto:a@b.test">yaz</a><a href="#top">üst</a>',
      );
      expect(r.hasRemoteContent, isFalse);
      expect(r.html, contains('href="mailto:a@b.test"'));
      expect(r.html, contains('href="#top"'));
    });

    test('allowed remote images load, scripts and handlers still go', () {
      final r = sanitize(
        '<script>alert(1)</script>'
        '<img src="https://images.example/photo.jpg" onerror="alert(2)">'
        '<a href="javascript:alert(3)">x</a>',
        allowRemoteImages: true,
      );
      expect(r.html, contains('src="https://images.example/photo.jpg"'));
      expect(r.html.toLowerCase(), isNot(contains('script')));
      expect(r.html, isNot(contains('onerror')));
      expect(r.html, isNot(contains('javascript:')));
      expect(r.remoteImagesAllowed, isTrue);
      expect(r.remoteImageHosts, contains('images.example'));
    });

    test('allowed protocol-relative images are upgraded to https', () {
      final r = sanitize(
        '<img src="//images.example/a.png">',
        allowRemoteImages: true,
      );
      expect(r.html, contains('src="https://images.example/a.png"'));
    });
  });

  group('tracking pixels', () {
    const photo = '<img src="https://images.example/photo.jpg" width="600">';
    for (final pixel in [
      '<img src="https://t.example/o.gif?u=1&amp;m=2" width="1" height="1">',
      '<img src="https://t.example/o.gif" style="display: none">',
      '<img src="https://t.example/o.gif" style="width:0px;height:0px">',
      '<img src="https://t.example/o.gif" style="visibility:hidden">',
    ]) {
      test('stay blocked even when remote images are allowed: $pixel', () {
        final r = sanitize('$photo$pixel', allowRemoteImages: true);
        expect(r.trackingPixelHosts, ['t.example']);
        expect(r.html, contains('src="https://images.example/photo.jpg"'));
        expect(r.html, isNot(contains(' src="https://t.example')));
        expect(r.html, contains('data-remote-src="https://t.example'));
      });
    }

    for (final image in [
      '<img src="https://images.example/banner.png" width="600" height="2">',
      '<img src="cid:LOGO" width="1" height="1">',
    ]) {
      test('regular images are not tracking: $image', () {
        expect(sanitize(image).trackingPixelHosts, isEmpty);
      });
    }
  });

  group('inline images', () {
    const png = 'data:image/png;base64,iVBORw0KGgo=';

    test('a cid image becomes a data image made from the inline part', () {
      final r = sanitize('<img src="cid:LOGO123">', cids: {'logo123': png});
      expect(r.html, contains('src="$png"'));
      expect(r.html.toLowerCase(), isNot(contains('cid:')));
      expect(r.hasRemoteContent, isFalse);
    });

    test('angle brackets in the reference are tolerated', () {
      final r = sanitize('<img src="cid:<logo123>">', cids: {'logo123': png});
      expect(r.html, contains(png));
    });

    test('an unknown cid leaves no source behind', () {
      final r = sanitize('<img src="cid:nope">', cids: {'logo123': png});
      expect(r.html, isNot(contains('src=')));
    });

    test('a data URI written by the sender is never trusted', () {
      final r = sanitize('<img src="data:image/svg+xml;base64,PHN2Zz4=">');
      expect(r.html, isNot(contains('data:')));
      expect(r.html, isNot(contains('src=')));
    });

    test('a cid reference outside an image is dropped', () {
      final r = sanitize('<a href="cid:logo">x</a>', cids: {'logo': png});
      expect(r.html, isNot(contains(png)));
    });
  });
}
