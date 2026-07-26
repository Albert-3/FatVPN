class ServerNode {
  const ServerNode({
    required this.id,
    required this.name,
    required this.address,
    required this.port,
    required this.usersOnline,
    this.configUri,
  });

  factory ServerNode.fromJson(Map<String, dynamic> json) {
    return ServerNode(
      id: json['id'] as String,
      name: json['name'] as String,
      address: json['address'] as String,
      port: json['port'] as int,
      usersOnline: json['usersOnline'] as int,
    );
  }

  final String id;
  final String name;
  final String address;
  final int port;
  final int usersOnline;

  /// The exact subscription link this entry came from, when the list was built
  /// from `/config`. Carrying it avoids re-deriving the link by address at
  /// connect time — an address lookup can't tell apart two inbounds published
  /// on the same host (e.g. a vless and a hysteria2 entry), and would always
  /// return whichever came first.
  final String? configUri;

  ServerNode withConfigUri(String uri) => ServerNode(
        id: id,
        name: name,
        address: address,
        port: port,
        usersOnline: usersOnline,
        configUri: uri,
      );
}

class ServerCountry {
  const ServerCountry({
    required this.country,
    required this.flag,
    required this.nodeCount,
    required this.nodes,
  });

  factory ServerCountry.fromJson(Map<String, dynamic> json) {
    return ServerCountry(
      country: json['country'] as String,
      flag: json['flag'] as String,
      nodeCount: json['nodeCount'] as int,
      nodes: (json['nodes'] as List<dynamic>)
          .map((e) => ServerNode.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  /// Remnawave country codes (e.g. "DE") rather than display names; kept as
  /// the label until the BFF returns human-readable country names.
  final String country;
  final String flag;
  final int nodeCount;
  final List<ServerNode> nodes;
}
