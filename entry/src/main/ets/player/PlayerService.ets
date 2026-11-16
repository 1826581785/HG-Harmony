/**
 * 播放器服务：单 AVPlayer 实例 + 状态机封装。
 * 切流流程：reset → 赋 url → (异步) initialized → 设 surfaceId → prepare → setScaleType → play。
 */
import { media } from '@kit.MediaKit';
import { BusinessError } from '@kit.BasicServicesKit';

export class PlayerService {
  private player: media.AVPlayer | null = null;
  private surfaceId: string = '';
  private targetUrl: string = '';
  /** 每次 attach 递增，防止旧回调串流 */
  private generation: number = 0;
  /** 播放器忙（正在切流） */
  switching: boolean = false;

  onTime: (ms: number) => void = () => {
  };
  onDuration: (ms: number) => void = () => {
  };
  onVideoSize: (w: number, h: number) => void = () => {
  };
  onPlaying: () => void = () => {
  };
  onPaused: () => void = () => {
  };
  onCompleted: () => void = () => {
  };
  onError: (msg: string) => void = () => {
  };

  private bindEvents(p: media.AVPlayer): void {
    p.on('error', (err: BusinessError) => {
      this.onError(`播放错误(${err.code}): ${err.message}`);
    });
    p.on('timeUpdate', (t: number) => {
      this.onTime(t);
    });
    p.on('videoSizeChange', (w: number, h: number) => {
      // 竖屏视频 → cover 裁剪填充；横屏视频 → contain（防拉伸）
      try {
        p.videoScaleType = h > w ? media.VideoScaleType.VIDEO_SCALE_TYPE_FIT_CROP : media.VideoScaleType.VIDEO_SCALE_TYPE_FIT;
      } catch (e) {
        // 忽略状态不允许时
      }
      this.onVideoSize(w, h);
    });
    p.on('stateChange', async (state: string) => {
      if (this.player !== p) {
        return;
      }
      if (state === 'initialized') {
        p.surfaceId = this.surfaceId;
        try {
          await p.prepare();
          await p.play();
        } catch (e) {
          this.switching = false;
          this.onError(`prepare/play 异常: ${(e as BusinessError).message ?? String(e)}`);
        }
      } else if (state === 'prepared') {
        this.onDuration(p.duration);
      } else if (state === 'playing') {
        this.switching = false;
        this.onPlaying();
      } else if (state === 'paused') {
        this.onPaused();
      } else if (state === 'completed' || state === 'stopped') {
        this.onCompleted();
      }
    });
  }

  /** 切换到新流（同 surface），自动播放。 */
  async attach(url: string, surfaceId: string): Promise<void> {
    const gen = ++this.generation;
    this.surfaceId = surfaceId;
    this.targetUrl = url;
    this.switching = true;
    if (this.player) {
      try {
        await this.player.reset();
      } catch (e) {
        // reset 失败则重建
        try { await this.player.release(); } catch (e2) { /* 忽略 */ }
        this.player = null;
      }
    }
    if (!this.player) {
      this.player = await media.createAVPlayer();
      this.bindEvents(this.player);
    }
    const p = this.player;
    if (gen !== this.generation) {
      return; // 已有更新的切流请求
    }
    p.url = url;
  }

  async play(): Promise<void> {
    if (this.player) {
      try { await this.player.play(); } catch (e) { /* 忽略 */ }
    }
  }

  async pause(): Promise<void> {
    if (this.player) {
      try { await this.player.pause(); } catch (e) { /* 忽略 */ }
    }
  }

  isPlaying(): boolean {
    return this.player?.state === 'playing';
  }

  async seek(ms: number): Promise<void> {
    if (this.player) {
      try { await this.player.seek(ms, media.SeekMode.SEEK_PREV_SYNC); } catch (e) { /* 忽略 */ }
    }
  }

  setSpeed(speed: media.PlaybackSpeed): void {
    if (this.player) {
      try { this.player.setSpeed(speed); } catch (e) { /* 忽略 */ }
    }
  }

  /** AVPlayer 无 muted 属性，静音用音量 0 实现（记住原音量） */
  private currentVolume: number = 1;
  private mutedFlag: boolean = false;

  setMuted(v: boolean): void {
    this.mutedFlag = v;
    this.applyVolume();
  }

  setVolume(v: number): void {
    this.currentVolume = Math.max(0, Math.min(1, v));
    if (this.currentVolume === 0) {
      this.mutedFlag = true;
    }
    this.applyVolume();
  }

  private applyVolume(): void {
    if (this.player) {
      try { this.player.setVolume(this.mutedFlag ? 0 : this.currentVolume); } catch (e) { /* 忽略 */ }
    }
  }

  async release(): Promise<void> {
    this.generation++;
    if (this.player) {
      try { await this.player.release(); } catch (e) { /* 忽略 */ }
      this.player = null;
    }
  }
}

export const playerService: PlayerService = new PlayerService();
