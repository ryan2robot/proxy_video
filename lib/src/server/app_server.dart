import 'dart:async';
import 'dart:io';

import '../api/api_routes.dart';
import '../api/transcode_service.dart';
import '../cache/disk_cache.dart';
import '../config.dart';
import '../logger.dart';
import '../proxy/media_proxy.dart';
import '../storage/storage.dart';
import '../util/http_util.dart';
import '../web/play_page.dart';
import 'router.dart';

/// The public-facing server: range proxy, JSON API and the web UI.
///
/// One `HttpServer` serves all three, because they are three views of the same
/// object store and splitting them would only add ports to keep track of.
class AppServer {
  AppServer({
    required this.config,
    required this.storage,
    required this.cache,
    required this.proxy,
    required this.transcodes,
    Logger? log,
  }) : _log = (log ?? rootLogger).child('server') {
    _api = ApiRoutes(
      config: config,
      cache: cache,
      storage: storage,
      proxy: proxy,
      transcodes: transcodes,
      log: _log,
    );
    _router = Router();
    _registerRoutes();
  }

  /// Resolved runtime settings.
  final Config config;

  /// Backend media is read from.
  final Storage storage;

  /// Disk cache backing the proxy.
  final DiskCache cache;

  /// Range proxy.
  final MediaProxy proxy;

  /// Transcode queue behind `/api/transcode`.
  final TranscodeService transcodes;

  final Logger _log;

  late final Router _router;
  late final ApiRoutes _api;
  final WebPages _pages = const WebPages();

  HttpServer? _server;

  /// Port actually listening; differs from [Config.port] when it was `0`.
  int get port => _server?.port ?? config.port;

  /// Base URI of the running server.
  Uri get baseUri => Uri(scheme: 'http', host: config.bindAddress, port: port);

  /// Whether the server is listening.
  bool get isRunning => _server != null;

  /// Routes registered, for diagnostics.
  Iterable<String> get routes => _router.routes;

  /// Binds and starts serving.
  Future<void> start() async {
    if (_server != null) return;

    final server = await HttpServer.bind(config.bindAddress, config.port);
    // Compression rewrites Content-Length, which would invalidate the byte
    // ranges this service exists to serve. Media is already compressed anyway.
    server.autoCompress = false;
    _server = server;

    unawaited(_accept(server));
    _log.info(
      'app server listening',
      fields: <String, Object?>{'url': baseUri.toString()},
    );
  }

  /// Stops serving, aborts live connections and waits for background cache
  /// fills so nothing is left half-written.
  Future<void> stop() async {
    final server = _server;
    _server = null;
    if (server != null) await server.close(force: true);

    try {
      await proxy.whenIdle().timeout(const Duration(seconds: 15));
    } on TimeoutException {
      _log.warn('gave up waiting for background cache fills');
    }
  }

  void _registerRoutes() {
    _api.register(_router);

    _router
      ..get('/', _library)
      ..get('/favicon.ico', _favicon)
      ..get('/play/**', _player)
      // Media is streamed by the proxy, which owns the range semantics.
      ..get('/media/**', _media);
  }

  Future<void> _library(RequestContext context) =>
      writeText(context.response, _pages.library(), kHtmlContentType);

  Future<void> _player(RequestContext context) async {
    final key = sanitizeKey(context.rest);
    if (key == null) {
      await writeProblem(
        context.request,
        HttpStatus.badRequest,
        'Not a usable media key.',
      );
      return;
    }
    await writeText(context.response, _pages.player(key), kHtmlContentType);
  }

  Future<void> _media(RequestContext context) async {
    if (context.rest.isEmpty) {
      await writeProblem(
        context.request,
        HttpStatus.badRequest,
        'Missing media key.',
      );
      return;
    }
    await proxy.serve(context.request, context.rest);
  }

  Future<void> _favicon(RequestContext context) async {
    // Nothing to serve, but answering keeps the browser console clean.
    context.response.statusCode = HttpStatus.noContent;
    await context.response.close();
  }

  Future<void> _accept(HttpServer server) async {
    await for (final request in server) {
      unawaited(_dispatchSafely(request));
    }
  }

  Future<void> _dispatchSafely(HttpRequest request) async {
    final stopwatch = Stopwatch()..start();
    try {
      await _dispatch(request);
    } on Object catch (error, stackTrace) {
      _log.warn(
        'request failed',
        fields: <String, Object?>{
          'method': request.method,
          'path': request.uri.path,
          'error': error,
        },
        stackTrace: Logger.level == LogLevel.debug ? stackTrace : null,
      );
      await _fail(request);
    } finally {
      _log.debug(
        'handled',
        fields: <String, Object?>{
          'method': request.method,
          'path': request.uri.path,
          'ms': stopwatch.elapsedMilliseconds,
        },
      );
    }
  }

  Future<void> _dispatch(HttpRequest request) async {
    final segments = request.uri.pathSegments;
    final match = _router.resolve(request.method, segments);

    if (match != null) {
      await match.handler(match.bind(request));
      return;
    }

    // A path that exists but not for this verb deserves 405, not 404, and it
    // has to name the verbs that would work.
    final allowed = _router.allowedMethods(segments);
    if (allowed.isNotEmpty) {
      final ordered = <String>[
        'GET',
        'HEAD',
        'POST',
        'DELETE',
      ].where(allowed.contains).toList(growable: false);
      request.response.headers.set(HttpHeaders.allowHeader, ordered.join(', '));
      await writeProblem(
        request,
        HttpStatus.methodNotAllowed,
        'Method not allowed.',
      );
      return;
    }

    await writeProblem(
      request,
      HttpStatus.notFound,
      'No route for ${request.uri.path}.',
    );
  }

  Future<void> _fail(HttpRequest request) async {
    try {
      await writeProblem(
        request,
        HttpStatus.internalServerError,
        'Internal error.',
      );
      return;
    } on Object {
      // The status line is already on the wire — a handler failed midway
      // through streaming — so it can no longer be replaced.
    }

    try {
      await request.response.close();
    } on Object {
      // The peer is gone; there is nobody left to tell.
    }
  }
}
