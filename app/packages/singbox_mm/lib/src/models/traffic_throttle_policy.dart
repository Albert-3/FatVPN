class TrafficThrottlePolicy {
  const TrafficThrottlePolicy({
    this.enableMultiplex = false,
    this.multiplexPadding = true,
    this.multiplexConnections = 4,
    this.multiplexMinStreams = 4,
    this.multiplexMaxStreams = 16,
    this.enableTcpBrutal = false,
    this.tcpBrutalUploadMbps = 80,
    this.tcpBrutalDownloadMbps = 240,
    this.tcpFastOpen = true,
    this.udpFragment = true,
    this.tunMtu,
    this.dnsStrategy = 'prefer_ipv4',
    this.enableAutoMtuProbe = true,
    this.mtuProbeCandidates = const <int>[1400, 1380, 1360, 1340, 1320],
  }) : assert(multiplexConnections > 0),
       assert(multiplexMinStreams > 0),
       assert(multiplexMaxStreams >= multiplexMinStreams),
       assert(tcpBrutalUploadMbps > 0),
       assert(tcpBrutalDownloadMbps > 0),
       assert(tunMtu == null || tunMtu >= 1280);

  final bool enableMultiplex;
  final bool multiplexPadding;
  final int multiplexConnections;
  final int multiplexMinStreams;
  final int multiplexMaxStreams;
  final bool enableTcpBrutal;
  final int tcpBrutalUploadMbps;
  final int tcpBrutalDownloadMbps;
  final bool tcpFastOpen;
  final bool udpFragment;

  /// TUN MTU this policy asks for, or null to take the platform default
  /// ([defaultTunMtu]).
  ///
  /// The single source of truth for the emitted `tun.mtu`: presets set it, the
  /// adaptive probe recomputes it (see `_effectiveThrottlePolicyForProfile`),
  /// and the config builder now reads it. Null rather than a fixed 1400 so
  /// "nobody asked for a particular MTU" stays distinguishable from "1400 was
  /// chosen" — the platform default differs between iOS and Android, and a
  /// non-null default here would silently override it everywhere.
  final int? tunMtu;
  final String dnsStrategy;
  final bool enableAutoMtuProbe;
  final List<int> mtuProbeCandidates;

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'enableMultiplex': enableMultiplex,
      'multiplexPadding': multiplexPadding,
      'multiplexConnections': multiplexConnections,
      'multiplexMinStreams': multiplexMinStreams,
      'multiplexMaxStreams': multiplexMaxStreams,
      'enableTcpBrutal': enableTcpBrutal,
      'tcpBrutalUploadMbps': tcpBrutalUploadMbps,
      'tcpBrutalDownloadMbps': tcpBrutalDownloadMbps,
      'tcpFastOpen': tcpFastOpen,
      'udpFragment': udpFragment,
      'tunMtu': tunMtu,
      'dnsStrategy': dnsStrategy,
      'enableAutoMtuProbe': enableAutoMtuProbe,
      'mtuProbeCandidates': mtuProbeCandidates,
    };
  }

  TrafficThrottlePolicy copyWith({
    bool? enableMultiplex,
    bool? multiplexPadding,
    int? multiplexConnections,
    int? multiplexMinStreams,
    int? multiplexMaxStreams,
    bool? enableTcpBrutal,
    int? tcpBrutalUploadMbps,
    int? tcpBrutalDownloadMbps,
    bool? tcpFastOpen,
    bool? udpFragment,
    int? tunMtu,
    String? dnsStrategy,
    bool? enableAutoMtuProbe,
    List<int>? mtuProbeCandidates,
  }) {
    return TrafficThrottlePolicy(
      enableMultiplex: enableMultiplex ?? this.enableMultiplex,
      multiplexPadding: multiplexPadding ?? this.multiplexPadding,
      multiplexConnections: multiplexConnections ?? this.multiplexConnections,
      multiplexMinStreams: multiplexMinStreams ?? this.multiplexMinStreams,
      multiplexMaxStreams: multiplexMaxStreams ?? this.multiplexMaxStreams,
      enableTcpBrutal: enableTcpBrutal ?? this.enableTcpBrutal,
      tcpBrutalUploadMbps: tcpBrutalUploadMbps ?? this.tcpBrutalUploadMbps,
      tcpBrutalDownloadMbps:
          tcpBrutalDownloadMbps ?? this.tcpBrutalDownloadMbps,
      tcpFastOpen: tcpFastOpen ?? this.tcpFastOpen,
      udpFragment: udpFragment ?? this.udpFragment,
      tunMtu: tunMtu ?? this.tunMtu,
      dnsStrategy: dnsStrategy ?? this.dnsStrategy,
      enableAutoMtuProbe: enableAutoMtuProbe ?? this.enableAutoMtuProbe,
      mtuProbeCandidates: mtuProbeCandidates ?? this.mtuProbeCandidates,
    );
  }

  Map<String, Object?> toMultiplexMap() {
    return <String, Object?>{
      'enabled': enableMultiplex,
      'protocol': 'smux',
      'max_connections': multiplexConnections,
      'min_streams': multiplexMinStreams,
      'max_streams': multiplexMaxStreams,
      'padding': multiplexPadding,
    };
  }

  Map<String, Object?>? toTcpBrutalMap() {
    if (!enableTcpBrutal) {
      return null;
    }

    return <String, Object?>{
      'enabled': true,
      'up_mbps': tcpBrutalUploadMbps,
      'down_mbps': tcpBrutalDownloadMbps,
    };
  }
}
