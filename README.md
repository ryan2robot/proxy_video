# proxy_video

本地可运行的视频点播管线：**ffmpeg 转码 → 上传对象存储 → Dart HTTP 代理（磁盘分片缓存 + Range 支持）→ 浏览器边下边播**。

核心是一件事：浏览器 `<video>` 播放时会自动发起 HTTP Range 请求，代理必须正确返回
`206 Partial Content` / `Content-Range` / `Content-Length` / `Accept-Ranges`，并把读到的每一段字节
**先落盘再下发**，才能既实现边下边播、又让下一次播放或拖动进度条零上游请求。

```
┌──────────────┐   ffmpeg    ┌──────────────┐   HTTP PUT   ┌───────────────┐
│  本地视频文件 │ ──────────▶ │ faststart MP4 │ ──────────▶ │ Storage 抽象   │
└──────────────┘             └──────────────┘              │ local / COS   │
                                                           └───────┬───────┘
                                                                   │ HTTP GET + Range
                                                                   ▼
   ┌─────────┐   Range/206    ┌────────────────────┐   Range    ┌──────────────┐
   │ 浏览器   │ ◀────────────▶ │ 代理 /media/<key>   │ ◀────────▶ │ Origin Server │
   │ <video> │   边下边播      │ 分片磁盘缓存 + tee  │   206      │  模拟 CDN     │
   └─────────┘                └────────────────────┘            └──────────────┘
```

代理**只通过 HTTP 读上游**，从不解开存储的本地路径。这样把真实 COS/CDN 换进来只是配置变化，
而不是代码变化。

---

## 快速开始

无需联网、无需全局安装：`dart pub get` 即可（依赖都在本地 pub 缓存里）。

```bash
dart pub get                      # 拉取依赖
dart run bin/pipeline.dart --demo # 用 ffmpeg 合成一段 12s 示例并上传
dart run bin/server.dart          # 启动服务，按提示打开 library 地址
```

打开打印出来的地址（默认 <http://127.0.0.1:8080>），在媒体库里点 **Play** 即可播放。
播放页右侧是缓存诊断面板，可以看到分片位图、已缓存字节、上游请求次数与命中率。

### 完整验证

```bash
dart analyze                      # 静态分析
dart test                         # 单元 + 集成测试（含真实 ffmpeg 与真实 HTTP 链路）
dart run tool/e2e_smoke.dart       # 端到端冒烟：真实起两个 CLI 子进程跑完整链路
```

---

## 使用

### 1. 转码并上传

```bash
# 合成一段示例视频（无需自备素材）
dart run bin/pipeline.dart --demo --key demo.mp4 --demo-duration 12

# 转码本地文件
dart run bin/pipeline.dart --input "D:\videos\movie.mov" --key clips/movie.mp4

# 调整编码参数，保留中间产物
dart run bin/pipeline.dart -i movie.mov -k clips/movie.mp4 --crf 20 --preset slow --keep-transcoded

# 查看已发布对象
dart run bin/pipeline.dart --list
```

转码参数固定为 `libx264 + aac + -pix_fmt yuv420p + -movflags +faststart`。
其中 `+faststart` 是边下边播的前提：它把 MP4 索引（`moov`）移到媒体数据（`mdat`）之前，
播放器才能在只读到文件开头时就算出该请求哪个字节区间。

### 2. 启动服务

```bash
dart run bin/server.dart                          # 代理 8080，模拟 origin 8090
dart run bin/server.dart --port 9000 --origin-port 9001
dart run bin/server.dart --chunk-size 256K        # 更小的分片 = 更快的首帧
dart run bin/server.dart --origin-throttle 1M     # 把上游限速到 1MB/s，肉眼观察边下边播
dart run bin/server.dart --max-cache-bytes 512M   # 缓存预算，超出按 LRU 淘汰
```

页面：

| 路径 | 说明 |
| --- | --- |
| `/` | 媒体库：卡片网格、转码上传面板、缓存/上游状态栏 |
| `/play/<key>` | 播放页：`<video>` + 分片缓存诊断面板 |

接口：

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| `GET` | `/media/<key>` | **核心代理**，支持 `Range` |
| `GET` `HEAD` | `/api/media` | 已发布对象列表（含缓存进度） |
| `GET` | `/api/stats[?key=]` | 缓存总览，或单个 key 的分片状态 |
| `GET` | `/api/jobs` `/api/jobs/<id>` | 转码任务列表 / 单个任务 |
| `POST` | `/api/transcode` | 提交转码任务，body：`{"input"\|"demo", "key", "crf", "preset", "duration"}` |
| `POST` | `/api/cache` | 清空缓存，body：`{"key": "..."}`（省略 key 清空全部） |
| `GET` | `/healthz` | 存活与关键配置 |

### 3. 存储后端

| 后端 | 触发条件 | 行为 |
| --- | --- | --- |
| `local`（默认） | 未配置 COS 凭据 | 写入 `<data-dir>/origin/<key>`，由本机 Origin Server 以 HTTP 提供 |
| `cos` | 设置 `COS_SECRET_ID` / `COS_SECRET_KEY` / `COS_BUCKET` / `COS_REGION`（可选 `COS_CDN_DOMAIN`） | 走 `CosStorage`，读取走 CDN 域名 |

```bash
export COS_SECRET_ID=... COS_SECRET_KEY=... COS_BUCKET=... COS_REGION=ap-guangzhou
export COS_CDN_DOMAIN=cdn.example.com
dart run bin/server.dart --storage cos
```

`CosStorage` 只依赖一个窄接口 `CosClient`（`putObject` / `headObject` / `deleteObject` / `listObjects`），
用真实 SDK 适配只需几十行：

```dart
Storage buildCos(Logger log) => CosStorage(
  credentials: credentials,
  client: MyCosSdkClient(credentials),   // 你的适配器
  log: log,
);
```

未注册实现时不会静默假装成功，而是在第一次使用时抛出 `CosNotConfiguredException`，
避免"上传成功"的日志对应着一个其实没离开本机的文件。

---

## Range 语义

这是整个项目的正确性核心，全部由 `lib/src/util/byte_range.dart` 一处实现，并被测试逐条固化：

| 请求 | 响应 |
| --- | --- |
| 无 `Range` | `200` + `Content-Length: <total>` + `Accept-Ranges: bytes` |
| `HEAD` | `200`（或 `206`）+ 头部，无响应体 |
| `Range: bytes=0-` | `206` + `Content-Range: bytes 0-<total-1>/<total>` |
| `Range: bytes=s-e` | `206` + `Content-Range: bytes s-e/<total>`，`Content-Length = e-s+1` |
| `Range: bytes=-N`（后缀） | 等价于 `<total-N>-<total-1>` |
| 越界 `s >= total` | `416` + `Content-Range: bytes */<total>` |
| 多段 `bytes=0-9,20-29` | 忽略 Range，返回 `200` 全量（RFC 允许，最稳妥） |
| 非法 / 未知单位 | 忽略 Range，返回 `200` 全量 |

另外：`Content-Length` 在 `206` 时永远是**区间长度**而非对象长度；响应使用
`HttpResponse.bufferOutput = false` 并在下发前 `flush()` 头部，播放器无需等到第一个字节就能
知道对象大小并决定在哪里缓冲。

### 边下边播与缓存写入

对象按 `chunk-size`（默认 1 MiB）切成固定分片，`CacheEntry` 维护三件事：

1. **先落盘再下发** —— 分片先 `writeFrom` + `flush` 到 `.bin` 文件，之后才把字节交给客户端。
   因此中途断开永远不会丢已经取回的字节，也不会把半个分片标成可用。
2. **single-flight** —— 同一个分片的并发请求合并成一次上游请求。浏览器 seek 造成的请求突发
   不会放大成对 origin 的请求突发。
3. **读时填充** —— `readRange` 顺序 `ensureChunk`，新下载的分片直接从内存交给当前消费者，
   已缓存的分片从磁盘读，天然就是 tee。

缓存元数据（`totalSize` / `chunkSize` / 分片位图 / `ETag`）以 `*.meta.json` 持久化，
分片位图用 base64 位图编码（4 GiB 文件在 1 MiB 分片下只有约 700 字节），并且**节流写入**
（1 秒或累积 32 个分片才落一次盘），不会因为边看边下产生写放大。

上游对象被替换时（`ETag` 或 `content-length` 变化）整份缓存作废重建，避免把旧字节喂给新视频。

### 客户端断开

- 已经发起的分片下载**不受客户端影响**：它是独立 Future，消费者取消 stream 不会取消它，
  分片照常落盘。
- 已经写出去一半、但连接真断了的窗口，会从**第一个未缓存的分片**继续在后台补完
  （`--no-continue-after-disconnect` 可关闭）。

需要注意的是，"连接是否真的断了"在客户端单方面停止读取时并不总能立刻察觉——本机回环上
需要写满 socket 缓冲区才会报错。所以保证"不丢字节"的机制是上面的第 1 条（先落盘再下发），
后台续传只是尽力而为的额外优化。

---

## 架构

```
bin/pipeline.dart        转码 + 上传 CLI
bin/server.dart          组装并启动服务，处理优雅关闭
lib/src/
  config.dart            配置聚合：CLI > 环境变量 > 默认值，含启动校验
  logger.dart            分级结构化日志（默认屏蔽二进制与超长文本）
  media/                 ffmpeg 定位、探测、转码进度解析
  storage/               Storage 抽象 + local（模拟 COS）+ COS 适配器
  origin/origin_server.dart   模拟 CDN：自实现 Range/206/HEAD/416 + 限速
  cache/                 分片状态机、磁盘布局、元数据、LRU
  proxy/                 HTTP 上游客户端 + 核心代理
  api/                   JSON API 与转码队列
  server/                手写路由 + 服务组装
  web/play_page.dart     自包含的媒体库与播放页（无 CDN、无构建步骤）
tool/e2e_smoke.dart      真实启动两个 CLI 的端到端冒烟
```

### 关键设计取舍

- **手写路由而不是 shelf**：本服务只需要 `:param` 和尾部 `**` 两种模式，全部路由不到十条；
  少一个依赖、少一层缓冲，换来对响应头与流式的完全控制。
- **Origin Server 是真实 HTTP 服务**，不是"直接读文件"的捷径。代理透传 `206` 的链路由真实
  socket 验证，而不是假设；它还提供 `--origin-throttle`，用于肉眼观察边下边播。
- **缓存目录镜像 key 结构**（`<cache>/clips/a.mp4.bin`）而不是哈希前缀。key 已被
  `sanitizeKey` 限制为 `[A-Za-z0-9._-]` 且拒绝 `..`、绝对路径、Windows 保留名，
  所以目录可读、不可能碰撞、也不会被穿越。
- **页面不引外部资源**：Tailwind CDN 之类会让页面在断网时失效，而这是个本地开发工具。

---

## 配置

优先级：**CLI 参数 > 环境变量 > 默认值**。

| 环境变量 | 默认值 | 说明 |
| --- | --- | --- |
| `PROXY_VIDEO_BIND` / `PROXY_VIDEO_PORT` | `127.0.0.1` / `8080` | 代理监听地址 |
| `PROXY_VIDEO_ORIGIN_BIND` / `PROXY_VIDEO_ORIGIN_PORT` | `127.0.0.1` / `8090` | 模拟 origin 监听地址 |
| `PROXY_VIDEO_DATA_DIR` | `<项目根>/data` | origin / cache / tmp 的根目录 |
| `PROXY_VIDEO_CACHE_DIR` | `<data>/cache` | 缓存目录 |
| `PROXY_VIDEO_CHUNK_SIZE` | `1M` | 分片大小，支持 `256K`、`1M`、`2G` 写法 |
| `PROXY_VIDEO_MAX_CACHE_BYTES` | `2G` | 缓存预算，`0` 表示不淘汰 |
| `PROXY_VIDEO_MAX_CONCURRENT_UPSTREAM` | `4` | 上游并发上限 |
| `PROXY_VIDEO_PREFETCH_AHEAD` | `0` | 顺序预取的分片数 |
| `PROXY_VIDEO_ORIGIN_THROTTLE` | `0` | 模拟 origin 限速 |
| `PROXY_VIDEO_LOG_LEVEL` | `info` | `debug` / `info` / `warn` / `error` |
| `FFMPEG_PATH` | 自动发现 | ffmpeg 可执行文件路径 |

ffmpeg 查找顺序：`--ffmpeg` → `$FFMPEG_PATH` → `<项目根>/tools/ffmpeg/ffmpeg[.exe]` → `PATH`。
全部失败时错误信息会列出所有尝试过的位置。

---

## 已知限制

- 代理不实现条件请求（`If-None-Match` / `If-Modified-Since`），因此不使用 `304`；
  `Cache-Control: no-store` 让浏览器每次都问代理，代理则从磁盘秒回。
- 上游必须支持 `HEAD` 并返回 `Content-Length`（COS 与主流 CDN 都支持）。
- 上游若忽略 `Range` 返回 `200`，代理会自行裁剪出请求区间；这条路径有测试覆盖。
- 不支持多段 Range（浏览器在播放媒体时也不会发），会降级成整文件 `200`。
- 转码任务串行执行：并发跑多个 x264 会抢走代理服务视频所需的 CPU。
- API 无鉴权，默认只监听回环地址；绑到非回环地址时会打警告。
