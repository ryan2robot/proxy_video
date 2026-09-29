/// Public surface of the `proxy_video` package.
///
/// A range-capable HTTP proxy that caches media on disk in fixed-size chunks,
/// so a player can start watching before the whole object has been transferred.
///
/// Start with [VideoProxy] and a [Config]: everything else here is the parts it
/// is assembled from, exposed for callers that need to wire them differently.
library;

export 'src/cache.dart';
export 'src/config.dart';
export 'src/logger.dart';
export 'src/media_proxy.dart';
export 'src/origin.dart';
export 'src/util.dart';
export 'src/video_proxy.dart';
