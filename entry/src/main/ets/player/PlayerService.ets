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
  /** 当前正在初始化的 url 的代数（区分过期流的迟到事件） */
  private urlGen: number = -1;
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
  onPrepared: () => void = () => {
  };
  onPaused: () => void = () => {
  };
  onCompleted: () => void = () => {
  };
  onError: (msg: string) => void = () => {
  };

  /** 最近上报的视频尺寸（0 表示未知） */
  private lastVideoW: number = 0;
  private lastVideoH: number = 0;
  /** 最近一次状态回调记录的状态名（applyScale 的状态闸门） */
  private stateName: string = 'idle';
  /** 本次流 prepared 后是否自动播放（页面不可见时置 false，停在 paused） */
  private autoPlay: boolean = true;
  /** 起播闸门：prepared 时刻动态判定（由活跃 UI 实例注入；null 时用 autoPlay） */
  playGate: (() => boolean) | null = null;
  /** prepared 后被闸门拦下未起播（看门狗把这种 prepared 视为成功稳态） */
  private preparedIdle: boolean = false;

  /** 缩放策略：竖屏视频 cover 裁剪填充，横屏视频 contain。
   *  仅在合法状态执行（否则 AVPlayer 抛 5400102）；失败静默，不闪错误。 */
  private applyScale(): void {
    const p = this.player;
    if (!p || this.lastVideoW <= 0 || this.lastVideoH <= 0) {
      return;
    }
    const ok = this.stateName === 'prepared' || this.stateName === 'playing'
      || this.stateName === 'paused' || this.stateName === 'completed';
    if (!ok) {
      return;
    }
    try {
      p.videoScaleType = this.lastVideoH > this.lastVideoW
        ? media.VideoScaleType.VIDEO_SCALE_TYPE_FIT_CROP
        : media.VideoScaleType.VIDEO_SCALE_TYPE_FIT;
    } catch (e) {
      // 静默：缩放失败不影响播放，prepared 态还会再试一次
    }
  }

  private bindEvents(p: media.AVPlayer): void {
    p.on('error', (err: BusinessError) => {
      // 过期流（已被新 attach reset 掉）的错误不上浮，避免闪报错
      if (this.urlGen !== this.generation) {
        return;
      }
      this.onError(`播放错误(${err.code}): ${err.message}`);
    });
    p.on('timeUpdate', (t: number) => {
      this.onTime(t);
    });
    p.on('videoSizeChange', (w: number, h: number) => {
      this.lastVideoW = w;
      this.lastVideoH = h;
      this.applyScale();
      this.onVideoSize(w, h);
    });
    p.on('stateChange', async (state: string) => {
      if (this.player !== p) {
        return;
      }
      this.stateName = state;
      // 旧流被 reset 后仍可能排队送达的事件：一律丢弃，防止对 idle 状态 prepare
      const stale = this.urlGen !== this.generation;
      if (state === 'initialized') {
        // 执行时刻以 p.state 为准（事件到达 ≠ 执行时刻）：已经不是 initialized 就说明被新流 reset 掉了
        if (stale || p.state !== 'initialized') {
          return;
        }
        p.surfaceId = this.surfaceId;
        try {
          await p.prepare();
          const stNow: string = p.state;
          if (stNow === 'prepared') {
            // 确认仍要播放本流，才摘封面（onPrepared）；若状态已被新流切走则交给新 attach/看门狗
            this.applyScale();
            this.applySpeed();
            this.onDuration(p.duration);
            this.onPrepared();
            const wantPlay = this.playGate ? this.playGate() : this.autoPlay;
            if (wantPlay) {
              this.preparedIdle = false;
              await p.play();
            } else {
              // 页面不可见：停在 prepared（prepared 态调 pause 是非法操作会抛错），
              // 恢复可见时由 play() 从 prepared 直接起播。
              this.preparedIdle = true;
              this.switching = false;
            }
          }
        } catch (e) {
          this.switching = false;
          this.onError(`prepare/play 异常: ${(e as BusinessError).message ?? String(e)}`);
        }
      } else if (state === 'prepared') {
        if (stale || p.state !== 'prepared') {
          return;
        }
        this.applyScale();
        this.applySpeed();
        this.onDuration(p.duration);
      } else if (state === 'playing') {
        if (stale || p.state !== 'playing') {
          return;
        }
        this.switching = false;
        this.onPlaying();
      } else if (state === 'paused') {
        if (stale || p.state !== 'paused') {
          return;
        }
        this.onPaused();
      } else if (state === 'completed' || state === 'stopped') {
        if (stale) {
          return;
        }
        this.onCompleted();
      }
    });
  }

  /** 切换到新流（同 surface）。autoplay=false 时 prepared 后停在 paused（页面不可见场景）。 */
  async attach(url: string, surfaceId: string, autoplay: boolean = true): Promise<void> {
    const gen = ++this.generation;
    this.autoPlay = autoplay;
    this.preparedIdle = false;
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
    // 只有 idle 才允许赋 url（否则 5400102）：并发 attach 交错时可能仍在 initialized，强制归位
    let st: string = p.state;
    let guard = 0;
    while (st !== 'idle' && guard < 3) {
      try {
        await p.reset();
      } catch (e) {
        break;
      }
      if (gen !== this.generation) {
        return;
      }
      st = p.state;
      guard++;
    }
    if (gen !== this.generation) {
      return;
    }
    if (st !== 'idle') {
      this.scheduleWatchdog(gen, 1);
      return;
    }
    this.urlGen = gen;
    try {
      p.url = url;
    } catch (e) {
      this.scheduleWatchdog(gen, 1);
      return;
    }
    this.scheduleWatchdog(gen, 0);
  }

  /** 看门狗：赋 url 后 8s 内没到 playing/paused（真正出画面出声）→ 自动 reset 重来 */
  private watchdogTimer: number = -1;

  private clearWatchdog(): void {
    if (this.watchdogTimer >= 0) {
      clearTimeout(this.watchdogTimer);
      this.watchdogTimer = -1;
    }
  }

  private scheduleWatchdog(gen: number, attempt: number): void {
    this.clearWatchdog();
    this.watchdogTimer = setTimeout(() => {
      this.watchdogTimer = -1;
      if (gen !== this.generation || this.urlGen !== gen) {
        return;
      }
      const ok = this.stateName === 'playing' || this.stateName === 'paused'
        || (this.stateName === 'prepared' && this.preparedIdle);
      if (ok) {
        return;
      }
      if (attempt >= 1) {
        this.switching = false;
        this.onError('播放器启动超时，滑动切换后重试');
        return;
      }
      this.rekick(gen, attempt + 1);
    }, 8000);
  }

  private async rekick(gen: number, attempt: number): Promise<void> {
    const p = this.player;
    if (!p) {
      return;
    }
    try {
      await p.reset();
    } catch (e) {
      return;
    }
    if (gen !== this.generation) {
      return;
    }
    this.stateName = 'idle';
    let st: string = p.state;
    if (st !== 'idle') {
      this.scheduleWatchdog(gen, attempt);
      return;
    }
    this.urlGen = gen;
    try {
      p.url = this.targetUrl;
    } catch (e) {
      this.switching = false;
      this.onError('播放器启动失败，滑动切换后重试');
      return;
    }
    this.scheduleWatchdog(gen, attempt);
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

  /** 期望倍速：attach/reset 会重置播放器，prepared 后按此值重新生效 */
  private pendingSpeed: media.PlaybackSpeed = media.PlaybackSpeed.SPEED_FORWARD_1_00_X;

  setSpeed(speed: media.PlaybackSpeed): void {
    this.pendingSpeed = speed;
    const ok = this.stateName === 'prepared' || this.stateName === 'playing'
      || this.stateName === 'paused' || this.stateName === 'completed';
    if (!ok) {
      return;
    }
    try {
      this.player?.setSpeed(speed);
    } catch (e) {
      // 静默：prepared 态还会再试一次
    }
  }

  private applySpeed(): void {
    try {
      this.player?.setSpeed(this.pendingSpeed);
    } catch (e) {
      // 静默
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
    this.clearWatchdog();
    if (this.player) {
      try { await this.player.release(); } catch (e) { /* 忽略 */ }
      this.player = null;
    }
  }
}

export const playerService: PlayerService = new PlayerService();
