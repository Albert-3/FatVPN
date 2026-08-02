/// The domain list behind the "Tracker protection" switch.
///
/// Shipped with the app rather than downloaded, and matched inside the tunnel
/// as sing-box `domain_suffix` → `block` route rules (see
/// `SingboxRouteRulesBuilder`, under `RouteOptions.blockAdvertisements`).
///
/// ## Why it is named for tracking
///
/// The switch was asked for as an ad blocker and it does block ads. It is
/// presented as tracker protection because Google Play's Device and Network
/// Abuse policy bars apps that interfere with the serving of third-party ads —
/// the rule standalone blockers have been removed under — while VPNs that
/// filter for privacy are accepted. The name is not a euphemism: most of the
/// list below is analytics, attribution and audience data rather than creative
/// serving. The subtitle in the UI still says ad networks are blocked, because
/// the user is owed the truth about what will stop loading; the framing is for
/// the store listing, not for them. See `docs/store-compliance.md` §3.1a.
///
/// ## Why not a remote rule-set
///
/// sing-box can fetch a rule-set over the network (`route.rule_set` with
/// `type: remote`), and the plugin already models it — but a remote rule-set is
/// a *start-time dependency of the router*: the core wants it in hand before it
/// will bring the tunnel up. Two things make that unacceptable here.
///
/// * The download happens before there is a tunnel, from a host the user's
///   network may well be the reason they installed a VPN for. A failed fetch
///   would mean "switching ad blocking on stopped the VPN from connecting".
/// * On iOS the on-disk cache is deliberately off — `AdvancedOptions.memoryLimit`
///   disables `experimental.cache_file` inside a network extension capped at
///   ~50 MB — so the list would be re-downloaded on *every single* connect,
///   paying that risk over and over.
///
/// A list compiled into the app has neither problem: it costs nothing at
/// start-up, works with no network at all, and behaves identically on both
/// platforms. The price is that it only moves when the app does, which is why
/// [version] exists — bump it whenever the list changes so a support report can
/// say which list a given build was running.
///
/// ## What is in it, and what is deliberately not
///
/// Entries are ad exchanges, mobile ad SDKs, and analytics/attribution
/// endpoints. Kept out on purpose, because blocking them breaks the app rather
/// than the advertising:
///
/// * shared infrastructure that also serves content — `googleapis.com`,
///   `gstatic.com`, `fbcdn.net`, CDNs;
/// * sign-in and deep-link plumbing — `graph.facebook.com`,
///   `connect.facebook.net`, `branch.io`;
/// * crash reporting — Crashlytics, Sentry, Bugsnag: a tracker in the abstract,
///   but not what the user switched this on for, and losing it costs the
///   developer of every app on the phone;
/// * anything at the apex of a domain the user still needs. `mail.ru` is not
///   here; `ad.mail.ru` and `top.mail.ru` are.
///
/// One known trade-off is in: `googletagmanager.com`. Every mainstream ad list
/// blocks it, and a handful of sites load real content through it. That is the
/// kind of breakage the switch itself is the answer to.
///
/// Matched by suffix, so `doubleclick.net` also covers
/// `googleads.g.doubleclick.net`. Never add an entry that is the entry domain
/// of a service the user visits.
abstract final class TrackerBlockList {
  /// Bumped on every edit to [domainSuffixes]. Surfaced nowhere in the UI; it
  /// exists so a log or a support bundle can pin down which list ran.
  static const int version = 1;

  /// Domain suffixes blocked while the switch is on.
  static const List<String> domainSuffixes = <String>[
    // ── Google ad stack ──────────────────────────────────────────────────
    'doubleclick.net',
    'googlesyndication.com',
    'googleadservices.com',
    'googletagservices.com',
    'googletagmanager.com',
    'google-analytics.com',
    'analytics.google.com',
    'adservice.google.com',
    'app-measurement.com',
    'admob.com',
    '2mdn.net',

    // ── Amazon / Microsoft / Apple-adjacent ──────────────────────────────
    'amazon-adsystem.com',
    'assoc-amazon.com',
    'bat.bing.com',
    'clarity.ms',
    'ads.microsoft.com',
    'adnxs.com',
    'adnxs-simple.com',

    // ── Meta ─────────────────────────────────────────────────────────────
    'an.facebook.com',
    'ads.facebook.com',
    'pixel.facebook.com',
    'atdmt.com',

    // ── TikTok / ByteDance ───────────────────────────────────────────────
    'ads.tiktok.com',
    'analytics.tiktok.com',
    'pangle.io',
    'pangleglobal.com',

    // ── X / Twitter ──────────────────────────────────────────────────────
    'ads-twitter.com',
    'ads-api.twitter.com',
    'analytics.twitter.com',

    // ── Mobile ad SDKs ───────────────────────────────────────────────────
    'applovin.com',
    'applvn.com',
    'adcolony.com',
    'unityads.unity3d.com',
    'unityads.unitychina.cn',
    'ironsrc.com',
    'ironsource.mobi',
    'supersonicads.com',
    'vungle.com',
    'vungle.io',
    'chartboost.com',
    'chartboo.st',
    'mintegral.com',
    'mtgglobals.com',
    'rayjump.com',
    'inmobi.com',
    'inmobicdn.net',
    'tapjoy.com',
    'tapjoyads.com',
    'fyber.com',
    'inner-active.mobi',
    'smaato.com',
    'smaato.net',
    'startappservice.com',
    'startappexchange.com',
    'mopub.com',
    'adtiming.com',
    'appodeal.com',
    'appodealx.com',
    'bidmachine.io',
    'liftoff.io',
    'digitalturbine.com',
    'mobfox.com',
    'tappx.com',
    'moloco.com',
    'adsmoloco.com',
    'kidoz.net',
    'yandexadexchange.net',

    // ── Attribution / product analytics ──────────────────────────────────
    'appsflyer.com',
    'adjust.com',
    'adjust.io',
    'kochava.com',
    'singular.net',
    'tenjin.io',
    'flurry.com',
    'localytics.com',
    'leanplum.com',
    'amplitude.com',
    'mixpanel.com',
    'heapanalytics.com',
    'hotjar.com',
    'hotjar.io',
    'fullstory.com',
    'mouseflow.com',
    'smartlook.com',
    'crazyegg.com',
    'luckyorange.com',
    'inspectlet.com',
    'clicktale.net',
    'sessioncam.com',
    'quantserve.com',
    'quantcount.com',
    'scorecardresearch.com',
    'imrworldwide.com',
    'chartbeat.com',
    'chartbeat.net',
    'statcounter.com',
    'histats.com',

    // ── Adobe ────────────────────────────────────────────────────────────
    'demdex.net',
    'omtrdc.net',
    '2o7.net',
    'everesttech.net',
    'adobedtm.com',

    // ── Exchanges, SSPs, DSPs ────────────────────────────────────────────
    'pubmatic.com',
    'rubiconproject.com',
    'openx.net',
    'openx.com',
    'adsrvr.org',
    'casalemedia.com',
    'smartadserver.com',
    'sascdn.com',
    'bidswitch.net',
    '3lift.com',
    'triplelift.com',
    'sharethrough.com',
    'teads.tv',
    'teads.com',
    'spotxchange.com',
    'spotx.tv',
    'yieldmo.com',
    'indexww.com',
    'districtm.io',
    'rlcdn.com',
    'crwdcntrl.net',
    'lijit.com',
    'gumgum.com',
    'media.net',
    'sonobi.com',
    'conversantmedia.com',
    'adform.net',
    'adformdsp.net',
    'improvedigital.com',
    'yieldlab.net',
    'adition.com',
    'theadex.com',
    'adscale.de',
    'pubnative.net',
    'smadex.com',
    'onaudience.com',
    'id5-sync.com',
    'adroll.com',
    'criteo.com',
    'criteo.net',
    'rtbhouse.com',
    'sociomantic.com',
    'exponential.com',
    'tremorhub.com',
    'telaria.com',
    'zedo.com',
    'bidvertiser.com',
    'infolinks.com',
    'chitika.com',
    'adblade.com',
    'adsnative.com',
    'undertone.com',

    // ── Verification / audience data ─────────────────────────────────────
    'adsafeprotected.com',
    'doubleverify.com',
    'moatads.com',
    'serving-sys.com',
    'flashtalking.com',
    'mathtag.com',
    'bluekai.com',
    'agkn.com',
    'eyeota.net',
    'tapad.com',
    'netmng.com',
    'adhigh.net',
    'addthis.com',
    'sharethis.com',
    'po.st',

    // ── Content recommendation ("you may also like") ─────────────────────
    'taboola.com',
    'taboolasyndication.com',
    'outbrain.com',
    'zemanta.com',
    'revcontent.com',
    'mgid.com',
    'dable.io',
    'plista.com',
    'ligatus.com',

    // ── Popunder / aggressive networks ───────────────────────────────────
    'propellerads.com',
    'popads.net',
    'popcash.net',
    'adsterra.com',
    'exoclick.com',
    'exosrv.com',
    'juicyads.com',
    'trafficjunky.com',
    'trafficfactory.biz',
    'hilltopads.net',
    'adnium.com',
    'clickadu.com',
    'adcash.com',
    'zeropark.com',
    'onclickads.net',
    'onclkds.com',
    'admaven.com',

    // ── Russia / CIS ─────────────────────────────────────────────────────
    // Subdomains only where the parent is a service the user still needs:
    // `yandex.ru` and `mail.ru` are in the *bypass* list, and the block rule
    // is emitted ahead of it precisely so these still get caught.
    'an.yandex.ru',
    'awaps.yandex.ru',
    'bs.yandex.ru',
    'adfox.yandex.ru',
    'mc.yandex.ru',
    'mc.yandex.com',
    'metrika.yandex.ru',
    'appmetrica.yandex.ru',
    'appmetrica.yandex.net',
    'yandexmetrica.com',
    'adfox.ru',
    'ad.mail.ru',
    'rb.mail.ru',
    'top.mail.ru',
    'top-fwz1.mail.ru',
    'ads.vk.com',
    'adriver.ru',
    'directadvert.ru',
    'marketgid.com',
    'smi2.ru',
    'smi2.net',
    'relap.io',
    'lentainform.com',
    'begun.ru',
    'soloway.ru',
    'rutarget.ru',
    'betweendigital.com',
    'buzzoola.com',
    'otm-r.com',
    'hybrid.ai',
    'digitaltarget.ru',
    'gnezdo.ru',
    'kadam.net',
    'tns-counter.ru',
    'liveinternet.ru',
    'hotlog.ru',
    'top100.rambler.ru',
    'counter.yadro.ru',
  ];
}
