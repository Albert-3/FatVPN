// An `HttpOverrides` that cannot reach the network, and says what was asked of
// it.
//
// `FatVpnApp` builds its own `ApiClient` (and therefore its own `http.Client`)
// deep inside `AuthController`, so a widget test that boots the whole app has
// no seam to inject a `MockClient` through. `HttpOverrides` is the seam that
// does exist: `package:http`'s `IOClient` goes through `dart:io`'s `HttpClient`,
// which `HttpOverrides.createHttpClient` supplies.
//
// Installing this makes a widget test hermetic in the strong sense — no socket
// is opened, no DNS lookup happens, and the answer is the same on every run and
// on a machine with no network at all. It also records every attempt, so a test
// can assert that a code path stayed offline rather than merely hoping it did.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Installs [NoNetworkHttpClient] for anything that asks `dart:io` for a client.
class NoNetworkHttpOverrides extends HttpOverrides {
  NoNetworkHttpOverrides({this.statusCode = 503, this.body = ''});

  /// Status every request is answered with. 503 rather than 200 on purpose: no
  /// test should be reading meaning out of a response that was never fetched.
  final int statusCode;
  final String body;

  /// `METHOD url` for every request attempted, in order.
  final List<String> requests = <String>[];

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      NoNetworkHttpClient(this);
}

class NoNetworkHttpClient implements HttpClient {
  NoNetworkHttpClient(this._overrides);

  final NoNetworkHttpOverrides _overrides;

  @override
  bool autoUncompress = true;
  @override
  Duration idleTimeout = const Duration(seconds: 15);
  @override
  Duration? connectionTimeout;
  @override
  int? maxConnectionsPerHost;
  @override
  String? userAgent;

  /// Settable, never called. No TLS happens here, but the app's own client sets
  /// this on construction (it is where a pinning rejection is written down), and
  /// a fake that threw on the setter would take out every widget test that boots
  /// the whole app — with a stack pointing at the certificate code rather than at
  /// this file.
  @override
  bool Function(X509Certificate cert, String host, int port)?
      badCertificateCallback;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    _overrides.requests.add('$method $url');
    return _NoNetworkRequest(method, url, _overrides);
  }

  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('GET', url);
  @override
  Future<HttpClientRequest> postUrl(Uri url) => openUrl('POST', url);
  @override
  Future<HttpClientRequest> putUrl(Uri url) => openUrl('PUT', url);
  @override
  Future<HttpClientRequest> deleteUrl(Uri url) => openUrl('DELETE', url);
  @override
  Future<HttpClientRequest> headUrl(Uri url) => openUrl('HEAD', url);
  @override
  Future<HttpClientRequest> patchUrl(Uri url) => openUrl('PATCH', url);

  @override
  void close({bool force = false}) {}

  /// Anything not listed above would mean a code path this fake was never meant
  /// to stand in for — fail loudly instead of pretending.
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
      'NoNetworkHttpClient.${invocation.memberName} is not available in tests');
}

class _NoNetworkRequest implements HttpClientRequest {
  _NoNetworkRequest(this.method, this.uri, this._overrides);

  @override
  final String method;
  @override
  final Uri uri;
  final NoNetworkHttpOverrides _overrides;

  @override
  final HttpHeaders headers = _MutableHeaders();
  @override
  bool followRedirects = true;
  @override
  int maxRedirects = 5;
  @override
  int contentLength = -1;
  @override
  bool persistentConnection = true;
  @override
  bool bufferOutput = true;
  @override
  Encoding encoding = utf8;

  @override
  void add(List<int> data) {}
  @override
  void write(Object? object) {}
  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) {}
  @override
  void writeln([Object? object = '']) {}
  @override
  void writeCharCode(int charCode) {}
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.drain<void>();

  @override
  Future<HttpClientResponse> get done => close();

  @override
  Future<HttpClientResponse> close() async => _NoNetworkResponse(_overrides);

  @override
  void abort([Object? exception, StackTrace? stackTrace]) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
      'NoNetworkHttpRequest.${invocation.memberName} is not available in tests');
}

class _NoNetworkResponse extends Stream<List<int>> implements HttpClientResponse {
  _NoNetworkResponse(this._overrides) : _body = utf8.encode(_overrides.body);

  final NoNetworkHttpOverrides _overrides;
  final List<int> _body;

  @override
  int get statusCode => _overrides.statusCode;
  @override
  String get reasonPhrase => 'Blocked: tests do not use the network';
  @override
  int get contentLength => _body.length;
  @override
  final HttpHeaders headers = _MutableHeaders();
  @override
  bool get isRedirect => false;
  @override
  bool get persistentConnection => false;
  @override
  List<Cookie> get cookies => const <Cookie>[];
  @override
  List<RedirectInfo> get redirects => const <RedirectInfo>[];
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      Stream<List<int>>.value(_body).listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
      'NoNetworkHttpResponse.${invocation.memberName} is not available in tests');
}

/// The few [HttpHeaders] members `package:http` actually touches.
class _MutableHeaders implements HttpHeaders {
  final Map<String, List<String>> _values = <String, List<String>>{};

  @override
  ContentType? contentType;
  @override
  bool chunkedTransferEncoding = false;
  @override
  int contentLength = -1;
  @override
  bool persistentConnection = true;
  @override
  DateTime? date;
  @override
  DateTime? expires;
  @override
  DateTime? ifModifiedSince;
  @override
  String? host;
  @override
  int? port;

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      _values[name.toLowerCase()] = <String>[value.toString()];

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) =>
      _values.putIfAbsent(name.toLowerCase(), () => <String>[])
          .add(value.toString());

  @override
  void remove(String name, Object value) =>
      _values[name.toLowerCase()]?.remove(value.toString());

  @override
  void removeAll(String name) => _values.remove(name.toLowerCase());

  @override
  List<String>? operator [](String name) => _values[name.toLowerCase()];

  @override
  String? value(String name) => _values[name.toLowerCase()]?.first;

  @override
  void forEach(void Function(String name, List<String> values) action) =>
      _values.forEach(action);

  @override
  void noFolding(String name) {}

  @override
  void clear() => _values.clear();
}
