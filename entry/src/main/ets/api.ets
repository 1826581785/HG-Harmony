/**
 * API 层：NAPI 信封解析 + 类型化调用。对应旧工程 src/api.ts。
 * 所有调用抛 Error（信封 ok=false 时），成功返回 data。
 */
import { hgEdge, hgPlay, hgMediaUrl, hgImgUrl, hgMediaStart } from 'libhg.so';
import { VideoCard, VideoDetail } from './model';

export class ApiError extends Error {
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

/** 经本地服务的封面地址（/img 解密通道） */
export function coverUrl(url: string): string {
  if (url === '') {
    return '';
  }
  return (envOf(hgImgUrl(url))['url'] as string);
}

/** 确保本地媒体服务已启动（返回 base，如 http://127.0.0.1:port） */
export async function ensureMedia(): Promise<string> {
  return (envOf(await hgMediaStart())['base'] as string);
}
