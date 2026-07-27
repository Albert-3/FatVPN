import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fatvpn_app/services/vless_config_parser.dart';
import 'package:fatvpn_app/utils/country_flag.dart';

/// Encodes lines the way Remnawave serves a subscription: one link per line,
/// the whole blob base64'd.
String subscription(List<String> lines) =>
    base64.encode(utf8.encode(lines.join('\n')));

void main() {
  group('parseConfigEntries', () {
    test('pulls host, real inbound port and decoded remark off each link', () {
      final entries = parseConfigEntries(subscription([
        'vless://uuid@de1.example.com:8443?security=tls#%F0%9F%87%A9%F0%9F%87%AA%20DE-1',
      ]));

      expect(entries, hasLength(1));
      expect(entries.single.host, 'de1.example.com');
      // The client-facing port, not the management port /servers reports.
      expect(entries.single.port, 8443);
      expect(entries.single.tag, '🇩🇪 DE-1');
    });

    test('keeps hysteria2 links spliced in by the BFF augmenter', () {
      // Mirrors SubscriptionAugmenter.AppendHysteriaHosts output: a dedicated
      // client-facing domain that matches no Remnawave node address, which is
      // exactly what the old address-keyed intersection dropped.
      final entries = parseConfigEntries(subscription([
        'vless://uuid@de1.example.com:443#DE',
        'hysteria2://uuid@h2-fr.arpozan.cloud:443?sni=h2-fr.arpozan.cloud&alpn=h3'
            '#%F0%9F%87%AB%F0%9F%87%B7%20%D0%A4%D1%80%D0%B0%D0%BD%D1%86%D0%B8%D1%8F%20%E2%80%A2%20H2',
      ]));

      expect(entries.map((e) => e.host),
          ['de1.example.com', 'h2-fr.arpozan.cloud']);
      expect(entries.last.tag, '🇫🇷 Франция • H2');
      expect(countryCodeFromFlagEmoji(entries.last.tag), 'FR');
    });

    test('distinguishes two inbounds published on the same host', () {
      // An address lookup can't tell these apart and always returns the first,
      // so each entry has to carry its own link.
      final entries = parseConfigEntries(subscription([
        'vless://uuid@same.example.com:443#A',
        'hysteria2://uuid@same.example.com:8443#B',
      ]));

      expect(entries.map((e) => e.uri).toSet(), hasLength(2));
      expect(entries.map((e) => e.port), [443, 8443]);
    });

    test('skips unsupported schemes and junk lines', () {
      final entries = parseConfigEntries(subscription([
        'vless://uuid@ok.example.com:443#OK',
        'not-a-link',
        '',
        'ftp://nope.example.com:21',
      ]));

      expect(entries.map((e) => e.host), ['ok.example.com']);
    });

    test('keeps XHTTP hosts, which are the shutdown-bypass ones', () {
      // Real shape of the panel's "🌍 Белые списки #1" host: an Xray XHTTP
      // inbound fronting a whitelisted address. sing-box has no XHTTP transport
      // and the plugin normalizes it onto `http`, so the connection may still
      // fail — but hiding the host costs the user the one server that survives
      // a mobile-internet shutdown, so it has to be offered.
      final entries = parseConfigEntries(subscription([
        'vless://uuid@81.222.127.189:443?type=xhttp&path=/api/v1/assets&mode=packet-up&security=tls#WL',
        'vless://uuid@95.85.224.3:8443?type=grpc&security=tls#EE',
      ]));

      expect(entries.map((e) => e.host), ['81.222.127.189', '95.85.224.3']);
    });

    test('returns empty on content that is not base64', () {
      expect(parseConfigEntries('«not base64»'), isEmpty);
    });

    test('falls back to the raw fragment when it is not valid escaping', () {
      final entries =
          parseConfigEntries(subscription(['vless://uuid@h.example.com:443#%zz']));

      expect(entries.single.tag, '%zz');
    });
  });

  group('countryCodeFromFlagEmoji', () {
    test('reads the code out of a leading flag', () {
      expect(countryCodeFromFlagEmoji('🇳🇱 Нидерланды'), 'NL');
    });

    test('finds a flag that is not at the start', () {
      expect(countryCodeFromFlagEmoji('H2 • 🇺🇸 США'), 'US');
    });

    test('returns null when there is no flag', () {
      expect(countryCodeFromFlagEmoji('DE-1'), isNull);
      expect(countryCodeFromFlagEmoji(''), isNull);
    });

    test('renders the globe for entries that belong to no country', () {
      // The bypass hosts ("🌍 Белые списки #1", "Авто 🔥 [GRPC]") land in this
      // bucket; showing "??" as a flag looked like a rendering fault.
      expect(countryCodeToFlagEmoji(unknownCountryCode), '🌍');
      expect(countryCodeToFlagEmoji('unknown'), '🌍');
      expect(countryLabel(unknownCountryCode, 'Особые'), 'Особые');
      expect(countryLabel('DE', 'Особые'), 'DE');
    });

    test('round-trips with countryCodeToFlagEmoji', () {
      for (final code in ['DE', 'FI', 'NL', 'EE', 'FR', 'US']) {
        expect(countryCodeFromFlagEmoji(countryCodeToFlagEmoji(code)), code);
      }
    });
  });
}
