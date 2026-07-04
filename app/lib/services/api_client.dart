import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../models/account_status.dart';
import '../models/auth_session.dart';
import '../models/server_country.dart';

class ApiException implements Exception {
  ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => 'ApiException($statusCode): $message';
}

class ApiClient {
  ApiClient({http.Client? httpClient, String? baseUrl})
      : _httpClient = httpClient ?? http.Client(),
        _baseUrl = baseUrl ?? bffBaseUrl;

  final http.Client _httpClient;
  final String _baseUrl;

  Future<AuthSession> exchangeToken(String shortToken) async {
    final response = await _httpClient.post(
      Uri.parse('$_baseUrl/auth/token'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'shortToken': shortToken}),
    );

    if (response.statusCode != 200) {
      throw ApiException(
        'Token exchange failed',
        statusCode: response.statusCode,
      );
    }

    return AuthSession.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<List<ServerCountry>> getServers() async {
    final response = await _httpClient.get(Uri.parse('$_baseUrl/servers'));

    if (response.statusCode != 200) {
      throw ApiException('Failed to load servers', statusCode: response.statusCode);
    }

    final body = jsonDecode(response.body) as List<dynamic>;
    return body
        .map((e) => ServerCountry.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<AccountStatus> getMe(String accessToken) async {
    final response = await _httpClient.get(
      Uri.parse('$_baseUrl/me'),
      headers: {'Authorization': 'Bearer $accessToken'},
    );

    if (response.statusCode != 200) {
      throw ApiException('Failed to load account status', statusCode: response.statusCode);
    }

    return AccountStatus.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<(String content, String contentType)> getConfig(String accessToken) async {
    final response = await _httpClient.get(
      Uri.parse('$_baseUrl/config'),
      headers: {'Authorization': 'Bearer $accessToken'},
    );

    if (response.statusCode != 200) {
      throw ApiException('Failed to load config', statusCode: response.statusCode);
    }

    final contentType = response.headers['content-type'] ?? 'text/plain';
    return (response.body, contentType);
  }
}
