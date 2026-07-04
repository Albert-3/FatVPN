class ServerNode {
  const ServerNode({
    required this.id,
    required this.name,
    required this.address,
    required this.port,
    required this.usersOnline,
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
