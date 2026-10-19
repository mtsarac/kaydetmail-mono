import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

/// A mail's HTML after sanitising, plus what it tried to load from outside.
class SanitizedHtml {
  const SanitizedHtml({
    required this.html,
    this.hasRemoteContent = false,
    this.remoteHosts = const [],
    this.remoteImageHosts = const [],
    this.trackingPixelHosts = const [],
    this.remoteImagesAllowed = false,
  });

  static const empty = SanitizedHtml(html: '');

  final String html;

  /// The original referenced something hosted elsewhere (links included).
  final bool hasRemoteContent;
  final List<String> remoteHosts;
  final List<String> remoteImageHosts;

  /// Hosts of images that look like tracking pixels (1×1, hidden). These
  /// stay blocked even when the user lets remote images load.
  final List<String> trackingPixelHosts;
  final bool remoteImagesAllowed;
}

/// Makes untrusted mail HTML safe to render, with the same rules as the
/// backend's `HtmlMailBodyRenderer` so a message looks and behaves the same
/// whichever way its account connects:
///
/// * only an allowlist of tags and attributes survives; scripts, frames,
///   forms, SVG, comments and every `style` attribute (the CSS `url()`
///   vector) are removed;
/// * links and sources keep only `http`, `https`, `mailto`, `tel` and
///   relative targets;
/// * anything absolute or protocol-relative that would load from outside is
///   moved to `data-remote-*` instead of being fetched, apart from images
///   when the user has allowed remote images — and tracking pixels never load;
/// * `cid:` images become `data:` images made from the message's own inline
///   parts, never from anything the sender wrote.
class MailHtmlSanitizer {
  const MailHtmlSanitizer._();

  static const _allowedTags = {
    'a', 'abbr', 'acronym', 'address', 'article', 'aside', 'b', 'bdi', 'bdo',
    'big', 'blockquote', 'body', 'br', 'caption', 'center', 'cite', 'code',
    'col', 'colgroup', 'dd', 'del', 'details', 'dfn', 'dir', 'div', 'dl',
    'dt', 'em', 'figcaption', 'figure', 'font', 'footer', 'h1', 'h2', 'h3',
    'h4', 'h5', 'h6', 'header', 'hr', 'i', 'img', 'ins', 'kbd', 'li', 'main',
    'mark', 'menu', 'nav', 'ol', 'p', 'pre', 'q', 's', 'samp', 'section',
    'small', 'span', 'strike', 'strong', 'sub', 'summary', 'sup', 'table',
    'tbody', 'td', 'tfoot', 'th', 'thead', 'time', 'tr', 'tt', 'u', 'ul',
    'var', 'wbr', //
  };

  /// Removed together with everything inside them.
  static const _dropWithContent = {
    'script', 'style', 'iframe', 'frame', 'frameset', 'object', 'embed',
    'applet', 'noscript', 'template', 'svg', 'math', 'canvas', 'audio',
    'video', 'source', 'track', 'title', 'head', 'textarea', 'select',
    'option', 'noembed', 'noframes', 'link', 'meta', 'base', 'xml', //
  };

  static const _allowedAttributes = {
    'abbr', 'align', 'alt', 'axis', 'bgcolor', 'border', 'cellpadding',
    'cellspacing', 'char', 'charoff', 'color', 'cols', 'colspan', 'compact',
    'dir', 'face', 'headers', 'height', 'href', 'hreflang', 'hspace', 'lang',
    'name', 'nowrap', 'rel', 'rowspan', 'rules', 'scope', 'shape', 'size',
    'span', 'src', 'srcset', 'start', 'summary', 'title', 'type', 'valign',
    'vspace', 'width', 'background', //
  };

  static const _urlAttributes = {'href', 'src', 'srcset', 'background'};
  static const _allowedSchemes = {'http', 'https', 'mailto', 'tel', 'cid'};

  /// Sanitises [rawHtml]. [cidImages] maps lower-cased Content-IDs (without
  /// angle brackets) to ready `data:` URIs for the message's inline images.
  static SanitizedHtml sanitize(
    String? rawHtml, {
    bool allowRemoteImages = false,
    Map<String, String> cidImages = const {},
  }) {
    if (rawHtml == null || rawHtml.trim().isEmpty) {
      return SanitizedHtml(html: '', remoteImagesAllowed: allowRemoteImages);
    }
    final document = html_parser.parse(rawHtml);
    final body = document.body;
    if (body == null) {
      return SanitizedHtml(html: '', remoteImagesAllowed: allowRemoteImages);
    }

    // Tracking detection reads `style`, so it runs before sanitising.
    final trackingSources = _trackingPixelSources(body);

    _cleanChildren(body);
    _resolveCids(body, cidImages);

    final remoteHosts = _remoteHosts(body);
    final remoteImageHosts = _remoteImageHosts(body);
    _neutralizeRemote(body, allowRemoteImages, trackingSources);

    return SanitizedHtml(
      html: body.innerHtml,
      hasRemoteContent: remoteHosts.isNotEmpty,
      remoteHosts: _distinct(remoteHosts),
      remoteImageHosts: _distinct(remoteImageHosts),
      trackingPixelHosts: _distinct([
        for (final source in trackingSources) ?_remoteHost(source),
      ]),
      remoteImagesAllowed: allowRemoteImages,
    );
  }

  // --- Cleaning ------------------------------------------------------------

  static void _cleanChildren(Node parent) {
    for (final child in parent.nodes.toList()) {
      if (child is Comment) {
        child.remove();
      } else if (child is Element) {
        _cleanElement(child);
      } else if (child is! Text) {
        child.remove();
      }
    }
  }

  static void _cleanElement(Element element) {
    final name = element.localName ?? '';
    if (_dropWithContent.contains(name)) {
      element.remove();
      return;
    }
    if (!_allowedTags.contains(name)) {
      // Unknown or unwanted wrapper (form, button, input, …): keep its
      // content, lose the tag.
      _cleanChildren(element);
      final parent = element.parent;
      if (parent != null) {
        final index = parent.nodes.indexOf(element);
        final inner = element.nodes.toList();
        element.remove();
        for (var i = 0; i < inner.length; i++) {
          parent.nodes.insert(index + i, inner[i]);
        }
      } else {
        element.remove();
      }
      return;
    }
    for (final key in element.attributes.keys.toList()) {
      final attribute = key.toString();
      if (!_allowedAttributes.contains(attribute)) {
        element.attributes.remove(key);
        continue;
      }
      if (_urlAttributes.contains(attribute) &&
          !_schemeAllowed(element.attributes[key] ?? '', attribute)) {
        element.attributes.remove(key);
      }
    }
    if (name == 'a') element.attributes['rel'] = 'noopener noreferrer';
    _cleanChildren(element);
  }

  /// A value is acceptable when it has no scheme (relative, `#fragment`,
  /// `//host`) or one on the allowlist. Control characters and spaces are
  /// ignored first, as browsers do (`java\nscript:`).
  static bool _schemeAllowed(String value, String attribute) {
    if (attribute == 'srcset') {
      return value
          .split(',')
          .map((c) => c.trim().split(RegExp(r'\s+')).first)
          .where((c) => c.isNotEmpty)
          .every((c) => _schemeAllowed(c, 'src'));
    }
    final compact = value.replaceAll(RegExp(r'[\u0000- \u007f-\u009f]'), '');
    final match = RegExp(r'^([A-Za-z][A-Za-z0-9+.\-]*):').firstMatch(compact);
    if (match == null) return true;
    return _allowedSchemes.contains(match.group(1)!.toLowerCase());
  }

  // --- Inline images ----------------------------------------------------------

  static void _resolveCids(Element body, Map<String, String> cidImages) {
    for (final element in body.querySelectorAll('[src], [background]')) {
      for (final attribute in const ['src', 'background']) {
        final value = element.attributes[attribute];
        if (value == null) continue;
        final compact = value.trim();
        if (!compact.toLowerCase().startsWith('cid:')) continue;
        final id = compact
            .substring(4)
            .replaceAll(RegExp(r'^<|>$'), '')
            .toLowerCase();
        final uri = cidImages[id];
        if (uri != null && element.localName == 'img' && attribute == 'src') {
          element.attributes[attribute] = uri;
        } else {
          element.attributes.remove(attribute);
        }
      }
    }
  }

  // --- Remote content -------------------------------------------------------------

  static void _neutralizeRemote(
    Element body,
    bool allowRemoteImages,
    Set<String> trackingSources,
  ) {
    for (final element in body.querySelectorAll(
      '[src], [srcset], [href], [background]',
    )) {
      for (final attribute in const ['src', 'srcset', 'href', 'background']) {
        final value = element.attributes[attribute];
        if (value == null || value.trim().isEmpty) continue;
        if (!_isRemote(value, attribute)) continue;
        if (allowRemoteImages &&
            element.localName == 'img' &&
            attribute == 'src' &&
            !trackingSources.contains(value)) {
          if (value.startsWith('//')) {
            element.attributes[attribute] = 'https:$value';
          }
          continue;
        }
        element.attributes['data-remote-$attribute'] = value;
        element.attributes.remove(attribute);
      }
    }
  }

  static bool _isRemote(String value, String attribute) {
    if (attribute == 'srcset') {
      return value
          .split(',')
          .map((c) => c.trim().split(RegExp(r'\s+')).first)
          .any((c) => _isRemote(c, 'src'));
    }
    final trimmed = value.trim();
    if (trimmed.startsWith('//')) return true;
    final uri = Uri.tryParse(trimmed);
    return uri != null &&
        uri.hasScheme &&
        (uri.scheme == 'http' || uri.scheme == 'https');
  }

  static List<String> _remoteHosts(Element body) {
    final hosts = <String>[];
    for (final element in body.querySelectorAll(
      'img, [src], [href], [background]',
    )) {
      final source =
          element.attributes['src'] ??
          element.attributes['href'] ??
          element.attributes['background'];
      final host = _remoteHost(source);
      if (host != null) hosts.add(host);
    }
    return hosts;
  }

  static List<String> _remoteImageHosts(Element body) => [
    for (final image in body.querySelectorAll('img[src]'))
      ?_remoteHost(image.attributes['src']),
  ];

  static String? _remoteHost(String? source) {
    if (source == null || source.trim().isEmpty) return null;
    var value = source.trim();
    if (value.startsWith('//')) value = 'https:$value';
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !uri.hasScheme ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      return null;
    }
    return uri.host;
  }

  // --- Tracking pixels -------------------------------------------------------------

  static Set<String> _trackingPixelSources(Element body) => {
    for (final image in body.querySelectorAll('img[src]'))
      if (_isTrackingPixel(image) &&
          _remoteHost(image.attributes['src']) != null)
        image.attributes['src']!,
  };

  static bool _isTrackingPixel(Element image) {
    if (_isTinyDimension(image.attributes['width']) ||
        _isTinyDimension(image.attributes['height'])) {
      return true;
    }
    final style = (image.attributes['style'] ?? '')
        .replaceAll(' ', '')
        .toLowerCase();
    for (final declaration in style.split(';')) {
      final parts = declaration.split(':');
      if (parts.length < 2) continue;
      final property = parts.first;
      final value = parts.sublist(1).join(':');
      if (property == 'display' && value.startsWith('none')) return true;
      if (property == 'visibility' && value.startsWith('hidden')) return true;
      if (const {
            'width',
            'height',
            'max-width',
            'max-height',
          }.contains(property) &&
          _isTinyDimension(value)) {
        return true;
      }
    }
    return false;
  }

  static bool _isTinyDimension(String? value) {
    if (value == null || value.trim().isEmpty) return false;
    var number = value.trim().toLowerCase().replaceAll('!important', '');
    if (number.endsWith('px')) number = number.substring(0, number.length - 2);
    final size = double.tryParse(number);
    return size != null && size <= 1;
  }

  static List<String> _distinct(Iterable<String> hosts) {
    final seen = <String>{};
    return [
      for (final host in hosts)
        if (seen.add(host.toLowerCase())) host,
    ];
  }
}
