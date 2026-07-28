package com.fatvpn.fatvpn_app.widget

/// The 2×2 tile.
///
/// Empty on purpose: it behaves exactly like [FatVpnWidgetProvider] — same
/// drawing, same power button, same broadcasts — and exists only so the widget
/// picker offers a second **size**. A provider's default placement comes from
/// its `appwidget-provider` XML (`targetCellWidth`/`Height` on API 31+,
/// `minWidth`/`minHeight` below), and there is one such XML per receiver, so a
/// second offered size means a second receiver. See res/xml/
/// fatvpn_widget_square_info.xml.
///
/// Which layout gets drawn is still decided by the size the tile actually ends
/// up at, not by which provider placed it: resize this one to four cells wide
/// and it becomes the wide card, exactly as the other provider would.
class FatVpnWidgetSquareProvider : FatVpnWidgetProvider()
