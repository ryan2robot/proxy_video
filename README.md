# proxy_video

面向播放器的 **HTTP Range 代理 + 磁盘分片缓存** Dart 库。

把它挂到任意 `HttpServer` 上，浏览器（或任何支持 `Range` 的客户端）就能**边下边播**：
读到哪一段就缓存哪一段，重新播放或拖动进度条不再回源。

这个包只做这一件事：**代理下载并缓存视频**。没有 UI、没有转码、没有对象存储适配器，
上游地址通过一个 base URL 描述。

## 安装

```yaml
dependencies:
  proxy_video:
    path: ../proxy_video
```

## 快速开始

```dart
import 'dart:io';

import 'package:proxy_video/proxy_video.dart';

Future<void> main() async {
  final config = Config(
    originBaseUrl: Uri.parse('https://cdn.example.com'),
    cacheDirPath: './cache',
  );
  Logger.configure(level: config.logLevel);

  final proxy = VideoProxy(config);
  final server = await HttpServer.bind('127.0.0.1', 8080);

  await for (final request in server) {
    await proxy.serve(request, request.uri.pathSegments.skip(1).join('/'));
  }

  await proxy.close();
}
```

可运行的完整示例在 `example/proxy_server.dart`：

```sh
dart run example/proxy_server.dart https://cdn.example.com ./cache 8080
curl -r 0-1023 http://127.0.0.1:8080/media/clips/movie.mp4
```

对象 key 逐段拼在上游 base URL 之后：key `clips/movie.mp4` +
`https://cdn.example.com/videos` → `https://cdn.example.com/videos/clips/movie.mp4`。

## Config

全部设置装在一个对象里，构造时校验；不合法的值立刻抛 `ArgumentError`，
而不是等到第一个请求才失败。

| 字段 | 默认值 | 说明 |
| --- | --- | --- |
| `originBaseUrl` | 必填 | 上游 base URL（`http`/`https`），保留其中的路径前缀 |
| `cacheDirPath` | 必填 | 缓存目录，每个对象一对 `<key>.bin` + `<key>.meta.json` |
| `chunkSize` | `1 MiB` | 分片粒度；越小首帧越快、回源请求数越多 |
| `maxCacheBytes` | `2 GiB` | 缓存预算，超出按 LRU 淘汰；`0` 表示不淘汰 |
| `maxConcurrentUpstream` | `4` | 并发回源上限 |
| `prefetchAhead` | `0` | 顺序预取的分片数 |
| `continueAfterDisconnect` | `true` | 客户端断开后继续补完当前窗口 |
| `upstreamTimeout` | `30s` | 单次回源请求超时 |
| `connectTimeout` | `10s` | 回源建连超时 |
| `logLevel` | `info` | 日志级别 |

需要自己组装时，`VideoProxy` 里的三件套也可以单独用：
`HttpOriginClient`（HTTP 上游）、`DiskCache`（分片缓存）、`MediaProxy`（Range 代理）。

## Range 语义

这是代理的正确性核心，由 `lib/src/util/byte_range.dart` 一处实现并被测试逐条固化：

| 请求 | 响应 |
| --- | --- |
| 无 `Range` | `200` + `Content-Length` + `Accept-Ranges: bytes` |
| `HEAD` | 与 GET 相同的头部，无响应体 |
| `Range: bytes=0-` | `206` + `Content-Range: bytes 0-<total-1>/<total>` |
| `Range: bytes=s-e` | `206` + `Content-Range: bytes s-e/<total>`，`Content-Length = e-s+1` |
| `Range: bytes=-N`（后缀） | 等价于末尾 N 字节 |
| 越界 `s >= total` | `416` + `Content-Range: bytes */<total>` |
| 多段 / 非法 / 未知单位 | 忽略 `Range`，返回 `200` 全量 |
| 其它方法 | `405` + `Allow: GET, HEAD` |

`Content-Length` 在 `206` 时永远是**区间长度**而非对象长度。响应使用
`bufferOutput = false` 并在下发前 `flush()` 头部，播放器无需等到第一个字节就能知道对象大小。

## 边下边播与缓存写入

对象按 `chunkSize` 切成固定分片，`CacheEntry` 维护三件事：

1. **先落盘再下发** —— 分片先写文件并 `flush`，之后字节才交给客户端。
   中途断开永远不会丢已经取回的字节，也不会把半个分片标成可用。
2. **single-flight** —— 同一个分片的并发请求合并成一次回源请求。
   浏览器 seek 造成的请求突发不会放大成对上游的请求突发。
3. **读时填充** —— `readRange` 顺序 `ensureChunk`，新下载的分片直接从内存交给当前消费者，
   已缓存的分片从磁盘读，天然就是 tee。

缓存元数据（`totalSize` / 分片位图 / `ETag`）持久化在 `*.meta.json`，位图用 base64 编码
（4 GiB 文件在 1 MiB 分片下只有约 700 字节）并**节流写入**，不会因为边看边下产生写放大。
上游对象被替换时（`ETag` 或长度变化）整份缓存作废重建，避免把旧字节喂给新视频。

### 客户端断开

已发起的回源请求不受客户端影响：它是独立的 Future，消费者取消 stream 不会取消它，
分片照常落盘。已经写出去一半、但连接真断了的窗口，会从**第一个未缓存的分片**继续在后台补完
（可用 `continueAfterDisconnect: false` 关闭）。

## 目录

```
lib/src/
  config.dart                  全部设置与校验
  video_proxy.dart             装配门面：Config → origin + cache + proxy
  proxy/http_origin_client.dart   HTTP 上游客户端（HEAD + Range）
  proxy/media_proxy.dart          Range 代理：206 / 416 / 断连续传
  cache/cache_entry.dart          分片状态机：single-flight、落盘、元数据
  cache/disk_cache.dart           磁盘布局、统计、LRU 淘汰
  cache/origin_client.dart        上游抽象与错误类型
  util/                           Range 解析、key 校验、字节尺寸、信号量、日志
example/proxy_server.dart         最小可用服务
```

## 已知限制

- 上游必须支持 `HEAD` 并返回 `Content-Length`（COS 与主流 CDN 都支持）。
- 上游若忽略 `Range` 返回 `200`，本库会自行裁剪出请求区间（有测试覆盖）。
- 不支持多段 `Range`，会降级成整文件 `200`。
- 不实现条件请求（`If-None-Match` / `If-Modified-Since`），因此不使用 `304`；
  响应带 `Cache-Control: no-store`，让客户端每次都问代理，代理则从磁盘秒回。
- 缓存目录按 key 镜像（`<cache>/clips/a.mp4.bin`）。key 由 `sanitizeKey` 限制为
  `[A-Za-z0-9._-]` 且拒绝 `..`、绝对路径与 Windows 保留名，所以目录可读、不会碰撞、也不会被穿越。
- 缓存目录不做并发进程保护：同一个目录应由一个进程独占使用。

## 测试

```sh
dart analyze
dart test
```

测试用真实 `HttpServer` + 真实 HTTP 上游替身跑完整链路，覆盖 Range 语义、缓存命中、
渐进播放（上游被卡住时首块仍能到达客户端）与断连续传。
