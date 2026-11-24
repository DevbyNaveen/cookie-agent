import 'package:cookie_mobile/runner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the QR code and the runner link both pair', () {
    final q = Pairing.parse('cookie://pair?u=${Uri.encodeComponent('https://cookie.example.com')}&t=abc123');
    expect(q?.base, 'https://cookie.example.com');
    expect(q?.token, 'abc123');
    expect(q?.encrypted, isTrue);
    final l = Pairing.parse('https://cookie.example.com/#token=abc123');
    expect(l?.base, 'https://cookie.example.com');
    expect(l?.token, 'abc123');
  });

  test('anything else is refused', () {
    expect(Pairing.parse('cookie://pair?u=ftp://x&t=1'), isNull);
    expect(Pairing.parse('https://example.com/'), isNull);
    expect(Pairing.parse('not a link'), isNull);
    expect(Pairing.parse('http://192.168.1.5:4519/#token=k')?.encrypted, isFalse);
  });
}
