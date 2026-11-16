/**
 * API 层：NAPI 信封解析 + 类型化调用。对应旧工程 src/api.ts。
 * 所有调用抛 Error（信封 ok=false 时），成功返回 data。
 */
import { hgEdge, hgPlay, hgMediaUrl, hgImgUrl, hgMediaStart, hgLogin, hgRegister, hgLogout, hgMe, hgBoot, hgClearMediaCache,
  hgDlOnState, hgDlAdd, hgDlList, hgDlPause, hgDlResume, hgDlRetry, hgDlRemove, hgDlVerify, hgDlRestore, hgDlFile } from 'libhg.so';
import { VideoCard, VideoDetail, CommentPageData, User, RankItem, Post, PostDetailData, Pagination, DlTask } from './model';
import { store } from './store';

export class ApiError extends Error {
}

/** 列表类返回结构（视频卡 / 帖子） */
export interface CardPage {
  items: VideoCard[];
  pages: number;
}

export interface PostPage {
  items: Post[];
  pages: number;
}

/** 解 NAPI 信封：ok=false 抛错，返回 data */
export function envOf(raw: string): Record<string, Object> {
  const env = JSON.parse(raw) as Record<string, Object>;
  if (env.ok !== true) {
    throw new ApiError((env.error as string) ?? '请求失败');
  }
  return env.data as Record<string, Object>;
}

/** 通用业务调用 */
export async function edge(method: string, path: string, body: string | null): Promise<Record<string, Object>> {
  const raw: string = await hgEdge(method, path, body);
  return envOf(raw);
}

async function get(path: string): Promise<Record<string, Object>> {
  return edge('GET', path, null);
}

/** 首页信息流（分页） */
export async function feed(page: number, size: number): Promise<VideoCard[]> {
  const data = await get(`/api/videos?page=${page}&size=${size}`);
  const items = (data['items'] as Array<Record<string, Object>>) ?? [];
  const out: VideoCard[] = [];
  for (const o of items) {
    out.push(VideoCard.from(o));
  }
  return out;
}

/** 视频详情（含剧集与作者） */
export async function videoDetail(id: number): Promise<VideoDetail> {
  const data = await get(`/api/videos/${id}`);
  return VideoDetail.from(data);
}

/** 播放地址（返回经本地代理后的可直接播放 URL） */
export async function playUrl(id: number, ep: number): Promise<string> {
  const raw: string = await hgPlay(id, ep);
  const data = envOf(raw);
  const url = (data['video_url'] as string) ?? '';
  if (url === '') {
    throw new ApiError('暂无播放地址');
  }
  return proxyUrl(url);
}

/** 经本地服务的播放地址（m3u8 → /hls，其它 → /seg） */
export function proxyUrl(url: string): string {
  return (envOf(hgMediaUrl(url))['url'] as string);
}

/** 经本地服务的封面地址（/img 解密通道）。媒体服务未就绪时返回空串（渲染期不可抛异常）。 */
export function coverUrl(url: string): string {
  if (url === '') {
    return '';
  }
  try {
    return (envOf(hgImgUrl(url))['url'] as string) ?? '';
  } catch (e) {
    return '';
  }
}

/** 确保本地媒体服务已启动（返回 base，如 http://127.0.0.1:port） */
export async function ensureMedia(): Promise<string> {
  return (envOf(await hgMediaStart())['base'] as string);
}

/** 按剧集分页拉评论 */
export async function comments(id: number, ep: number, page: number, size: number): Promise<CommentPageData> {
  const data = await get(`/api/videos/${id}/comments?ep=${ep}&page=${page}&size=${size}`);
  return CommentPageData.from(data);
}

/** 发表评论（未登录由服务端拒绝） */
export async function commentSend(id: number, ep: number, text: string): Promise<void> {
  await edge('POST', `/api/videos/${id}/comments?ep=${ep}`, JSON.stringify({ text: text }));
}

/* ── 账号 ── */

/** 启动时取会话：{user, logged_in, base}。token 由 Rust session.json 持久化。 */
export async function boot(): Promise<User | null> {
  const data = envOf(await hgBoot());
  if ((data['logged_in'] as boolean) !== true) {
    return null;
  }
  const u = data['user'] as Record<string, Object>;
  const user = u ? User.from(u) : null;
  if (user) {
    // 本地互动标记与服务端对齐（session 里存有上次 me() 的 interactions）
    store.applyServerInteractions(user.likeIds, user.favIds, user.followIds);
  }
  return user;
}

export async function login(username: string, password: string): Promise<User> {
  const data = envOf(await hgLogin(username, password));
  return User.from(data['user'] as Record<string, Object>);
}

export async function register(username: string, password: string, email: string): Promise<User> {
  const data = envOf(await hgRegister(username, password, email));
  return User.from(data['user'] as Record<string, Object>);
}

export async function logout(): Promise<void> {
  envOf(await hgLogout());
}

/** 拉取并刷新当前用户资料（服务端最新计数与互动列表，落库到本地标记） */
export async function me(): Promise<User> {
  const user = User.from(envOf(await hgMe()));
  store.applyServerInteractions(user.likeIds, user.favIds, user.followIds);
  return user;
}

/* ── 互动（登录态，POST/DELETE 由 Rust 侧 authed 通道发出） ── */

/** 点赞/取消（按剧集） */
export async function likeVideo(id: number, ep: number, on: boolean): Promise<void> {
  await edge(on ? 'POST' : 'DELETE', `/api/videos/${id}/like?ep=${ep}`, null);
}

/** 收藏/取消 */
export async function collect(id: number, on: boolean): Promise<void> {
  await edge(on ? 'POST' : 'DELETE', `/api/videos/${id}/collect`, null);
}

/** 关注/取关作者 */
export async function followUser(uid: number, on: boolean): Promise<void> {
  await edge(on ? 'POST' : 'DELETE', `/api/users/${uid}/follow`, null);
}

/* ── 列表类 ── */

/** 搜索（结果复用 VideoCard 结构） */
export async function search(q: string, page: number, size: number): Promise<CardPage> {
  const data = await edge('GET', `/api/search?q=${encodeURIComponent(q)}&page=${page}&size=${size}`, null);
  const items = (data['items'] as Array<Record<string, Object>>) ?? [];
  const out: VideoCard[] = [];
  for (const o of items) {
    out.push(VideoCard.from(o));
  }
  const pg = Pagination.from(data['pagination'] as Record<string, Object>);
  const res: CardPage = { 'items': out, 'pages': pg.pages };
  return res;
}

export async function category(cate: string, page: number, size: number): Promise<CardPage> {
  const data = await edge('GET', `/api/videos/category/${cate}?page=${page}&size=${size}`, null);
  const items = (data['items'] as Array<Record<string, Object>>) ?? [];
  const out: VideoCard[] = [];
  for (const o of items) {
    out.push(VideoCard.from(o));
  }
  const pg = Pagination.from(data['pagination'] as Record<string, Object>);
  const res: CardPage = { 'items': out, 'pages': pg.pages };
  return res;
}

export async function rank(kind: string): Promise<RankItem[]> {
  const data = await edge('GET', `/api/ranks/${kind}`, null);
  const items = (data['items'] as Array<Record<string, Object>>) ?? [];
  const out: RankItem[] = [];
  for (const o of items) {
    out.push(RankItem.from(o));
  }
  return out;
}

export async function posts(page: number, size: number): Promise<PostPage> {
  const data = await edge('GET', `/api/posts?page=${page}&size=${size}`, null);
  const items = (data['items'] as Array<Record<string, Object>>) ?? [];
  const out: Post[] = [];
  for (const o of items) {
    out.push(Post.from(o));
  }
  const pg = Pagination.from(data['pagination'] as Record<string, Object>);
  const res: PostPage = { 'items': out, 'pages': pg.pages };
  return res;
}

export async function postDetail(id: number): Promise<PostDetailData> {
  const data = await edge('GET', `/api/posts/${id}`, null);
  return PostDetailData.fromDetail(data);
}

/** 清空媒体内存缓存（封面/播放列表），对应旧 cache_clear 的媒体部分 */
export function clearMediaCache(): void {
  hgClearMediaCache();
}

/* ── 下载引擎（阶段 6） ── */

/** 注册下载状态回调（任务列表 JSON 快照）。必须在 EntryAbility.onCreate 注册。
 * 注意：napi ThreadsafeFunction 默认 CalleeHandled=true，回调收到 (err, json) 两个参数。 */
export function dlOnState(cb: (err: Object | null, json: string) => void): void {
  hgDlOnState(cb);
}

/** 添加下载任务。返回任务 id；同剧同集已完成时返回 null（重复）。 */
export async function dlAdd(videoId: number, ep: number, title: string, epTitle: string): Promise<number | null> {
  const data = envOf(await hgDlAdd(videoId, ep, title, epTitle));
  const id = data['id'] as number;
  return id !== undefined && id !== null ? id : null;
}

/** 任务列表快照（含已完成文件存在性校验） */
export async function dlList(): Promise<DlTask[]> {
  const data = envOf(await hgDlList());
  const arr = (data['tasks'] as Array<Object>) ?? [];
  const out: DlTask[] = [];
  for (const o of arr) {
    out.push(o as DlTask);
  }
  return out;
}

/** 校验已完成文件存在性（被外部删除的记录自动移出） */
export async function dlVerify(): Promise<void> {
  await hgDlVerify();
}

/** 应用启动恢复：中断任务回队列续传 + 清残留分片缓存 */
export async function dlRestore(): Promise<void> {
  await hgDlRestore();
}

/** 已完成任务的成品文件绝对路径（供保存到系统图库） */
export async function dlFile(id: number): Promise<string> {
  const data = envOf(await hgDlFile(id));
  return (data['path'] as string) ?? '';
}

export async function dlPause(id: number): Promise<void> {
  await hgDlPause(id);
}

export async function dlResume(id: number): Promise<void> {
  await hgDlResume(id);
}

export async function dlRetry(id: number): Promise<void> {
  await hgDlRetry(id);
}

export async function dlRemove(id: number): Promise<void> {
  await hgDlRemove(id);
}
