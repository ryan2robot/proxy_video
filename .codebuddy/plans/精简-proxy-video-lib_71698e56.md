---
name: 精简-proxy-video-lib
overview: 精简 proxy_video 库的 lib 实现：收敛冗长注释、合并工具类文件、删除未被使用的公开 API 与可选特性，并同步重写测试、示例与 README，使 dart analyze 零告警、dart test 全绿。
todos:
  - id: slim-leaves
    content: 精简 Config 与 Logger，合并 util 原语为 src/util.dart，删除 byte_size.dart
    status: completed
  - id: slim-cache
    content: 合并 CacheEntry 与 DiskCache 为 src/cache.dart，移除统计、LRU 淘汰、预取、clear/flush
    status: completed
    dependencies:
      - slim-leaves
  - id: slim-proxy
    content: 合并上游客户端为 src/origin.dart，精简 MediaProxy 移除断连续传背景填充；用 [skill:dart-use-pattern-matching] 收敛状态码与异常分支
    status: completed
    dependencies:
      - slim-leaves
  - id: wire-facade
    content: 更新 VideoProxy 装配与 proxy_video.dart 导出及文档注释
    status: completed
    dependencies:
      - slim-cache
      - slim-proxy
  - id: rewrite-tests
    content: 用 [skill:dart-add-unit-test] 重写 5 个测试与测试替身适配新 API，删除被移除特性的用例
    status: completed
    dependencies:
      - wire-facade
  - id: sync-docs
    content: 同步 README 与 example 到新字段表与目录结构，去掉被移除特性的说明
    status: completed
    dependencies:
      - wire-facade
  - id: verify
    content: 用 [skill:dart-run-static-analysis] 与 [mcp:dart] 跑 analyze/format/test 全绿，并用 [subagent:code-explorer] 复核无悬挂引用
    status: completed
    dependencies:
      - rewrite-tests
      - sync-docs
---

## 需求概述

对 `proxy_video` 库的 `lib/` 实现做一次激进的精简重构：在保持「HTTP Range 代理 + 磁盘分片缓存 + 边下边播」核心行为不变的前提下，收敛冗长注释、合并碎片化小文件、简化实现逻辑，并移除库内无调用者的公开 API 与可裁剪的可选能力（统计、LRU 淘汰、断连续传背景填充、顺序预取等）。

## 核心内容

- **精简注释**：把「讲原理」的散文式注释收敛为一两行要点，只保留契约、安全边界与 why 的关键说明；保持 lib 注释英文、README 中文的现有文风。
- **简化实现**：合并 `cache_entry` / `disk_cache` / `media_proxy` 中重复的路径与状态处理，用 switch 表达式、记录类型收敛多分支控制流，行为保持不变。
- **收窄 API**：删除无调用者或仅供统计调试的导出与成员（`parseByteSize`、`LogLevel.tryParse`、`countChunkBitmapBits`、`isValidKey`、`OriginMetadata.acceptsRanges`、`RangeParseResult.isUnsatisfiable` / `wantsFullBody` 等）。
- **合并小文件**：util 下 6 个文件合并、origin 客户端两文件合并、缓存层两文件合并，去掉 `src/cache`、`src/proxy`、`src/util` 子目录；lib 文件数从 14 降到 8。
- **移除可裁剪能力**：LRU 淘汰与 `maxCacheBytes`、统计 stats、断连续传背景填充、顺序预取 `prefetchAhead`、`DiskCache.clear` / `flush`、日志 ANSI 着色与 `Logger.configure` / `captureOutput` / `reset`、`Config.describe` / `logLevel`。
- **同步更新**：`example`、`README`、全部测试对齐新 API；测试允许为新结构重写，服务于行为而非旧接口。

## 成果与验收

- `dart analyze` 零告警、`dart format` 无差异、`dart test` 全绿。
- 核心行为必须仍被用例覆盖：Range 语义（200 / 206 / 416 / 405 / 后缀 / 多段降级）、分片按需填充、single-flight 合并、断开后已缓存字节不丢、ETag / 长度变化整份重建、key 安全校验、渐进播放。
- lib 代码量与文件数显著下降（预计约 2900 行降至 1400 行上下，14 个文件降至 8 个）。

## 技术栈

沿用现有栈，不引入任何新依赖，不改动 `analysis_options.yaml`：

- 语言 / SDK：Dart `^3.8.0`（tall-style formatter，服务于 `require_trailing_commas`）。
- 运行时依赖：`path: ^1.9.1`（跨平台路径拼接）。
- 开发依赖：`lints: ^6.0.0`、`test: ^1.31.1`。
- 质量门禁：`package:lints/recommended.yaml` + `strict-casts` + `strict-raw-types`，额外 lint `always_declare_return_types`、`avoid_print`、`directives_ordering`、`prefer_single_quotes`、`require_trailing_commas`、`unawaited_futures`。

## 实现思路

**总体策略**：一次「行为等价重构 + 有意的功能裁剪」。先收窄公开面与移除可选能力，再据此重写测试，最后以 `dart analyze` + `dart test` 作为唯一硬性验收。为避免回归，正确性核心（Range 解析、分片状态机、元数据持久化、key 校验）只做「抽掉旁支 + 精简表达」，不重写算法。

**关键取舍（请逐条审阅，可在确认时否决）**：

| 能力 | 处置 | 理由 |
| --- | --- | --- |
| Range 语义解析、206/416/200/405 响应 | 保留 | 代理的正确性核心，README 已固化 |
| 分片预分配 `.bin`、base64 位图元数据、节流 + 原子写盘 | 保留 | 持久化可靠性核心 |
| single-flight `ensureChunk`、先落盘再下发、新分片内存直供 | 保留 | 「边下边播」的实现基础 |
| ETag / 长度变化整份缓存作废重建 | 保留 | 避免喂旧字节 |
| `sanitizeKey`、`Semaphore`、`AsyncMutex` | 保留 | 安全边界与并发正确性 |
| 上游客户端 HEAD / 206 / 200 裁剪 / 连接池 / `_discard` / 超时 | 保留 | 上游健壮性 |
| LRU 淘汰 + `maxCacheBytes` + 目录扫描 + 孤儿清理 | 移除 | 与核心职责正交；同时消除周期性递归目录扫描与 5 秒节流定时逻辑，属净收益。代价：缓存目录不再自动回收，需在 README「已知限制」写明由使用方管理 |
| 统计 stats（`CacheStats` / `CacheEntryStats` / 各计数 getter） | 移除 | 纯观测用途；断言改由测试替身的请求记录与磁盘文件完成 |
| 断连续传背景填充（`continueAfterDisconnect` / `whenIdle` / `_startBackgroundFill` / `firstUncachedOffset` / `isRangeCached`） | 移除 | 库内最大的跨请求时序复杂度来源。**保留**「已发起的在途分片请求不随消费者取消、照常落盘」这一核心特性 |
| 顺序预取 `prefetchAhead` + `_schedulePrefetch` | 移除 | 可选平滑度优化；代价是顺序播放按需逐分片取（仍为 single-flight），README 可注明可后加 |
| `DiskCache.clear` / `flush` / `CacheEntry.deleteFiles` | 移除 | 仅服务于淘汰与手工清理；保留 `close()` 完成元数据落盘 |
| `parseByteSize`（CLI 遗留）、`LogLevel.tryParse`、`countChunkBitmapBits`、`isValidKey`、`acceptsRanges`、`isUnsatisfiable` / `wantsFullBody` | 移除 | 库内零调用者 |
| 日志 ANSI 着色、`Logger.configure` / `captureOutput` / `reset` | 移除 | 改为 `Logger.level` + 可替换 `Logger.sink`（默认 stdout），职责更小 |
| `Config.describe` / `logLevel` / `cacheDirectory` | 移除 | `describe` 仅供示例打印；`logLevel` 与全局 Logger 重复；`VideoProxy` 自行构造 `Directory`，使 `config.dart` 不再依赖 `dart:io` |
| `ByteRange` 的 `==` / `hashCode` | 保留 | 测试与上游替身按值比对区间，属真实使用者，且仅 5 行 |
| `CacheEntry.readyChunkCount`、`DiskCache.root` | 保留 | 测试用于证明缓存命中与目录镜像，各 1 行 |


**性能影响**：移除 LRU 后不再有「每次落盘触发预算检查」与统计 `stats()` 触发的递归目录扫描，热路径上的 I/O 与分配净减少；移除预取后顺序场景每分片多一次上游往返，但并发上限与 single-flight 不变，总请求数与旧实现一致（旧实现亦为按需 + 可选预取）。

**技术债控制**：不新增分层或模式，只做删除、合并与表达简化；异常类型（`OriginNotFoundException` / `OriginTruncatedException` / `OriginRequestException`）保持不变，`MediaProxy` 到 404 / 502 / 504 的映射行为不变。

## 实施要点

- **格式化与 lint**：`require_trailing_commas` 与 tall-style，改动后必须跑 `dart format .` 与 `dart analyze`；`strict-casts` 下不要用 `as` 强转 `jsonDecode` 结果，沿用 `is` 判定。
- **保留的可靠性细节**：元数据写盘仍走 `<file>.tmp` 写入 + 删除 + `rename` 的原子替换；分片仍 `writeFrom` + `flush` 后才加入 ready 集合；`FileMode.append` + 显式 `setPosition` 以保留上一进程已缓存的分片；`response.bufferOutput = false` 且下发前 `flush()` 头部。
- **日志**：沿用现有 `fields` 结构化风格与 `debug` / `info` / `warn` / `error` 级别；不输出密钥与二进制体（保留 512 字符截断与 `List<int>` 折叠为字节数）。
- **爆炸半径**：仓库内只有 `lib/`、`example/proxy_server.dart`、`test/**`、`README.md` 引用本库（`tool/`、`web/` 为空），不改 `pubspec.yaml`、不改 `analysis_options.yaml`。
- **一致性**：改完 API 后，README 字段表、示例与文档注释必须与代码同源，禁止留下已删除能力（`maxCacheBytes`、`prefetchAhead`、`continueAfterDisconnect`、stats）的描述。

## 架构与分层

保持现有单层直线调用，不新增抽象：

```
HttpServer request
   -> VideoProxy.serve(key)
        -> MediaProxy      HTTP <-> 缓存 的翻译层：Range 语义、状态码、响应头
   -> DiskCache.entryFor(key)   key -> 文件映射 + Entry 注册表
        -> CacheEntry      分片状态机：single-flight、落盘、元数据
             -> OriginClient (HttpOriginClient)  HEAD + Range 上游读取
```

依赖方向单向向下；`lib/src/util.dart` 只提供无状态原语（Range 解析、key 校验、Content-Type、HTTP 日期、信号量、互斥量），不反向依赖上层。

## 目录结构

目标：14 个文件精简为 8 个，`src/` 扁平化，去掉 `cache/`、`proxy/`、`util/` 子目录。

```
lib/
├── proxy_video.dart          # [MODIFY] 库入口。`library` 文档收敛；export 列表同步为新的 7 个 src 文件
└── src/
    ├── config.dart           # [MODIFY] Config 精简为 6 个字段：originBaseUrl / cacheDirPath / chunkSize /
    │                         #   maxConcurrentUpstream / upstreamTimeout / connectTimeout；保留 validate()、urlFor()、
    │                         #   kDefaultChunkSize / kDefaultMaxConcurrentUpstream；移除 describe() / logLevel /
    │                         #   cacheDirectory / maxCacheBytes / prefetchAhead / continueAfterDisconnect 及
    │                         #   kDefaultMaxCacheBytes；不再 import dart:io；注释收敛到契约要点
    ├── logger.dart           # [MODIFY] 保留 LogLevel（label、index 比较）、LogOutput、rootLogger、child、
    │                         #   debug/info/warn/error、时间戳、fields 渲染与脱敏；移除 tryParse、colorEnabled、
    │                         #   _paint、_detectColor、configure、captureOutput、reset；改为静态 level + sink
    ├── util.dart             # [NEW] 合并 util/byte_range.dart、http_util.dart、semaphore.dart、async_mutex.dart：
    │                         #   ByteRange(length/contentRange/==/hashCode)、RangeParseKind、RangeParseResult
    │                         #   (parse/note/unsatisfiedContentRange，去掉 isUnsatisfiable/wantsFullBody)、
    │                         #   sanitizeKey、contentTypeForPath、formatHttpDate、parseHttpDate、
    │                         #   Semaphore(仅 withPermit/acquire/release，去掉 tryAcquire/waiting/isIdle/timeout/available/inUse)、
    │                         #   AsyncMutex(run/isIdle)；Range 解析算法逐字保留
    ├── origin.dart           # [NEW] 合并 cache/origin_client.dart 与 proxy/http_origin_client.dart：
    │                         #   OriginMetadata(去 acceptsRanges)、3 个异常、抽象 OriginClient、
    │                         #   HttpOriginClient(HEAD 解析、206 直通、200 裁剪、404/416/其它映射、_discard/_readBody)
    ├── cache.dart            # [NEW] 合并 cache/cache_entry.dart 与 cache/disk_cache.dart：
    │                         #   chunkCountFor、encode/decodeChunkBitmap（去 countChunkBitmapBits）、CacheEntryMeta、
    │                         #   CacheEntry（resolveTotalSize/readRange/ensureChunk/persistMeta/dispose/readyChunkCount，
    │                         #   去统计计数、isComplete/cachedBytes/chunkCount/touch/lastAccessAt/isBusy/
    │                         #   onChunkCached/prefetchAhead、_schedulePrefetch、isRangeCached/firstUncachedOffset、deleteFiles）、
    │                         #   DiskCache(entryFor/close/root，去 stats/peekEntry/isFullyCached/clear/enforceBudget/
    │                         #   _scanFiles/_onChunkCached/flush/trackedBytes/entryCount)
    ├── media_proxy.dart      # [NEW] 由 proxy/media_proxy.dart 改名并精简：去掉 continueAfterDisconnect、
    │                         #   _backgroundFills/whenIdle/_startBackgroundFill、backgroundFillCount/Total；
    │                         #   保留状态码映射、HEAD、响应头、_pump 的 clientGone/failed 判定与日志
    └── video_proxy.dart      # [MODIFY] 装配层同步：Directory(config.cacheDirPath)、去掉 whenIdle 与已删字段；
                              #   精简 close() 与类文档
lib/src/util/byte_range.dart  # [DELETE] 内容并入 util.dart
lib/src/util/http_util.dart   # [DELETE] 内容并入 util.dart
lib/src/util/semaphore.dart   # [DELETE] 内容并入 util.dart
lib/src/util/async_mutex.dart # [DELETE] 内容并入 util.dart
lib/src/util/byte_size.dart   # [DELETE] 两个函数均无调用者，整文件删除
lib/src/cache/origin_client.dart # [DELETE] 并入 src/origin.dart
lib/src/proxy/http_origin_client.dart # [DELETE] 并入 src/origin.dart
test/byte_range_test.dart     # [MODIFY] 去掉 wantsFullBody / isUnsatisfiable 断言，其余用例保留
test/http_util_test.dart      # [MODIFY] 去掉 isValidKey 用例，sanitizeKey / contentTypeForPath / HTTP 日期用例保留
test/util_test.dart           # [MODIFY] 删除 parseByteSize / formatByteSize 两组；Semaphore 用例改为覆盖 withPermit 与
                              #   release 越界抛错；Logger 用例改用 Logger.sink 捕获
test/disk_cache_test.dart     # [MODIFY] 删除 budget enforcement 组（LRU / clear / stats）与 countChunkBitmapBits 断言；
                              #   openCache 去掉 maxBytes；断言改用上游替身的 requestedRanges / rangeRequestCount 与磁盘文件
test/media_proxy_test.dart    # [MODIFY] startRig 去掉 maxBytes / continueAfterDisconnect，Rig.dispose 去掉 whenIdle；
                              #   disconnects 组保留「在途分片仍落盘」，把两个背景填充用例改写为「断开后再请求不再回源已缓存分片」
test/helpers/test_origin.dart # [MODIFY] FakeOrigin / GatedOrigin 仅去掉 openCache 相关签名变化引起的适配，接口不变
test/helpers/origin_server.dart # [MODIFY] 仅在签名不匹配时微调（真实 HttpServer 上游替身，无被裁 API 依赖）
example/proxy_server.dart     # [MODIFY] 去掉 config.describe() 与 Logger.configure(level: config.logLevel)，直接设置 Logger.level
README.md                     # [MODIFY] 重写 Config 字段表、目录树、缓存章节与「已知限制」；删去淘汰 / 统计 /
                              #   断连续传 / 预取 / logLevel 的说明；新增「缓存目录不自动回收」的限制
```

## 关键接口（精简后的公开形状）

```
// lib/src/config.dart
class Config {
  Config({
    required this.originBaseUrl,
    required this.cacheDirPath,
    this.chunkSize = kDefaultChunkSize,
    this.maxConcurrentUpstream = kDefaultMaxConcurrentUpstream,
    this.upstreamTimeout = const Duration(seconds: 30),
    this.connectTimeout = const Duration(seconds: 10),
  });

  final Uri originBaseUrl;
  final String cacheDirPath;
  final int chunkSize;
  final int maxConcurrentUpstream;
  final Duration upstreamTimeout;
  final Duration connectTimeout;

  Uri urlFor(String key);
  void validate();
}
```

```
// lib/src/cache.dart
class CacheEntry {
  Future<int> resolveTotalSize();
  Stream&lt;List&lt;int&gt;&gt; readRange(int start, int end);
  Future&lt;Uint8List&gt; ensureChunk(int index);
  Future&lt;void&gt; persistMeta({bool force});
  Future&lt;void&gt; dispose();
  int get readyChunkCount;
}

class DiskCache {
  DiskCache({
    required Directory root,
    required int chunkSize,
    required OriginClient origin,
    int maxConcurrentUpstream = 4,
    Logger? log,
  });

  Future&lt;CacheEntry&gt; entryFor(String key);
  Directory get root;
  Future&lt;void&gt; close();
}
```

`Logger` 的公开面由 `Logger([name])`、静态 `level` / `sink`、`child(name)`、`debug/info/warn/error` 组成，签名与现有 `fields` / `error` / `stackTrace` 具名参数保持一致。

## Agent Extensions

### Skill

- **dart-use-pattern-matching**
- Purpose: 在精简 `media_proxy` / `origin` 的状态码与异常分支时，用 switch 表达式与记录类型替代多段 if-else 链。
- Expected outcome: 控制流更短、无遗漏分支，且 `dart analyze` 保持零告警。
- **dart-add-unit-test**
- Purpose: 按精简后的公开 API 重写 5 个测试文件与测试替身，补齐核心行为的回归覆盖。
- Expected outcome: `test/` 全部用例通过，并以 `package:test` 的惯用分组组织。
- **dart-run-static-analysis**
- Purpose: 执行 `dart analyze` 与 `dart fix --apply`，清除机械性 lint 问题并确认无残留告警。
- Expected outcome: `dart analyze` 输出无 error / warning，`dart format` 无差异。

### MCP

- **dart**
- Purpose: 用 `analyze_files` 对改动后的 `lib/`、`example/`、`test/` 做定点静态分析；必要时用 `lsp` 的引用查询确认被删符号已无调用点。
- Expected outcome: 每个改动文件均无诊断信息，且被删 API 在全仓库确实无引用。

### SubAgent

- **code-explorer**
- Purpose: 在精简完成后做一次「很彻底」的爆炸半径复核，确认没有残留的引用、注释或文档仍指向被移除的类型与成员。
- Expected outcome: 输出一份残留引用清单（预期为空），作为验收证据。