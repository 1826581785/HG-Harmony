/**
 * 全局状态：本地喜欢/收藏/历史/静音/音量，preferences 持久化。
 * 对应旧工程 store.tsx 的 Persist 部分。
 */
import { preferences } from '@kit.ArkData';
import { User } from './model';

const PREF_NAME = 'hgapp';
const KEY_DATA = 'app_data_v1';

interface PersistData {
  likes: number[];
  favs: number[];
  follows: number[];
  history: number[];
  muted: boolean;
  volume: number;
  searchHist: string[];
}

export function fmtCount(n: number): string {
  if (n >= 100000000) {
    return `${(n / 100000000).toFixed(1).replace('.0', '')}亿`;
  }
  if (n >= 10000) {
    return `${(n / 10000).toFixed(1).replace('.0', '')}万`;
  }
  return `${n}`;
}

class Store {
  likes: number[] = [];
  favs: number[] = [];
  follows: number[] = [];
  history: number[] = [];
  muted: boolean = true;
  volume: number = 0.7;
  searchHist: string[] = [];
  /** 当前登录用户（token 在 Rust session.json，重启由 boot 恢复） */
  user: User | null = null;
  /** 简单事件通知（组件订阅后刷新 UI） */
  onUpdate: (() => void) | null = null;

  private pref: preferences.Preferences | null = null;

  async init(context: Context): Promise<void> {
    this.pref = await preferences.getPreferences(context, PREF_NAME);
    const raw = (await this.pref.get(KEY_DATA, '')) as string;
    if (raw !== '') {
      try {
        const d = JSON.parse(raw) as PersistData;
        this.likes = d.likes ?? [];
        this.favs = d.favs ?? [];
        this.follows = d.follows ?? [];
        this.history = d.history ?? [];
        this.muted = d.muted ?? true;
        this.volume = d.volume ?? 0.7;
        this.searchHist = d.searchHist ?? [];
      } catch (e) {
        // 数据损坏则用默认值
      }
    }
  }

  private async persist(): Promise<void> {
    if (!this.pref) {
      return;
    }
    const d: PersistData = {
      likes: this.likes,
      favs: this.favs,
      follows: this.follows,
      history: this.history,
      muted: this.muted,
      volume: this.volume,
      searchHist: this.searchHist
    };
    await this.pref.put(KEY_DATA, JSON.stringify(d));
    await this.pref.flush();
    if (this.onUpdate) {
      this.onUpdate();
    }
  }

  /** 是否已登录（以 store.user 为准，由 boot/登录流程维护） */
  loggedIn(): boolean {
    return this.user !== null;
  }

  setUser(u: User | null): void {
    this.user = u;
    if (this.onUpdate) {
      this.onUpdate();
    }
  }

  isLiked(id: number): boolean {
    return this.likes.includes(id);
  }

  isFav(id: number): boolean {
    return this.favs.includes(id);
  }

  async toggleLike(id: number): Promise<boolean> {
    const on = !this.likes.includes(id);
    this.likes = on ? [id].concat(this.likes) : this.likes.filter((x: number) => x !== id);
    await this.persist();
    return on;
  }

  async toggleFav(id: number): Promise<boolean> {
    const on = !this.favs.includes(id);
    this.favs = on ? [id].concat(this.favs) : this.favs.filter((x: number) => x !== id);
    await this.persist();
    return on;
  }

  isFollowed(uid: number): boolean {
    return this.follows.includes(uid);
  }

  /** 服务端互动列表并入本地标记（取并集，本地独有项保留） */
  async applyServerInteractions(likeIds: number[], favIds: number[], followIds: number[]): Promise<void> {
    let changed = false;
    const merge = (local: number[], server: number[]): number[] => {
      const out = local.slice();
      for (const id of server) {
        if (!out.includes(id)) {
          out.push(id);
          changed = true;
        }
      }
      return out;
    };
    this.likes = merge(this.likes, likeIds);
    this.favs = merge(this.favs, favIds);
    this.follows = merge(this.follows, followIds);
    if (changed) {
      await this.persist();
    }
  }

  async toggleFollow(uid: number): Promise<boolean> {
    const on = !this.follows.includes(uid);
    this.follows = on ? [uid].concat(this.follows) : this.follows.filter((x: number) => x !== uid);
    await this.persist();
    return on;
  }

  async addHistory(id: number): Promise<void> {
    this.history = [id].concat(this.history.filter((x: number) => x !== id)).slice(0, 80);
    await this.persist();
  }

  async clearHistory(): Promise<void> {
    this.history = [];
    await this.persist();
  }

  async setMuted(v: boolean): Promise<void> {
    this.muted = v;
    await this.persist();
  }

  async setVolume(v: number): Promise<void> {
    this.volume = Math.max(0, Math.min(1, v));
    if (this.volume === 0) {
      this.muted = true;
    }
    await this.persist();
  }

  async addSearch(q: string): Promise<void> {
    const t = q.trim();
    if (t === '') {
      return;
    }
    this.searchHist = [t].concat(this.searchHist.filter((x: string) => x !== t)).slice(0, 12);
    await this.persist();
  }

  async clearSearchHist(): Promise<void> {
    this.searchHist = [];
    await this.persist();
  }

  /** 清理本地记录（喜欢/收藏/关注/历史/搜索历史），登录态保留 */
  async clearLocal(): Promise<void> {
    this.likes = [];
    this.favs = [];
    this.follows = [];
    this.history = [];
    this.searchHist = [];
    await this.persist();
  }
}

export const store: Store = new Store();
