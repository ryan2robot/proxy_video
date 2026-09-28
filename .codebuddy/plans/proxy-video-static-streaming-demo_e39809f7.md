---
name: proxy-video-static-streaming-demo
overview: 新增一个不依赖 Dart 服务的纯静态 HTML 演示页（可 file:// 直接打开），用"播放进度 vs 代理已缓存分片"双轨进度条直观展示边下边播；并新增一个只读 SSE 分片事件接口（含 file:// 场景所需的 CORS 支持）让"正在下载哪个分片"实时可见。
design:
  architecture:
    framework: html
  styleKeywords:
    - Dark Glassmorphism
    - Neon Gradient
    - Data Dashboard
    - Technical
    - Micro-animation
  fontSystem:
    fontFamily: Noto Sans
    heading:
      size: 28px
      weight: 700
    subheading:
      size: 16px
      weight: 600
    body:
      size: 14px
      weight: 400
  colorSystem:
    primary:
      - "#6366F1"
      - "#8B5CF6"
      - "#22D3EE"
    background:
      - "#0B0F1A"
      - "#111827"
      - "#1F2937"
    text:
      - "#F9FAFB"
      - "#9CA3AF"
      - "#6B7280"
    functional:
      - "#10B981"
      - "#EF4444"
      - "#F59E0B"
      - "#38BDF8"
todos:
  - id: cache-chunk-events
    content: 新增 ChunkEvent 事件模型与 CacheEntry 分片事件回调、DiskCache 广播流（含 close 释放），不改动既有 onChunkCached 与单飞/落盘逻辑
    status: completed
  - id: cors-and-config
    content: 新增 CORS 支持与 --cors auto|on|off 配置项：响应头注入、_dispatch 内 OPTIONS 短路、describe/启动横幅体现，保持既有 404/405 语义不变
    status: completed
  - id: sse-endpoint
    content: 实现只读 /api/events SSE：SSE 写响应辅助与 kEventStreamContentType、DiskCache.statsFor、snapshot/chunk/ping 报文与心跳、断连清理；用 [skill:dart-use-pattern-matching] 组织报文编码
    status: completed
    dependencies:
      - cache-chunk-events
      - cors-and-config
  - id: demo-page
    content: 新增 web/streaming-demo.html 单文件演示页（连接栏、播放舞台、双轨进度、分片网格、指标、EventSource 订阅 + rAF 合并渲染 + 轮询降级），并在 AppServer 注册 GET /demo 托管该文件
    status: completed
    dependencies:
      - sse-endpoint
  - id: tests
    content: 用 [skill:dart-add-unit-test] 补齐测试：缓存事件流、/api/events 推送与 CORS 头、config 的 --cors 解析、/demo 路由缺失文件的降级
    status: completed
    dependencies:
      - cache-chunk-events
      - cors-and-config
      - sse-endpoint
  - id: docs-verify
    content: 更新 README 的页面/接口表格、启动提示与 CORS 说明，并用 [skill:dart-run-static-analysis] 与 [mcp:dart] analyze_files 确认零告警
    status: completed
    dependencies:
      - tests
      - demo-page
---

## 产品概述

为已具备"边下边播"能力的本地视频代理，提供一个可独立打开的演示网页。打开后能一边播放视频，一边实时看到代理在后台把视频按分片缓存下来的过程，直观证明"还没下载完就能播放、拖动进度条不会重新下载"。

## 核心功能

- 单文件演示页：可双击直接在浏览器打开（页面内填写服务地址），也可由服务托管后同源打开；
- 视频选择与播放：可从已发布列表选择视频，也可手填标识，随后在页面内播放；
- 播放/缓存双轨进度：一条表示已播放到的位置，一条表示代理已缓存下来的比例，两条进度相互追赶，未缓存完也能正常播放；
- 实时指标：已缓存大小、分片数量与分片粒度、上游请求次数、缓存命中率、当前并发下载数、播放器已缓冲时间区间；
- 分片状态网格：每个小格代表一个缓存分片，正在下载的高亮跳动，下载完的变为已缓存颜色，随播放推进逐格点亮；
- 快捷跳转：一键跳到 25% / 50% / 75% / 片尾，用于展示"跳转命中缓存、不重新下载"；
- 只读实时事件通道：服务端把分片"开始下载 / 下载完成"即时推送到页面；通道不可用时页面自动回退为轮询，展示不中断。

## 视觉与交互效果

深色玻璃拟态界面，青色/紫色/靛蓝渐变强调，进度条带流光动画、分片格子有脉冲高亮；指标数字等宽字体对齐，整体呈现"技术仪表盘"观感。窄屏时双栏自动堆叠为单栏。

## 技术栈选择

- 服务端：Dart（SDK ^3.8）保持现状，**不新增任何依赖**。SSE 复用 `dart:io` 的 `HttpResponse` 流式写（参考 `lib/src/proxy/media_proxy.dart` L183 `bufferOutput=false` + L228/L304 `flush()`），事件源用 `dart:async` 的 `StreamController.broadcast()`。
- 演示页：**单文件 HTML**，内联手写 CSS + 原生 JS（`EventSource` / `fetch` / `<video>`），零构建、零 CDN，符合 README「页面不引外部资源」的既有基调；视觉效果与渲染思路复用 `lib/src/web/play_page.dart` 的 `_styles`(L49-269) 与 `renderBits`(L662)。

## 实现方案

- **事件驱动替代轮询**：在缓存层新增一个轻量的分片事件广播（`started` / `ready`），经 `/api/events` 以 SSE 下发；页面用 `EventSource` 订阅，实时点亮"正在下载"的分片，而不是靠位图反推（现有页面 L706 的紫色 `hot` 只是"位图未满"的近似）。
- **最小侵入的 CORS 放开**：静态页以 `file://` 打开时 `Origin` 为不透明的 `null`，必须在响应上回 `Access-Control-Allow-Origin: *` 才能 fetch/EventSource。按项目既有安全基调（默认仅回环、非回环已告警）设计为**默认 auto**：仅监听回环时放开，非回环需显式开启。
- **诚实可视化**：分片是**字节维度**（默认 1 MiB），映射到时间轴按字节比例近似，页面上明确标注；同时并列展示播放器真实 `video.buffered` 时间区间，两者差异本身就是"边下边播"的直接证据。
- **优雅降级**：SSE 不可用（浏览器/网络策略）时自动回退到 `/api/stats?key=` 轮询，核心展示不丢失。
- **兼容兜底**：额外提供 `GET /demo` 由服务托管同一份 HTML（同源打开，完全绕开 `file://` → `127.0.0.1` 的浏览器策略风险）；HTML 文件本身仍可独立双击打开。

### 关键决策与取舍

1. **不改 `Router` 语义**：`lib/src/server/router.dart` 只有 `get/post/delete`（L71/L75/L79），`allowedMethods` L105 硬编码方法集合。为避免触碰既有 404/405 行为（`test/server_test.dart` L243-252 有用例），CORS 预检在 `AppServer._dispatch`(L184) 中**短路处理 `OPTIONS`**，路由表不动。
2. **不覆盖既有回调**：`CacheEntry.onChunkCached`(L209/L605) 已被 `DiskCache._onChunkCached`(L401-405) 的预算逻辑独占且不带分片号，因此**新增独立回调** `onChunkEvent`，两者语义不重叠。
3. **事件源挂实例**：`DiskCache` 非单例（`bin/server.dart` L127 构造、`app_server.dart` L48 持有），`StreamController` 随之 `close()` dispose（`bin/server.dart` finally L183-187 已调用 `cache.close()`），避免退出时被挂起连接/定时器拖住。
4. **SSE 不复用写响应工具**：`writeJson`/`writeText`/`writeProblem`(http_util.dart L182-233) 会设置 `Content-Length` 并立即 `close()`，长连接必须走 `bufferOutput=false` + 手动 flush。

### 性能与可靠性

- 事件频率低（约 1 事件/分片；1 MiB 分片 + 限速下约 1-2 事件/秒），广播为 O(1)/订阅者，单 key 过滤在**服务端**完成；`/api/events` 初始下发一次 `snapshot`，避免页面额外轮询。
- 客户端用 `requestAnimationFrame` 合并渲染（现有 `renderBits` L667-669 会把 4096 分片折叠成 ≤320 格，若每个事件都重建 DOM 会造成明显抖动）。
- 15s 心跳保活，防止中间层断开；`response.done` / 写异常时取消订阅与定时器。
- `/api/events` 仅调用 `peekEntry`（L245，无目录 IO），不从 `stats()`(L255) 触发 `_scanFiles`，避免连接风暴时的磁盘扫描。

## 架构设计

```mermaid
graph LR
  V[浏览器 video 发起 Range] --> P[MediaProxy /media/**]
  P --> C[CacheEntry 分片下载]
  C -- started / ready --> E[DiskCache 事件广播]
  E --> S[/api/events SSE 只读通道]
  S --> D[演示页 EventSource]
  F[/api/stats 轮询 降级] --> D
  D --> UI[双轨进度 + 分片网格 + 指标]
```

## 关键代码结构

```
// lib/src/cache/chunk_event.dart [NEW]
enum ChunkPhase { started, ready }

class ChunkEvent {
  const ChunkEvent({
    required this.key,
    required this.index,
    required this.chunkCount,
    required this.phase,
    required this.readyChunks,
  });
  final String key;
  final int index;
  final int chunkCount;
  final ChunkPhase phase;
  final int readyChunks;
}

// lib/src/cache/disk_cache.dart [MODIFY] 新增（非单例，随 close() 释放）
Stream<ChunkEvent> get events;              // broadcast
CacheEntryStats? statsFor(String key);      // 复用 peekEntry，无 IO
```

**SSE 报文格式**（`event: <name>\ndata: <json>\n\n`）：

- `snapshot`：`{key,totalSize,chunkSize,chunkCount,readyChunks,cachedBytes,cachedFraction,complete,chunkBitmap,upstreamRequests,cacheHits,cacheMisses,cacheHitRate}`（复用 `CacheEntryStats.toJson()` 既有键名，disk_cache.dart L84-101）
- `chunk`：`{key,index,chunkCount,phase:"started"|"ready",readyChunks}`
- `ping`：心跳

## 实现要点

- **配置**：按 `config.dart` 既有模式（CLI > env > 默认）新增 `--cors auto|on|off` 与 `PROXY_VIDEO_CORS`，默认 `auto`（= `servesLoopbackOnly`，L308），并在 `validate()`(L344) / `describe()`(L427) / `bin/server.dart` 启动横幅中体现；`Config.copyWith`(L385) 同步该字段。
- **不改既有语义**：`/`、`/play/<key>`、`/media/**` 的状态码与 Range 行为保持不变；新增仅 `/api/events`（只读 GET）与 `/demo`（只读 GET）。
- **视频不要加 `crossorigin`**：媒体元素默认非 CORS 请求，跨域播放本身不受限制；加上反而会引入新的约束。
- **日志**：沿用 `Logger` 分级（分片级已有 `log.debug('chunk cached')` L594），SSE 连接只记 info 一次，不做逐事件日志，避免刷屏；不打印 payload 内容。
- **Windows 注意**：`/demo` 读取 `path.join(config.projectRoot, 'web', 'streaming-demo.html')`，用 `package:path` 拼路径；文件缺失时回 404 problem 而非 500。
- **回归保护**：改动集中在新文件与少量新增分支，先跑 `dart analyze` 与 `dart test` 确认既有 12 个测试全绿。

## 设计风格

延续现有 `play_page.dart` 的暗色玻璃拟态基调，加入更强的"数据仪表盘"表达：深色背景 + 大范围彩色光晕、半透明毛玻璃卡片、青色到紫色的渐变强调。单文件、内联手写 CSS，零外部资源，断网可用。

## 页面结构（单页 /demo，自上而下分块）

1. **顶栏**：品牌标识（渐变文字 + 呼吸光点）、当前视频标识、连接方式胶囊（实时通道 / 轮询 / 未连接）。粘性置顶、背景模糊。
2. **连接栏**：服务地址输入框（`file://` 打开时预填 `http://127.0.0.1:8080`，经 `/demo` 打开时自动取同源）、视频下拉（取自已发布列表）、连接按钮；右侧一行小字提示填写方式。
3. **播放舞台**：居中的视频卡片，圆角、描边微光、播放时有渐变色晕随进度呼吸；下方一行时间与播放状态。
4. **双轨进度**：两条堆叠的进度条相互追赶——上条为"已缓存"（渐变填充 + 流光），下条为"已播放"（亮色滑块）；并叠加播放器已缓冲区间与播放头标记，旁注"分片为字节维度，时间轴为近似映射"。
5. **分片网格**：小方格矩阵，已缓存为绿色、正在下载为紫色脉冲跳动、未下载为暗格；大文件自动折叠为 ≤320 格取平均，避免卡顿。
6. **指标与页脚**：已缓存字节、分片数/粒度、上游请求次数、命中率、并发下载数等键值对；页脚固定一行全局状态（并发占用、最近事件时间）。

## Agent Extensions

### Skill

- **dart-add-unit-test**
- Purpose: 为新增的分片事件广播、`/api/events` SSE、CORS 头与配置项编写 `package:test` 用例（沿用 `test/server_test.dart` 的起服务写法与 `test/helpers/test_origin.dart` 的 `GatedOrigin`/`FakeOrigin` 控制时机）。
- Expected outcome: 新增缓存层事件流测试、SSE 能随分片就绪推出事件的集成测试、CORS 头断言与 `--cors` 解析测试全部通过。
- **dart-use-pattern-matching**
- Purpose: 用 Dart 3 switch 表达式/模式匹配组织事件类型与 SSE 帧的编码分支，保持与项目风格一致。
- Expected outcome: 事件模型与报文编码集中、无重复分支，`dart analyze` 无告警。
- **dart-run-static-analysis**
- Purpose: 改动完成后执行 `dart analyze` 与 `dart fix --apply`，确保零告警且符合 `require_trailing_commas` 等既有 lint 规则。
- Expected outcome: 全仓静态分析通过，无新增警告。

### MCP

- **dart**
- Purpose: 用 `analyze_files` 对本次改动的 `lib/src/cache`、`lib/src/api`、`lib/src/server`、`lib/src/config.dart` 做定点分析与符号校验。
- Expected outcome: 改动文件无错误/警告，接口签名与调用点一致。