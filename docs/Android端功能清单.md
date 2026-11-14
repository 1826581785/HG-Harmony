# Android 端功能清单（HarmonyOS 移植参考）

> 源码基线：`D:\workspace\react\HuangGuo`（HGhub 1.0.1，commit a895fa8）。
> 本文只覆盖 **Android 端实际启用的功能**；桌面端独有功能（窗口壳、侧边栏、画中画、键盘快捷键、剧场模式）在文末单独列出，移植时默认不需要。
> 仅个人学习用途。

## 1. 应用概览

- **应用名**：HGhub（第三方客户端，仅供个人学习）
- **内容源**：单一第三方站点（下称「上游」，地址见源码 `src-tauri/src/net.rs` 的 `BASE` 常量）
- **架构**：React 19 + TS + Tailwind 4 前端 WebView 层 + Rust 业务层（Tauri 2 打包），两者通过 Tauri command（IPC）和自定义协议通信。
- **双端检测**：前端按 UA 判定 `platform = "android" | "windows"`（`src/api.ts:31`），Android 走无窗口壳的 `MobileShell`，顶部/底部使用 `env(safe-area-inset-*)` CSS 变量适配刘海与手势条。

移植到 HarmonyOS 时，Rust 层的全部协议、解密、下载、封装逻辑需要用 ArkTS 或 ArkTS+Native（C/C++ / 可能直接复用 Rust 编译到 OHOS）重写——这是最大的移植工作量所在。

## 2. 导航结构

### 2.1 底部标签栏（仅 Android，`src/App.tsx`）
- 4 个 Tab：**首页 / 搜索 / 分类 / 我的**；细瘦纯文字样式（42px 高，选中加粗 + 小圆点指示）。
- 首页是沉浸视频流，底栏透明悬浮在视频上（白字 + 阴影）；其余 Tab 有背景。
- 切换 Tab 会清空页面栈。
- **进入任何栈页（播放详情/图文/下载页等）后底栏隐藏**（这些页面是沉浸式的，底栏会挡住评论输入框）。

### 2.2 页面栈（`store.tsx` 的 `stack`）
可压栈的页面类型：
| 类型 | 说明 |
| --- | --- |
| `feed` | 播放信息流（视频列表 + 起始下标 + 标题，短剧/图文帖共用） |
| `channel` | 分类频道详情页 |
| `ranks` | 排行榜 |
| `posts` | 图文帖列表 |
| `post` | 图文帖详情 |
| `downloads` | 我的下载 |

### 2.3 Android 返回键处理（优先级从高到低，`App.tsx:221`）
1. 沉浸全屏播放中 → 退出全屏
2. WebView 原生全屏 → 退出
3. 播放器内面板（选集/评论/图文）打开 → 关面板
4. 登录弹窗打开 → 关弹窗
5. 页面栈非空 → pop
6. 当前 Tab 不是首页 → 回首页
7. 否则 → 退出应用

HarmonyOS 侧需要实现同级的 `onBackPress` 拦截链。

## 3. 页面功能明细

### 3.1 首页（`pages/Home.tsx`）
- 竖屏沉浸式短视频信息流（类似抖音），上下滑动切换（CSS scroll-snap 强制整屏）。
- 分页加载：每页 10 条，滑动到倒数第 3 条时预取下一页，按 id 去重，到底停止。
- 右上角悬浮按钮：**静音切换**、**搜索入口**（全屏时隐藏）。
- 默认静音（首次启动 `muted=true`），音量记忆上次设置（默认 0.7）。

### 3.2 播放页 / 信息流（`components/Feed.tsx`，核心组件）
短剧与图文帖共用同一套界面（`kind: "video" | "post"`）。

**内容加载**
- 当前条 + 前后各 1 条预取视频详情（`api.video`）。
- 按需取播放地址（`api.play(videoId, ep)`），按 `videoId:ep` 缓存在内存。
- 开始播放即写入观看历史（本地，最多 80 条）。
- 图文帖：拉帖子详情；**有视频则播视频，无视频显示"查看图文详情"入口**（图文用白名单清洗后的 HTML 渲染）。

**播放器行为**
- hls.js 播放 HLS（m3u8 经本地代理改写，AES-128 分片可播）；竖屏视频 `cover` 填充，横屏视频 `contain`（按视频实际分辨率自动判定）。
- 播放结束自动连播下一集；下一集不存在则不动。
- 倍速档位 1 / 1.25 / 1.5 / 2。
- 状态 UI：缓冲 spinner、暂停大按钮、出错卡片（显示错误信息 + 重试）。

**Android 手势（桌面无）**
- **单击**：暂停/恢复（260ms 内松手判定）。
- **长按 ≥380ms**：进入 2x 倍速（触发电机震动 `navigator.vibrate(25)`）；**长按期间上滑超过 64px → "松手锁定 2x"**，顶部出现锁定标签，点按解除。
- **横滑 >14px**：进入进度拖动模式（暂停播放，显示目标时间浮层 + 进度条，松手 seek 并恢复播放）。
- **竖滑**：上下切换视频。
- 长按倍速期间禁用列表原生滚动，防止上滑被列表吃掉。
- **底部进度条**：22px 热区、可拖动，拖动时显示时间气泡；平时 2.5px 高，拖动/全屏时 5px。
- **沉浸全屏**：应用内全屏层（Android WebView 不支持 Fullscreen API），顶部右上退出按钮，底部控制条：播放/暂停、时间、倍速循环切换。
- **横屏视频 + 全屏 → 舞台旋转 90°**（CSS transform 实现横屏观感，进度条按 Y 轴换算拖动）。
- **倍速状态胶囊**：顶部居中显示当前倍速/锁定状态。

**右侧操作栏（自上而下）**
- 作者头像 + 关注按钮（+ / ✓ 角标，本地记录关注状态，登录后同步服务端）
- **点赞**（爱心爆裂动画，计数 = 服务端计数 + 本地标记，登录后调 `api_like`）
- **评论**（打开底部弹层）
- **收藏**（星标，逻辑同点赞，登录后调 `api_collect`）
- **下载**（仅短剧；图标三态：下载 / 下载中 spinner / 已下载 ✓；重复添加有 toast 提示）
- **选集**（打开底部弹层）
- **分享**（复制链接到剪贴板：视频 = 上游详情页 URL（格式见 `src/components/Feed.tsx:611`），图文帖 = 视频直链）

**左下信息区**
- @作者名、`第 n/总 集` 徽章、评分（琥珀色）、标题（两行截断）。
- 简介：默认单行截断，点击展开/收起。

**顶部栏**：返回按钮、标题、`当前/总数` 徽章、静音切换。

### 3.3 选集面板（`components/Panels.tsx`）
- 底部弹层（72vh）；4 列集数网格，当前集高亮。
- 正序/倒序切换。
- 点选即切换播放并收起。

### 3.4 评论面板（底部弹层，桌面为右侧停靠）
- 按剧集拉评论（图文帖用帖子评论接口），分页加载（每页 20）。
- 评论项：头像（无图时按用户 id 生成色相）、昵称、时间、正文、点赞数、回复数。
- **发表评论**：底部输入框 + 发送按钮；未登录时输入框聚焦即弹登录框；提交后提示"审核通过后展示"并刷新第一页。
- 短剧与图文帖共用（`kind` 决定接口）。

### 3.5 搜索页（`pages/Search.tsx`）
- 搜索栏（圆角胶囊，清空按钮）+ 右侧排行榜入口按钮。
- **未搜索态**：搜索历史 chips（最多 12 条，可清空）、热门题材 12 个标签（关键词写死在 `src/pages/Search.tsx:9` 的 `HOT_TAGS`，点击即以该词发起搜索，移植时从源码取）、"完整榜单"入口。
- **结果态**：结果计数、瀑布流（Masonry）卡片、"加载更多"按钮（或已到底提示）、空态引导去热榜。
- 搜索历史去重、最新在前。

### 3.6 排行榜（`pages/Search.tsx` RankPage）
- 三个子 Tab：**热播榜**（热力指数）/ **推荐榜**（推荐值）/ **潜力榜**（潜力值）。
- 列表行：名次、封面、标题、分类名、集数、完结标记、指标条（相对最大值归一化的进度条）、采集/评论/点赞/播放四项计数。
- 切换 Tab 重新拉取。

### 3.7 分类页（`pages/Category.tsx`）
- 频道总览：排行榜入口卡 + **4 个 AI 频道**横向滚动卡片行（cate 代码：`ai-duanju` / `ai-manju` / `ai-huanlian` / `ai-mogai`；cate 是分类接口的必填参数，显示名见 `src/pages/Category.tsx:9` 的 `CHANNELS`）。
- + **图文频道**（帖子封面卡，右上角热度角标）。
- **频道详情页**：排序切换（最新 / 最热 / 高分——前端排序）、瀑布流、IntersectionObserver 无限滚动（600px 预载）、加载失败重试、到底提示。
- 图文帖详情页（`PostDetail`）：顶部封面/视频播放器（点击播放）、标题、发布时间、热度、标签 chips、正文（HTML 白名单清洗渲染或纯文本 pre-wrap）。

### 3.8 图文帖列表页（`pages/Posts.tsx`）
- 2 列瀑布流（桌面 3–4 列），封面卡 + 标题 + 热度，无限滚动。

### 3.9 我的（`pages/Profile.tsx`）
**未登录态**
- 登录/注册卡片：Tab 切换登录/注册；账号（4-20 位）、密码（6-20 位）、注册邮箱（可选）；错误提示；提交 loading。
- "登录能做什么"说明卡。
- **我的下载入口**（无需登录）：显示进行中任务数 / 总记录数。

**已登录态**
- 资料卡：头像、昵称、@用户名、ID、点赞/收藏/关注计数、退出登录。
- **我的收藏 / 观看历史**子 Tab：封面 3 列网格（最多取前 12 个 id，逐个拉详情，失败的跳过）；点击进入对应信息流；观看历史有"清空"按钮；空态引导。
- 我的下载入口。
- **设置**：深色/浅色主题开关（持久化）；本地数据统计行。
- **关于弹窗**：版本、简介、复制仓库地址。
- **清理缓存弹窗**：清除封面/播放缓存 + 本地喜欢/收藏/历史/搜索历史（保留登录态）。
- 底部版本文字（`HGhub 1.0.0 · Android 客户端`）。

### 3.10 我的下载（`pages/Downloads.tsx`）
- 顶部返回 + 标题 + 子 Tab：**下载中 (n) / 已下载 (n)**。
- 任务行：集数徽章或完成图标、标题、进度条、状态文案（排队中/下载中/已暂停/合成 MP4 中/保存中/已完成/失败/**需要存储权限**）、实时速度（MB/s）、已下/总量（MB）、分片进度、错误信息。
- 操作按钮：暂停 / 继续 / 重试（含"已开权限,重试"）/ 删除。
- 进入页面时触发文件存在性校验（`dl_verify`，核对已下载文件是否还在磁盘上）。

### 3.11 登录弹窗（`components/LoginModal.tsx`）
- 点赞/收藏/关注/评论时未登录则弹出；样式与"我的"页登录卡一致。

## 4. 本地持久化数据

| 数据 | 存储 | 内容 |
| --- | --- | --- |
| 应用状态 | `localStorage["hghub_app_v1"]` | 喜欢列表、收藏列表、观看历史（≤80）、关注列表、静音、音量、搜索历史（≤12） |
| 主题 | `localStorage["hghub_theme"]` | dark / light（默认 dark） |
| 会话 | 应用数据目录 `session.json` | token、用户资料、**visitor_id**（32 位十六进制设备身份，首启生成后复用） |
| 下载任务 | 应用数据目录 `downloads.json` | 全量任务快照，启动时恢复并接管 |

移植说明：HarmonyOS 侧对应 `preferences` / 关系数据库；visitor_id 与 token 的持久化语义需保留。

## 5. 网络与协议层（Rust，移植工作量最大）

### 5.1 dx150-edge-v1 加密协议（`src-tauri/src/dx150.rs`）
上游 API 已全面加密，这是所有数据接口的前提：
- **分域端点**：`/api/public/request`（明文 JSON，头 `X-HG-Public-JSON: 1`，只读列表类接口）、`/api/user|playback|dynamic/request`（加密）。
- **握手**：POST `{v:1, type:'hello', client_pub}` → 服务端回 `kid/sid/site/server_pub/salt`。
- **密钥派生**：ECDH P-256 → HKDF-SHA256（salt + info+方向后缀）→ AES-256-GCM 请求/响应双向密钥。
- **调用**：`{v:1, type:'call', kid, sid, seq, ts, ciphertext}`，密文内层 `{request, authorization}`；序列号上限 16384，会话过期自动重握手。
- scope 路由表（哪个接口走哪个域）复刻自官方前端内嵌的 `window.__cloudfrontCompat.encryptedAPIRoutes`，共 40+ 条路由。
- 未匹配路由回落旧版 `/api/edge/request` 明文信封。
- 请求带浏览器 UA、gzip/brotli、连接超时 10s / 总超时 20s，失败重试。

### 5.2 业务命令（Tauri IPC，`api.rs`）
`app_boot`、`api_login/register/logout/me`、`api_feed`、`api_category`、`api_rank`、`api_search`、`api_posts/post/post_like/post_collect/post_comments`、`api_video`（详情）、`api_play`（取播放地址）、`api_comments`、`api_comment_send`、`api_like/collect/follow`、`cache_clear`、下载命令组（见 §7）。

### 5.3 本地媒体协议（`media.rs`，关键机制）
所有图片和视频流经自定义协议 `http://hg.localhost/*`（Tauri 注册的 `hg://` scheme）：
- **`/img?u=<加密封面URL>`**：封面是 AES-128-CBC 密文（固定 key/iv 硬编码），Rust 解密后回明文图片，`<img>` 直接可用；内存缓存 240 张（FIFO 淘汰）。
- **`/hls?u=<m3u8地址>`**：代理播放列表——解密上游 m3u8 文本、**改写 `#EXT-X-KEY` URI 与分片地址**为本地代理地址，规避 WebView CORS 与防盗链；缓存 60 份。
- **`/seg?u=<分片或mp4地址>`**：分片（含 AES key）/ mp4 直链原样透传（附带必要请求头）。
- HarmonyOS 移植：ArkWeb 不一定支持等价的 scheme 拦截，需要用 Web 组件的 `onInterceptRequest` 实现同样的本地代理，或改为 ArkTS 拉流 + Native 播放器直接喂 URL。

## 6. 播放技术

- **hls.js 1.6.15**（WebView 内）播放 AES-128 加密 HLS；详情接口返回 `video_url`（AVC）与可选 `video_url_hevc`，前端目前只用 `video_url`。
- 非 m3u8 媒体（mp4 等）走 `/seg` 透传。
- hls.js 的 MSE 在 Android WebView 可用；HarmonyOS 若用 ArkWeb + hls.js 需实测 MSE 支持，否则改用 AVPlayer 原生播放。

## 7. 下载引擎（`download.rs` + `mux.rs`）

完整离线链路，全部在 Rust 侧：
1. **`dl_add(videoId, ep, ...)`**：解析 m3u8 → 建任务（同一时刻仅 1 个任务下载，其余排队）。
2. **分片下载**：并发拉分片 → **AES-128-CBC 解密** → 解密后的分片落盘缓存（临时名写完再改名，存在即完整）→ **断点续传**（恢复时重取播放地址，因 auth_key 有时效，已下分片直接走缓存）。
3. **封装**：下载完 → MPEG-TS 解封装（PAT/PMT → H264 AnnexB + AAC ADTS 基本流，PES 组帧，parse PTS/DTS）→ AVCC 化（4 字节长度前缀）→ `mp4` crate 无损转封装 **MP4（不重编码）**。
4. **保存**：写入系统公共 Download 目录；Android 无权限时任务进入 `need_permission` 状态，前端提示开权限后重试。
5. **状态推送**：任务列表快照经 `dl://state` 事件实时推给前端；进度含 seg_done/seg_total、MB、实时网速。
6. **任务管理**：暂停/继续/删除/重试/已下载文件存在性校验（`dl_verify`）。

HarmonyOS 移植：这套 TS 解封装 + MP4 封装逻辑建议原样用 C/C++（或 Rust→OHOS NDK）复用；Android 的存储权限流程对应 HarmonyOS 的用户授权弹窗（`requestPermissionFromUser`，下载目录写入）。

## 8. UI / 体验细节

- **主题**：Fluent 风格深色为主、可选浅色；CSS 变量驱动（`--p-primary` 等）；`colorScheme` 同步。
- **动效**：页面进入动画、卡片 rise、爱心爆裂 pop、按钮 pressable 缩放、Toast（最多同时 3 条，2.2s 自动消失，可带 ok/heart/star/info 图标）。
- **安全区**：所有沉浸页面用 `--sat`（顶部）/ `--sab`（底部）变量，取 `max(env(safe-area-inset-*), 8px/6px)`。
- **图片组件**：统一 `Img`（封面走本地解密协议）、`Avatar`（无头像时按名字/色相生成）。
- **格式化**：数字中文单位（万/亿）、时长 m:ss。
- 阻止长按右键菜单；输入框内 Escape 失焦。
- **启动自检**（仅 DEV）：跑一条完整的 webview→本地协议→上游链路探针，输出到调试日志。

## 9. 桌面端独有功能（移植时不需要）

- Windows 窗口壳：无边框窗口 + 自绘标题栏/侧边栏、窗口缩放手柄、剧场模式（theater）、`wide` 宽屏布局（>640px 切换）。
- 桌面控制条 PlayerControls（音量条、画中画、进度条、上一/下一部按钮）、鼠标闲置 2.8s 隐藏 UI。
- 键盘快捷键（1-4 切 Tab、`/` 搜索、方向键、空格、f/t/m/l/s/c/e 等）。
- 选集/评论右侧停靠面板（Android 是底部弹层）。
- Fullscreen API 全屏（Android 用应用内沉浸层替代）。
- 桌面本地协议是 `http://hg.localhost`（Android 上代码里同是 http，但 Tauri 实际注册为 https，前端统一按 http 拼 URL）。

## 10. HarmonyOS 移植要点（建议）

1. **UI 层**：React/WebView 结构可以用 ArkWeb 直接复用现有前端（工程量最小），也可以用 ArkTS + ArkUI 原生重写（体验最好）。无论哪条路，§5.3 的本地媒体代理都要落地：ArkWeb 用 `onInterceptRequest` 拦截 `hg.localhost`。
2. **Rust 业务层**：dx150 协议（ring/crate 依赖加密）建议用 Rust 编译到 OHOS（`ohos` target + NDK）做成 native 模块，或用 ArkTS 的 cryptoFramework 重写 ECDH P-256/HKDF/AES-GCM——注意 HKDF 的 info 拼接和 AES-GCM AAD 细节必须完全一致。
3. **播放**：优先验证 ArkWeb 内 hls.js（MSE）能否播 AES-128 HLS；不行则走 AVPlayer（OHOS 原生支持 HLS 解密流需要自实现解密回调）。
4. **下载引擎**：TS→MP4 无损封装是纯算法，建议 native 复用；文件保存与权限用 HarmonyOS `requestPermissionsFromUser` + 媒体库 API。
5. **返回键**：`onBackPress` 按 §2.3 的 7 级优先级实现。
6. **手势**：长按 2x / 上滑锁定 / 横拖 seek 需在 ArkTS 手势系统（`LongPressGesture`/`PanGesture`）重新实现；触感反馈对应系统振动接口。
