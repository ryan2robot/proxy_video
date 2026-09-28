import 'package:proxy_video/proxy_video.dart';
import 'package:test/test.dart';

Future<void> _noop(RequestContext context) async {}

void main() {
  group('Router', () {
    test('matches literal segments exactly', () {
      final router = Router()..get('/api/media', _noop);

      expect(router.resolve('GET', <String>['api', 'media']), isNotNull);
      expect(router.resolve('GET', <String>['api', 'media', 'extra']), isNull);
      expect(router.resolve('GET', <String>['api']), isNull);
      expect(router.resolve('GET', <String>['API', 'media']), isNull);
    });

    test('captures :placeholders', () {
      final router = Router()..get('/api/jobs/:id', _noop);

      final match = router.resolve('GET', <String>['api', 'jobs', 'job-3']);
      expect(match, isNotNull);
      expect(match!.parameters['id'], 'job-3');
    });

    test('captures a trailing ** as the rest of the path', () {
      final router = Router()..get('/media/**', _noop);

      expect(
        router.resolve('GET', <String>['media', 'clips', 'a.mp4'])!.wildcard,
        'clips/a.mp4',
      );
      expect(router.resolve('GET', <String>['media'])!.wildcard, '');
      expect(
        router.resolve('GET', <String>['media', 'a.mp4'])!.wildcard,
        'a.mp4',
      );
    });

    test('a HEAD request falls back to the GET route', () {
      final router = Router()..get('/media/**', _noop);

      expect(router.resolve('HEAD', <String>['media', 'a.mp4']), isNotNull);
      expect(router.resolve('POST', <String>['media', 'a.mp4']), isNull);
    });

    test('reports the methods a path accepts', () {
      final router = Router()
        ..get('/api/media', _noop)
        ..post('/api/transcode', _noop);

      expect(router.allowedMethods(<String>['api', 'media']), <String>{
        'GET',
        'HEAD',
      });
      expect(router.allowedMethods(<String>['api', 'transcode']), <String>{
        'POST',
      });
      expect(router.allowedMethods(<String>['nope']), isEmpty);
    });

    test('matches the root route only for an empty path', () {
      final router = Router()..get('/', _noop);

      expect(router.resolve('GET', <String>[]), isNotNull);
      expect(router.resolve('GET', <String>['anything']), isNull);
    });

    test('refuses a `**` that is not the final segment', () {
      expect(
        () => Router()..get('/a/**/b', _noop),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('refuses two routes that would be ambiguous', () {
      expect(
        () => Router()
          ..get('/a/:x', _noop)
          ..get('/a/:y', _noop),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => Router()
          ..get('/a/b', _noop)
          ..get('/a/b', _noop),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('the first registered route wins', () {
      // Registration order decides, which is why `AppServer` lists its patterns
      // from most specific to least.
      final literalFirst = Router()
        ..get('/a/fixed', _noop)
        ..get('/a/:name', _noop);
      expect(
        literalFirst.resolve('GET', <String>['a', 'fixed'])!.parameters,
        isEmpty,
      );

      final placeholderFirst = Router()
        ..get('/a/:name', _noop)
        ..get('/a/fixed', _noop);
      expect(
        placeholderFirst.resolve('GET', <String>[
          'a',
          'fixed',
        ])!.parameters['name'],
        'fixed',
      );
    });

    test('lists the registered routes for diagnostics', () {
      final router = Router()
        ..get('/', _noop)
        ..post('/api/cache', _noop);

      expect(router.routes, containsAll(<String>['GET /', 'POST /api/cache']));
    });
  });
}
