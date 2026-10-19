import 'package:flutter_test/flutter_test.dart';

import 'support/direct_rig.dart';

void main() {
  late DirectRig rig;
  tearDown(() => rig.dispose());

  test('a check reports only mail that arrived since the last look', () async {
    rig = DirectRig();
    rig.imap.add('INBOX', rigMail('old'), date: rig.clock.now);

    // The first look at an Inbox brings in old mail, which is not news.
    expect(await rig.gateway.checkForMail(), isEmpty);

    rig.imap.add(
      'INBOX',
      rigMail(
        'new',
        subject: 'Acil toplantı',
        from: 'Şirin <sirin@example.org>',
      ),
      date: rig.clock.now,
    );
    final incoming = await rig.gateway.checkForMail();
    expect(incoming.single.subject, 'Acil toplantı');
    expect(incoming.single.sender, 'Şirin');
    expect(incoming.single.folderType, 'Inbox');

    // The same mail is not announced twice.
    expect(await rig.gateway.checkForMail(), isEmpty);
  });
}
