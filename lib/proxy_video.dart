/// Public surface of the `proxy_video` package.
///
/// A range-capable HTTP proxy that caches media on disk in fixed-size chunks,
/// so a player can start watching before the whole object has been transferred.
///
/// Start with [VideoProxy] and a [Config]: everything else here is the parts it
/// is assembled from, exposed for callers that need to wire them differently.
library;

export 'src/cache/cache_entry.dart';
export 'src/cache/disk_cache.dart';
export 'src/cache/origin_client.dart';
export 'src/config.dart';
export 'src/logger.dart';
export 'src/proxy/http_origin_client.dart';
export 'src/proxy/media_proxy.dart';
export 'src/util/byte_range.dart';
export 'src/util/byte_size.dart';
export 'src/util/http_util.dart';
export 'src/util/semaphore.dart';
export 'src/video_proxy.dart';
