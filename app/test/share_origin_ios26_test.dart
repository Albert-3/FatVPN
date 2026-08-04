// Regression test for the Send-logs button doing nothing on iOS 26.
//
// iOS 26 made `sharePositionOrigin` mandatory: `Share.shareXFiles` without it
// (or with a zero rect) throws `PlatformException(sharePositionOrigin:
// argument must be set)` where earlier iOS quietly presented the sheet. The
// throw lands in AppLogger's catch, whose only output is the log the user was
// trying to send — so on a device the button simply reads as dead (reported
// 2026-08-04). Every share now goes through [AppLogger.shareOriginOrFallback],
// pinned here to never hand the platform an absent or zero-sized anchor.

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:fatvpn_app/services/app_logger.dart';

void main() {
  test('no rect still yields a usable anchor', () {
    final rect = AppLogger.shareOriginOrFallback(null);
    expect(rect.isEmpty, isFalse,
        reason: 'iOS 26 throws on an absent/zero anchor and the share sheet '
            'never appears — the fallback must be a real rect');
  });

  test('a zero-sized rect is replaced, not passed through', () {
    final rect = AppLogger.shareOriginOrFallback(Rect.zero);
    expect(rect.isEmpty, isFalse,
        reason: 'a RenderBox measured mid-layout can hand back a zero rect, '
            'which iOS 26 rejects exactly like an absent one');
  });

  test('a real button rect is used as given', () {
    const requested = Rect.fromLTWH(40, 600, 120, 48);
    expect(AppLogger.shareOriginOrFallback(requested), requested,
        reason: 'the anchor exists so the iPad popover points at the button '
            'that was actually pressed');
  });
}
