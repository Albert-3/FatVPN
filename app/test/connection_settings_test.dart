import 'package:flutter_test/flutter_test.dart';

import 'package:fatvpn_app/services/connection_settings_controller.dart';

void main() {
  group('ConnectionSettingsController.isValidBypassHost', () {
    test('accepts plain domains', () {
      expect(ConnectionSettingsController.isValidBypassHost('example.com'), isTrue);
      expect(ConnectionSettingsController.isValidBypassHost('sub.example.co.uk'), isTrue);
    });

    test('accepts wildcard / leading-dot domains', () {
      expect(ConnectionSettingsController.isValidBypassHost('*.ru'), isTrue);
      expect(ConnectionSettingsController.isValidBypassHost('.example.com'), isTrue);
    });

    test('accepts bare IPs and CIDRs (v4 and v6)', () {
      expect(ConnectionSettingsController.isValidBypassHost('8.8.8.8'), isTrue);
      expect(ConnectionSettingsController.isValidBypassHost('10.0.0.0/8'), isTrue);
      expect(ConnectionSettingsController.isValidBypassHost('2001:4860:4860::8888'), isTrue);
      expect(ConnectionSettingsController.isValidBypassHost('fc00::/7'), isTrue);
    });

    test('rejects junk, empty, and out-of-range masks', () {
      expect(ConnectionSettingsController.isValidBypassHost(''), isFalse);
      expect(ConnectionSettingsController.isValidBypassHost('   '), isFalse);
      expect(ConnectionSettingsController.isValidBypassHost('not a domain'), isFalse);
      expect(ConnectionSettingsController.isValidBypassHost('http://example.com'), isFalse);
      expect(ConnectionSettingsController.isValidBypassHost('10.0.0.0/33'), isFalse);
      expect(ConnectionSettingsController.isValidBypassHost('192.168.0.0/'), isFalse);
    });
  });
}
