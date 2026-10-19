import 'dart:convert';

String crlf(String s) => s.replaceAll('\r\n', '\n').replaceAll('\n', '\r\n');

// windows-1254: "Merhaba şğüıöç İĞŞ"
final _w1254 = <int>[
  ...ascii.encode('Merhaba '),
  0xFE, 0xF0, 0xFC, 0xFD, 0xF6, 0xE7, 0x20, 0xDD, 0xD0, 0xDE, //
];

/// A realistic Turkish mail: encoded names and subject, a windows-1254 plain
/// part, an iso-8859-9 HTML part with an inline `cid:` logo, an RFC 2231 PDF
/// attachment and a forwarded message.
final turkishMail = crlf(
  '''From: =?UTF-8?B?${base64.encode(utf8.encode('Şirin Ağaç'))}?= <sirin@example.test>
To: "Doe, Jane" <jane@example.test>, bob@example.test
Cc: cc@example.test
Reply-To: reply@example.test
Subject: =?UTF-8?Q?T=C3=BCrk=C3=A7e_konu?=
Date: Mon, 6 Oct 2025 10:00:00 +0300
Message-ID: <abc.123@example.test>
In-Reply-To: <prev@example.test>
References: <root@example.test> <prev@example.test>
List-Unsubscribe: <mailto:u@example.test>, <https://example.test/u>
List-Unsubscribe-Post: List-Unsubscribe=One-Click
Disposition-Notification-To: sirin@example.test
Authentication-Results: mx.example.test; spf=pass smtp.mailfrom=example.test; dkim=fail header.d=example.test; dkim=pass header.d=other.test; dmarc=hardfail
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="MIX"

--MIX
Content-Type: multipart/alternative; boundary="ALT"

--ALT
Content-Type: text/plain; charset=windows-1254
Content-Transfer-Encoding: base64

${base64.encode(_w1254)}
--ALT
Content-Type: multipart/related; boundary="REL"

--REL
Content-Type: text/html; charset=iso-8859-9
Content-Transfer-Encoding: quoted-printable

<p>Merhaba =FE=F0=FD <img src=3D"cid:logo@x"> <img src=3D"https://t.example/p.gif" width=3D"1" height=3D"1"></p>
--REL
Content-Type: image/png; name="logo.png"
Content-Transfer-Encoding: base64
Content-ID: <logo@x>
Content-Disposition: inline; filename="logo.png"

iVBORw0KGgo=
--REL--
--ALT--
--MIX
Content-Type: application/pdf; name*=UTF-8''rapor%20%C5%9Fubat.pdf
Content-Disposition: attachment; filename*=UTF-8''rapor%20%C5%9Fubat.pdf
Content-Transfer-Encoding: base64

JVBERi0xLjQK
--MIX
Content-Type: message/rfc822
Content-Disposition: attachment; filename="iletilen.eml"

From: a@example.test
Subject: inner
Content-Type: text/plain

inner body
--MIX--
''',
);

/// No MIME headers at all, as very old software still sends.
final bareTextMail = crlf('''From: old@example.test
To: me@example.test
Subject: duz metin
Date: Tue, 7 Oct 2025 08:00:00 +0000

Merhaba,
bu duz metin.
''');

final htmlOnlyMail = crlf('''From: News <news@example.test>
To: me@example.test
Subject: Bulten
Date: Tue, 7 Oct 2025 08:00:00 +0000
MIME-Version: 1.0
Content-Type: text/html; charset=utf-8

<html><head><style>p{color:red}</style></head><body><h1>Başlık</h1><p>Gövde <b>metni</b></p><script>x()</script></body></html>
''');

final unknownCharsetMail = crlf('''From: x@example.test
To: me@example.test
Subject: bozuk
Date: Tue, 7 Oct 2025 08:00:00 +0000
MIME-Version: 1.0
Content-Type: text/plain; charset=x-no-such-charset
Content-Transfer-Encoding: 8bit

selam dunya
''');

final smimeSignedMail = crlf('''From: a@example.test
To: me@example.test
Subject: imzali
Date: Tue, 7 Oct 2025 08:00:00 +0000
MIME-Version: 1.0
Content-Type: multipart/signed; protocol="application/pkcs7-signature"; micalg=sha-256; boundary="SIG"

--SIG
Content-Type: text/plain

imzali govde
--SIG
Content-Type: application/pkcs7-signature; name="smime.p7s"
Content-Transfer-Encoding: base64

MIAGCSqGSIb3DQEHAqCAMIA=
--SIG--
''');

final pgpInlineMail = crlf('''From: a@example.test
To: me@example.test
Subject: pgp
Date: Tue, 7 Oct 2025 08:00:00 +0000

-----BEGIN PGP SIGNED MESSAGE-----
Hash: SHA256

merhaba
-----BEGIN PGP SIGNATURE-----
abc
-----END PGP SIGNATURE-----
''');

/// An attachment-disposition image that the HTML shows through `cid:` (some
/// clients do this), plus one that nothing references.
final attachedCidMail = crlf('''From: a@example.test
To: me@example.test
Subject: cid
Date: Tue, 7 Oct 2025 08:00:00 +0000
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="M"

--M
Content-Type: text/html; charset=utf-8

<p><img src="cid:banner"></p>
--M
Content-Type: image/png; name="banner.png"
Content-ID: <banner>
Content-Disposition: attachment; filename="banner.png"
Content-Transfer-Encoding: base64

iVBORw0KGgo=
--M
Content-Type: image/png; name="foto.png"
Content-Disposition: attachment; filename="foto.png"
Content-Transfer-Encoding: base64

iVBORw0KGgo=
--M--
''');
