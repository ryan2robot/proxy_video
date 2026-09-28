import 'dart:io';

/// Handles one matched request.
typedef RouteHandler = Future<void> Function(RequestContext context);

/// A request plus whatever the router captured from its path.
class RequestContext {
  const RequestContext({
    required this.request,
    required this.parameters,
    this.wildcard,
  });

  /// The underlying request.
  final HttpRequest request;

  /// `:name` placeholders captured from the path.
  final Map<String, String> parameters;

  /// Everything matched by a trailing `**`, without a leading slash.
  final String? wildcard;

  /// The request target.
  Uri get uri => request.uri;

  /// The response to write to.
  HttpResponse get response => request.response;

  /// Captured `:name` value; empty when the route has no such placeholder.
  String param(String name) => parameters[name] ?? '';

  /// Whatever the trailing `**` matched; empty when the pattern has none.
  String get rest => wildcard ?? '';
}

/// A route that matched, ready to build a [RequestContext].
class RouteMatch {
  const RouteMatch({
    required this.handler,
    required this.parameters,
    this.wildcard,
  });

  /// Handler to invoke.
  final RouteHandler handler;

  /// Captured `:name` placeholders.
  final Map<String, String> parameters;

  /// Captured `**` remainder.
  final String? wildcard;

  /// Binds this match to [request].
  RequestContext bind(HttpRequest request) => RequestContext(
    request: request,
    parameters: parameters,
    wildcard: wildcard,
  );
}

/// Method-and-path router for [HttpServer].
///
/// Patterns are literal segments, `:name` placeholders, and an optional
/// trailing `**` that swallows the rest of the path. That is the entire feature
/// set this service needs, and hand-rolling it avoids a dependency for a table
/// of about a dozen routes.
class Router {
  final List<_Route> _routes = <_Route>[];

  /// Registers a `GET` route.
  void get(String pattern, RouteHandler handler) =>
      _add('GET', pattern, handler);

  /// Registers a `POST` route.
  void post(String pattern, RouteHandler handler) =>
      _add('POST', pattern, handler);

  /// Registers a `DELETE` route.
  void delete(String pattern, RouteHandler handler) =>
      _add('DELETE', pattern, handler);

  /// Routes registered so far, for diagnostics.
  Iterable<String> get routes => _routes.map(
    (_Route route) => '${route.method} /${route.segments.join('/')}',
  );

  /// Finds the handler for [method] and [segments].
  ///
  /// A `HEAD` request falls back to a matching `GET`, which is what HTTP
  /// requires: a client must be able to ask for headers of any resource.
  RouteMatch? resolve(String method, List<String> segments) {
    RouteMatch? headFallback;

    for (final route in _routes) {
      final match = route.match(segments);
      if (match == null) continue;
      if (route.method == method || route.method == '*') return match;
      if (method == 'HEAD' && route.method == 'GET') headFallback ??= match;
    }

    return headFallback;
  }

  /// Methods that would match [segments], used to answer `405` properly.
  Set<String> allowedMethods(List<String> segments) {
    final allowed = <String>{};
    for (final route in _routes) {
      if (route.match(segments) == null) continue;
      if (route.method == '*') return <String>{'GET', 'HEAD', 'POST', 'DELETE'};
      allowed.add(route.method);
      if (route.method == 'GET') allowed.add('HEAD');
    }
    return allowed;
  }

  void _add(String method, String pattern, RouteHandler handler) {
    final route = _Route(method, pattern, handler);
    final duplicate = _routes.any(
      (_Route existing) =>
          existing.method == route.method &&
          existing.segments.length == route.segments.length &&
          _sameShape(existing.segments, route.segments),
    );
    if (duplicate) {
      throw ArgumentError(
        'duplicate route: $method /${route.segments.join('/')}',
      );
    }
    _routes.add(route);
  }

  static bool _sameShape(List<String> a, List<String> b) {
    for (var index = 0; index < a.length; index++) {
      final left = a[index];
      final right = b[index];
      if (left.startsWith(':') && right.startsWith(':')) continue;
      if (left != right) return false;
    }
    return true;
  }
}

class _Route {
  _Route(this.method, String pattern, this.handler)
    : segments = _splitPattern(pattern) {
    // A pattern of `/` legitimately splits into zero segments: it is the root
    // route, and it matches only the empty path.
    final star = segments.indexOf('**');
    if (star >= 0 && star != segments.length - 1) {
      throw ArgumentError('`**` must be the last segment of "$pattern"');
    }
  }

  final String method;
  final List<String> segments;
  final RouteHandler handler;

  RouteMatch? match(List<String> path) {
    final parameters = <String, String>{};

    for (var index = 0; index < segments.length; index++) {
      final pattern = segments[index];

      if (pattern == '**') {
        return RouteMatch(
          handler: handler,
          parameters: parameters,
          wildcard: path.skip(index).join('/'),
        );
      }
      if (index >= path.length) return null;

      if (pattern.startsWith(':')) {
        parameters[pattern.substring(1)] = path[index];
        continue;
      }
      if (pattern != path[index]) return null;
    }

    if (path.length != segments.length) return null;
    return RouteMatch(handler: handler, parameters: parameters);
  }
}

List<String> _splitPattern(String pattern) => pattern
    .split('/')
    .where((String segment) => segment.isNotEmpty)
    .toList(growable: false);
