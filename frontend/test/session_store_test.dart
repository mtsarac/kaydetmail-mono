import 'package:flutter_test/flutter_test.dart';
import 'package:kaydetmail/services/session_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('backend-only installs read exactly what they stored', () async {
    SharedPreferences.setMockInitialValues({
      'kaydet.session.emails': ['a@x.test', 'b@x.test'],
    });
    expect(await SessionStore.loadEmails(), ['a@x.test', 'b@x.test']);
    expect(await SessionStore.loadDirectAccounts(), isEmpty);
  });

  test('direct accounts follow backend ones and are found by email', () async {
    await SessionStore.addEmail('a@x.test');
    await SessionStore.saveDirectAccount('d-1', 'd@y.test');
    await SessionStore.saveDirectAccount('d-2', 'e@y.test');

    expect(await SessionStore.loadEmails(), [
      'a@x.test',
      'd@y.test',
      'e@y.test',
    ]);
    final entry = await SessionStore.loadDirectAccount('d@y.test');
    expect(entry?.id, 'd-1');
    expect(await SessionStore.loadDirectAccount('a@x.test'), isNull);
  });

  test('saving the same direct account twice does not duplicate it', () async {
    await SessionStore.saveDirectAccount('d-1', 'd@y.test');
    await SessionStore.saveDirectAccount('d-1', 'd@y.test');
    expect(await SessionStore.loadDirectAccounts(), hasLength(1));
  });

  test('removing one account leaves the others untouched', () async {
    await SessionStore.addEmail('a@x.test');
    await SessionStore.saveAccountId('a@x.test', 'acc-a');
    await SessionStore.saveDirectAccount('d-1', 'd@y.test');
    await SessionStore.saveDirectAccount('d-2', 'e@y.test');

    await SessionStore.removeEmail('d@y.test');
    expect(await SessionStore.loadEmails(), ['a@x.test', 'e@y.test']);
    expect(await SessionStore.loadAccountId('a@x.test'), 'acc-a');

    await SessionStore.removeEmail('a@x.test');
    expect(await SessionStore.loadEmails(), ['e@y.test']);
  });

  test('clear forgets both kinds of account', () async {
    await SessionStore.addEmail('a@x.test');
    await SessionStore.saveDirectAccount('d-1', 'd@y.test');
    await SessionStore.clear();
    expect(await SessionStore.loadEmails(), isEmpty);
  });

  test('a corrupt direct registry is ignored, not fatal', () async {
    SharedPreferences.setMockInitialValues({
      'kaydet.session.emails': ['a@x.test'],
      'kaydet.session.direct': 'not json',
    });
    expect(await SessionStore.loadEmails(), ['a@x.test']);
  });
}
