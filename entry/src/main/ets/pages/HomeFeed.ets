/**
 * 首页信息流：竖向 Swiper + 每页内嵌 XComponent（单 AVPlayer 切流）。
 * 对应旧工程 Home.tsx + Feed.tsx。
 * 交互：抖音式底部进度条；右侧操作栏；沉浸全屏（横屏视频可旋转 90°）。
 */
import { VideoCard, VideoDetail, Comment, DlTask } from '../model';
import { feed, videoDetail, playUrl, coverUrl, ensureMedia, comments, commentSend, likeVideo, collect, followUser, dlAdd } from '../api';
import { fmtCount, store } from '../store';
import { playerService } from '../player/PlayerService';
import { promptAction } from '@kit.ArkUI';
import { media } from '@kit.MediaKit';
import { vibrator } from '@kit.SensorServiceKit';

/** AVPlayer 实际支持档位（无 1.5，规格中的 1.5 用 1.75 替代） */
const SPEED_STEPS: number[] = [1.0, 1.25, 1.75, 2.0];

function speedEnum(f: number): media.PlaybackSpeed {
  if (f === 1.25) {
    return media.PlaybackSpeed.SPEED_FORWARD_1_25_X;
  }
  if (f === 1.75) {
    return media.PlaybackSpeed.SPEED_FORWARD_1_75_X;
  }
  if (f === 2.0) {
    return media.PlaybackSpeed.SPEED_FORWARD_2_00_X;
  }
  return media.PlaybackSpeed.SPEED_FORWARD_1_00_X;
}

@Component
export struct HomeFeed {
  navStack: NavPathStack = new NavPathStack();
  onOpenSearch: () => void = () => {
  };
  /** 片单模式：非空则只播这些 id（搜索/榜单/收藏入口），无分页加载 */
  listIds: number[] = [];
  /** 片单模式起始下标（点击结果列表的第几条） */
  startIdx: number = 0;
  @State cards: VideoCard[] = [];
  @State activeIndex: number = 0;
  @State loading: boolean = false;
  @State done: boolean = false;
  @State errMsg: string = '';
  @State curDetail: VideoDetail | null = null;
  @State curCard: VideoCard | null = null;
  @State muted: boolean = true;
  @State ready: boolean = false;
  @State liked: boolean = false;
  @State faved: boolean = false;
  @State followed: boolean = false;
  @State curMs: number = 0;
  @State durMs: number = 0;
  @State dragging: boolean = false;
  @State dragMs: number = 0;
  @State playingIds: number[] = [];
  @State paused: boolean = false;
  @State playStateMsg: string = '';
  /** 当前播放的集号（每张卡的最后一集记录在 epMap，划回恢复） */
  @State curEp: number = 1;
  /** 底部弹层：'' 无 / 'ep' 选集 / 'cm' 评论 */
  @State showSheet: boolean = false;
  @State sheetKind: string = 'ep';
  @State epAsc: boolean = true;
  /** 长按 2x：进行中（松手恢复）/ 已锁定（点按解除）/ 松手锁定提示 */
  @State long2x: boolean = false;
  @State lock2x: boolean = false;
  @State lockHint: boolean = false;
  /** 全屏倍速循环档下标 */
  @State speedIdx: number = 0;
  /** 切集/连播加载中（新流出画面即消失） */
  @State epLoading: boolean = false;
  /** 评论面板 */
  @State cmItems: Comment[] = [];
  @State cmPage: number = 1;
  @State cmPages: number = 1;
  @State cmLoading: boolean = false;
  @State cmText: string = '';
  @State cmSending: boolean = false;
  /** 沉浸全屏：放 AppStorage，Main 的 onBackPress 能读到（返回键优先退全屏） */
  @StorageLink('feedFs') @Watch('onFsChange') fs: boolean = false;
  @State rotated: boolean = false;
  @State videoW: number = 0;
  @State videoH: number = 0;
  @State scrW: number = 0;
  @State scrH: number = 0;
  /** 片单模式下的封面（按激活拉详情填充；数组重赋值触发 UI 刷新） */
  @State listCovers: string[] = [];
  @StorageLink('dlTasks') dlTasks: DlTask[] = [];
  /** 首页 Tab 是否可见（切走时暂停/不自动起播，回来恢复） */
  @StorageLink('feedTabVisible') @Watch('onTabVisible') tabVisible: boolean = true;
  /** 实例已销毁（NavDestination pop 后异步链路必须中止） */
  private disposed: boolean = false;
  private detailCache: Map<number, VideoDetail> = new Map();
  private urlCache: Map<string, string> = new Map();
  private controllers: Map<number, XComponentController> = new Map();
  private surfaces: Map<number, string> = new Map();
  private page: number = 0;
  private pages: number = 1;
  private loadingMore: boolean = false;
  private loadGen: number = 0;
  private barWidth: number = 1;
  private dragStartMs: number = 0;
  private epMap: Map<number, number> = new Map();
  /** 长按 2x 触摸跟踪 */
  private pressY: number = 0;
  private longTimer: number = -1;
  private longArmed: boolean = false;

  /** 绑定播放器事件回调（单槽，attach 前重绑保证活跃流归当前实例） */
  private bindPlayer(): void {
    playerService.onTime = (ms: number) => {
      this.curMs = ms;
    };
    playerService.onDuration = (ms: number) => {
      this.durMs = ms;
    };
    playerService.onVideoSize = (w: number, h: number) => {
      this.videoW = w;
      this.videoH = h;
    };
    playerService.onPlaying = () => {
      const id = this.curCard ? this.curCard.id : 0;
      if (id > 0 && !this.playingIds.includes(id)) {
        this.playingIds = this.playingIds.concat([id]);
      }
      this.paused = false;
      this.playStateMsg = '';
      this.epLoading = false;
    };
    // 双保险：prepared 也摘封面（防 onPlaying 被状态校验丢弃导致封面卡死）
    playerService.onPrepared = () => {
      const id = this.curCard ? this.curCard.id : 0;
      if (id > 0 && !this.playingIds.includes(id)) {
        this.playingIds = this.playingIds.concat([id]);
      }
    };
    playerService.onPaused = () => {
      // 切流过程中的 pause 是收尾动作，不算用户暂停
      if (!playerService.switching) {
        this.paused = true;
      }
    };
    playerService.onCompleted = () => {
      // 切流收尾产生的 stopped 不触发连播
      if (playerService.switching) {
        return;
      }
      // 自动连播下一集；没有下一集则提示结束
      if (this.curDetail && this.curDetail.episodes.includes(this.curEp + 1)) {
        this.switchEp(this.curEp + 1);
      } else {
        this.playStateMsg = '播放结束';
      }
    };
    playerService.onError = (msg: string) => {
      this.playStateMsg = msg;
      this.epLoading = false;
    };
    // 起播闸门：prepared 时刻重新判定可见性/存活，杜绝 attach 与起播之间的竞态
    playerService.playGate = () => this.canAutoPlay();
  }

  aboutToAppear(): void {
    this.muted = store.muted;
    this.bindPlayer();
    if (this.listIds.length > 0) {
      this.initList();
    } else {
      this.initFeed();
    }
  }

  /** 片单模式：按传入 id 列表构建卡片（点中的那条旋转到第 0 位），无分页 */
  private async initList(): Promise<void> {
    try {
      await ensureMedia();
      if (this.disposed) {
        return;
      }
      const n = this.listIds.length;
      const start = Math.min(Math.max(0, this.startIdx), n - 1);
      this.cards = [];
      for (let k = 0; k < n; k++) {
        const c = new VideoCard();
        c.id = this.listIds[(start + k) % n];
        this.cards.push(c);
      }
      this.listCovers = this.cards.map(() => '');
      this.ready = true;
      this.activate(0);
    } catch (e) {
      this.errMsg = (e as Error).message;
    }
  }

  /** 详情到达后填充片单封面 */
  private fillCover(i: number, d: VideoDetail): void {
    if (i < 0 || i >= this.cards.length || this.listCovers[i] !== '' || d.cover === '') {
      return;
    }
    this.listCovers = this.listCovers.slice(0, i).concat([d.cover]).concat(this.listCovers.slice(i + 1));
  }

  /** 每页封面地址（片单模式从 listCovers 取，普通模式从卡片取） */
  private pageCover(id: number, i: number): string {
    if (this.listIds.length > 0) {
      return (i >= 0 && i < this.listCovers.length) ? this.listCovers[i] : '';
    }
    return id === 0 ? '' : (this.cards[i] ? this.cards[i].cover : '');
  }

  aboutToDisappear(): void {
    this.disposed = true;
    this.clearLongTimer();
    // 片单页退出时清掉全屏标记，避免残留到首页实例
    if (this.listIds.length > 0 && AppStorage.get<boolean>('feedFs') === true) {
      AppStorage.set<boolean>('feedFs', false);
    }
    playerService.release();
  }

  private onFsChange(): void {
    if (!this.fs) {
      this.rotated = false;
    }
  }

  /** 回到首页 Tab：恢复播放（流已就绪则续播，否则重新激活当前卡） */
  private onTabVisible(): void {
    if (!this.tabVisible || this.listIds.length > 0 || this.disposed) {
      return;
    }
    if (this.cards.length === 0 || this.activeIndex < 0) {
      return;
    }
    if (playerService.isPlaying() || playerService.switching) {
      return;
    }
    playerService.play();
  }

  /** 当前是否允许起播：片单页看销毁标记；首页 Tab 还要看可见性 */
  private canAutoPlay(): boolean {
    if (this.disposed) {
      return false;
    }
    if (this.listIds.length > 0) {
      return true;
    }
    return AppStorage.get<boolean>('feedTabVisible') !== false;
  }

  private ctrlFor(id: number): XComponentController {
    let c = this.controllers.get(id);
    if (!c) {
      c = new XComponentController();
      this.controllers.set(id, c);
    }
    return c;
  }

  /** 某页 surface 就绪：登记；若是当前卡则触发挂载 */
  private onPageLoad(id: number): void {
    const ctrl = this.controllers.get(id);
    if (ctrl) {
      const sid = ctrl.getXComponentSurfaceId();
      this.surfaces.set(id, sid);
    }
    if (this.curCard && this.curCard.id === id) {
      this.activate(this.activeIndex);
    }
  }

  async initFeed(): Promise<void> {
    try {
      await ensureMedia();
      await this.loadPage(1);
      this.ready = true;
      this.activate(0);
    } catch (e) {
      this.errMsg = (e as Error).message;
    }
  }

  async loadPage(p: number): Promise<void> {
    if (this.listIds.length > 0 || this.loadingMore || this.done) {
      return;
    }
    this.loadingMore = true;
    this.loading = this.cards.length === 0;
    try {
      const list = await feed(p, 10);
      const seen = new Set<number>(this.cards.map((c: VideoCard) => c.id));
      const fresh: VideoCard[] = list.filter((c: VideoCard) => !seen.has(c.id));
      this.cards = this.cards.concat(fresh);
      this.page = p;
      if (list.length === 0) {
        this.done = true;
      }
    } catch (e) {
      this.errMsg = (e as Error).message;
    } finally {
      this.loadingMore = false;
      this.loading = false;
    }
  }

  /** 激活某一页：切播放流 + 拉详情 + 写历史 + 预取 */
  async activate(index: number): Promise<void> {
    if (index < 0 || index >= this.cards.length) {
      return;
    }
    const gen = ++this.loadGen;
    this.activeIndex = index;
    this.bindPlayer();
    const card = this.cards[index];
    this.curCard = card;
    this.curEp = this.epMap.get(card.id) ?? 1;
    this.curMs = 0;
    this.durMs = 0;
    this.paused = false;
    this.playStateMsg = '';
    // 换卡复位倍速/长按状态
    this.clearLongTimer();
    this.long2x = false;
    this.lock2x = false;
    this.lockHint = false;
    this.speedIdx = 0;
    playerService.setSpeed(media.PlaybackSpeed.SPEED_FORWARD_1_00_X);
    this.liked = store.isLiked(card.id);
    this.faved = store.isFav(card.id);
    this.followed = store.isFollowed(this.authorId());
    // 旧页回落封面（不再属于播放中集合）
    this.playingIds = this.playingIds.filter((x: number) => x !== card.id);
    // 详情缓存（含邻接预取）
    for (const di of [index, index + 1, index - 1]) {
      if (di < 0 || di >= this.cards.length) {
        continue;
      }
      const cid = this.cards[di].id;
      if (!this.detailCache.has(cid)) {
        videoDetail(cid).then((d: VideoDetail) => {
          this.detailCache.set(cid, d);
          if (di === this.activeIndex && gen === this.loadGen) {
            this.curDetail = d;
          }
          this.fillCover(di, d);
        }).catch(() => {
        });
      } else if (di === index) {
        const d = this.detailCache.get(cid);
        this.curDetail = d ?? null;
        if (d) {
          this.fillCover(di, d);
        }
      }
    }
    // 播放地址
    const key = `${card.id}:${this.curEp}`;
    let url = this.urlCache.get(key) ?? '';
    if (url === '') {
      try {
        url = await playUrl(card.id, this.curEp);
        this.urlCache.set(key, url);
      } catch (e) {
        if (gen === this.loadGen) {
          this.errMsg = (e as Error).message;
        }
        return;
      }
    }
    if (gen !== this.loadGen) {
      return;
    }
    if (this.disposed) {
      return; // 页面已退出，中止挂载链路
    }
    this.errMsg = '';
    const sid = this.surfaces.get(card.id) ?? '';
    if (sid === '') {
      return; // surface 尚未 onLoad，onPageLoad 会再触发 activate
    }
    playerService.setMuted(this.muted);
    playerService.attach(url, sid, this.canAutoPlay());
    store.addHistory(card.id);
    if (index >= this.cards.length - 3) {
      this.loadPage(this.page + 1);
    }
  }

  /** 切换当前卡的剧集（选集面板点选 / 自动连播共用） */
  private async switchEp(ep: number): Promise<void> {
    const card = this.curCard;
    if (!card) {
      return;
    }
    this.epLoading = true;
    this.epMap.set(card.id, ep);
    this.curEp = ep;
    this.curMs = 0;
    this.durMs = 0;
    this.paused = false;
    this.playStateMsg = '';
    this.clearLongTimer();
    this.long2x = false;
    this.lock2x = false;
    this.lockHint = false;
    this.speedIdx = 0;
    playerService.setSpeed(media.PlaybackSpeed.SPEED_FORWARD_1_00_X);
    const gen = ++this.loadGen;
    this.bindPlayer();
    const key = `${card.id}:${ep}`;
    let url = this.urlCache.get(key) ?? '';
    if (url === '') {
      try {
        url = await playUrl(card.id, ep);
        this.urlCache.set(key, url);
      } catch (e) {
        this.epLoading = false;
        if (gen === this.loadGen) {
          this.errMsg = (e as Error).message;
        }
        return;
      }
    }
    if (gen !== this.loadGen) {
      this.epLoading = false;
      return;
    }
    if (this.disposed) {
      this.epLoading = false;
      return;
    }
    this.errMsg = '';
    const sid = this.surfaces.get(card.id) ?? '';
    if (sid === '') {
      this.epLoading = false;
      return;
    }
    playerService.setMuted(this.muted);
    playerService.attach(url, sid, this.canAutoPlay());
  }

  /* ── 长按 2x 倍速 ── */

  private clearLongTimer(): void {
    if (this.longTimer >= 0) {
      clearTimeout(this.longTimer);
      this.longTimer = -1;
    }
  }

  private vibrateShort(): void {
    try {
      vibrator.startVibration({ type: 'time', duration: 25 }, { usage: 'touch' })
        .catch(() => {
        });
    } catch (e) {
      // 无振动能力则静默
    }
  }

  private onTouchCard(e: TouchEvent): void {
    if (e.type === TouchType.Down) {
      this.pressY = e.touches.length > 0 ? e.touches[0].y : 0;
      this.longArmed = true;
      this.lockHint = false;
      if (this.longTimer < 0) {
        this.longTimer = setTimeout(() => {
          this.longTimer = -1;
          if (this.longArmed && !this.lock2x) {
            this.long2x = true;
            playerService.setSpeed(media.PlaybackSpeed.SPEED_FORWARD_2_00_X);
            this.vibrateShort();
          }
        }, 380);
      }
    } else if (e.type === TouchType.Move) {
      const y = e.touches.length > 0 ? e.touches[0].y : this.pressY;
      // 长按期间上滑超过 64px → 标记"松手锁定 2x"
      if (this.long2x && this.pressY - y > 64) {
        this.lockHint = true;
      }
    } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
      this.longArmed = false;
      this.clearLongTimer();
      if (this.long2x) {
        this.long2x = false;
        if (this.lockHint) {
          this.lockHint = false;
          this.lock2x = true; // 保持 2x，直到点按解除
        } else {
          playerService.setSpeed(media.PlaybackSpeed.SPEED_FORWARD_1_00_X);
        }
      }
    }
  }

  /** 全屏控制条：倍速循环切换 */
  private cycleSpeed(): void {
    const next = (this.speedIdx + 1) % SPEED_STEPS.length;
    this.speedIdx = next;
    playerService.setSpeed(speedEnum(SPEED_STEPS[next]));
  }

  /* ── 评论面板 ── */

  private async openComments(): Promise<void> {
    if (!this.curCard) {
      return;
    }
    this.sheetKind = 'cm';
    this.cmItems = [];
    this.cmPage = 1;
    this.cmPages = 1;
    this.cmText = '';
    this.showSheet = true;
    await this.loadComments(1);
  }

  private async loadComments(p: number): Promise<void> {
    if (!this.curCard || this.cmLoading) {
      return;
    }
    this.cmLoading = true;
    try {
      const res = await comments(this.curCard.id, this.curEp, p, 20);
      if (p === 1) {
        this.cmItems = res.items;
      } else {
        const seen = new Set<number>(this.cmItems.map((c: Comment) => c.id));
        this.cmItems = this.cmItems.concat(res.items.filter((c: Comment) => !seen.has(c.id)));
      }
      this.cmPage = p;
      this.cmPages = res.pages;
    } catch (e) {
      if (p === 1) {
        this.cmItems = [];
      }
    } finally {
      this.cmLoading = false;
    }
  }

  private async sendComment(): Promise<void> {
    const t = this.cmText.trim();
    if (t === '' || !this.curCard || this.cmSending) {
      return;
    }
    if (!store.loggedIn()) {
      promptAction.showToast({ message: '请先登录（登录功能阶段 5 接入）' });
      return;
    }
    this.cmSending = true;
    try {
      await commentSend(this.curCard.id, this.curEp, t);
      this.cmText = '';
      promptAction.showToast({ message: '评论已提交，审核通过后展示' });
      await this.loadComments(1);
    } catch (e) {
      promptAction.showToast({ message: (e as Error).message });
    } finally {
      this.cmSending = false;
    }
  }

  /** 评论头像底色（按用户 id 稳定取色） */
  private cmtColor(uid: number): string {
    const palette: string[] = ['#4a90d9', '#e056a7', '#3fbf8f', '#d98a3f', '#8f6fd9', '#d9593f'];
    return palette[Math.abs(uid) % palette.length];
  }

  /* ── 元信息 ── */

  private metaTitle(): string {
    return (this.curDetail && this.curDetail.title !== '') ? this.curDetail.title : (this.curCard ? this.curCard.title : '');
  }

  /** 当前集下载状态：idle 可下 / active 下载中（含排队）/ done 已完成 */
  private dlStateFor(): string {
    const vid = this.curDetail ? this.curDetail.id : (this.curCard ? this.curCard.id : 0);
    if (vid === 0) {
      return 'idle';
    }
    for (const t of (this.dlTasks ?? [])) {
      if (t.video_id === vid && t.ep === this.curEp) {
        return t.status === 'done' ? 'done' : 'active';
      }
    }
    return 'idle';
  }

  /** 加入下载（重复任务由 Rust 侧返回 null，前端提示） */
  private onDownload(): void {
    const vid = this.curDetail ? this.curDetail.id : (this.curCard ? this.curCard.id : 0);
    if (vid === 0) {
      return;
    }
    const st = this.dlStateFor();
    if (st === 'done') {
      promptAction.showToast({ message: '本集已下载，可在「我的下载」查看' });
      return;
    }
    if (st === 'active') {
      promptAction.showToast({ message: '本集已在下载列表中' });
      return;
    }
    dlAdd(vid, this.curEp, this.metaTitle(), `第${this.curEp}集`)
      .then((id: number | null) => {
        promptAction.showToast({ message: id !== null ? '已加入下载' : '本集已在下载列表中' });
      })
      .catch((e: Error) => {
        promptAction.showToast({ message: e.message });
      });
  }

  private metaAuthor(): string {
    return (this.curDetail && this.curDetail.authorName !== '') ? this.curDetail.authorName : (this.curCard ? this.curCard.authorName : '');
  }

  private metaEp(): string {
    const d = this.curDetail;
    if (d && d.episodes.length > 0) {
      return `第 ${this.curEp}/${d.episodes.length} 集`;
    }
    return '';
  }

  private likeCount(): number {
    const base = this.curDetail ? this.curDetail.likeCount : (this.curCard ? this.curCard.likeCount : 0);
    return base + (this.liked ? 1 : 0);
  }

  private commentCount(): number {
    return this.curDetail ? this.curDetail.commentCount : (this.curCard ? this.curCard.commentCount : 0);
  }

  private collectCount(): number {
    const base = this.curDetail ? this.curDetail.collectCount : (this.curCard ? this.curCard.collectCount : 0);
    return base + (this.faved ? 1 : 0);
  }

  private authorId(): number {
    if (this.curDetail && this.curDetail.authorId > 0) {
      return this.curDetail.authorId;
    }
    return this.curCard ? Math.abs(this.curCard.id) : 0;
  }

  private avatarChar(): string {
    const name = this.metaAuthor();
    return name === '' ? '?' : name.substring(0, 1);
  }

  private avatarColor(): string {
    const palette: string[] = ['#4a90d9', '#e056a7', '#3fbf8f', '#d98a3f', '#8f6fd9', '#d9593f'];
    return palette[Math.abs(this.authorId()) % palette.length];
  }

  private async toggleLike(): Promise<void> {
    if (!this.curCard) {
      return;
    }
    this.liked = await store.toggleLike(this.curCard.id);
    if (store.loggedIn()) {
      likeVideo(this.curCard.id, this.curEp, this.liked).catch(() => {
      });
    }
    promptAction.showToast({ message: this.liked ? '已加入喜欢' : '已取消喜欢' });
  }

  private async toggleFav(): Promise<void> {
    if (!this.curCard) {
      return;
    }
    this.faved = await store.toggleFav(this.curCard.id);
    if (store.loggedIn()) {
      collect(this.curCard.id, this.faved).catch(() => {
      });
    }
    promptAction.showToast({ message: this.faved ? '已收藏' : '已取消收藏' });
  }

  private async toggleFollow(): Promise<void> {
    const uid = this.authorId();
    if (uid <= 0) {
      return;
    }
    this.followed = await store.toggleFollow(uid);
    if (store.loggedIn()) {
      followUser(uid, this.followed).catch(() => {
      });
    }
    promptAction.showToast({ message: this.followed ? '已关注' : '已取消关注' });
  }

  /* ── 进度条 ── */

  private fmtTime(ms: number): string {
    const s = Math.max(0, Math.floor(ms / 1000));
    const m = Math.floor(s / 60);
    return `${m}:${String(s % 60).padStart(2, '0')}`;
  }

  private barProgress(): number {
    const ms = this.dragging ? this.dragMs : this.curMs;
    const d = this.durMs > 0 ? this.durMs : 1;
    return Math.max(0, Math.min(1, ms / d));
  }

  private onBarDrag(offsetX: number): void {
    const target = this.dragStartMs + (offsetX / this.barWidth) * this.durMs;
    this.dragMs = Math.max(0, Math.min(this.durMs, target));
  }

  private endBarDrag(): void {
    this.dragging = false;
    if (this.durMs > 0) {
      playerService.seek(this.dragMs);
      this.curMs = this.dragMs;
    }
  }

  /* ── 播放/暂停 ── */

  private isLandscape(): boolean {
    return this.videoW > 0 && this.videoH > 0 && this.videoW > this.videoH;
  }

  private async togglePlay(): Promise<void> {
    if (playerService.isPlaying()) {
      await playerService.pause();
    } else {
      await playerService.play();
    }
  }

  /** 非旋转横屏视频的组件高：scrW × (h/w)（宽度铺满屏宽） */
  private landscapeH(): number {
    const vw = Math.max(1, this.videoW);
    return this.scrW * this.videoH / vw;
  }

  /** 旋转态组件宽：scrW × (w/h)（旋转后视频长边铺满屏向），超出屏高则截断 */
  private rotatedW(): number {
    const vh = Math.max(1, this.videoH);
    return Math.min(this.scrW * this.videoW / vh, this.scrH);
  }

  /* ── 底部弹层 ── */

  private epList(): number[] {
    const eps = this.curDetail ? this.curDetail.episodes : [];
    return this.epAsc ? eps : eps.slice().reverse();
  }

  @Builder
  sheetBody() {
    if (this.sheetKind === 'cm') {
      this.commentsSheet();
    } else {
      this.episodesSheet();
    }
  }

  @Builder
  sheetHeader(title: string, count: string) {
    Row({ space: 8 }) {
      Text(title)
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor('#e8eaf0')
      Text(count)
        .fontSize(11)
        .fontColor('#8fa3c0')
        .backgroundColor('#262a33')
        .borderRadius(10)
        .padding({ left: 8, right: 8, top: 2, bottom: 2 })
      Blank()
      if (this.sheetKind === 'ep') {
        Text(this.epAsc ? '倒序' : '正序')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor('#ff4d6a')
          .backgroundColor('rgba(255,77,106,0.12)')
          .borderRadius(14)
          .padding({ left: 12, right: 12, top: 5, bottom: 5 })
          .onClick(() => {
            this.epAsc = !this.epAsc;
          })
      }
      Text('✕')
        .fontSize(12)
        .fontColor('#c3cad6')
        .textAlign(TextAlign.Center)
        .width(30)
        .height(30)
        .backgroundColor('#262a33')
        .borderRadius(15)
        .onClick(() => {
          this.showSheet = false;
        })
    }
    .width('100%')
    .height(56)
    .padding({ left: 16, right: 16 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  episodesSheet() {
    Column() {
      this.sheetHeader('选集', `共 ${this.curDetail ? this.curDetail.episodes.length : 0} 集`)

      if (this.curDetail && this.curDetail.episodes.length > 0) {
        Grid() {
          ForEach(this.epList(), (ep: number) => {
            GridItem() {
              Text(`${ep}`)
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor(ep === this.curEp ? '#ffffff' : '#c3cad6')
                .backgroundColor(ep === this.curEp ? '#ff4d6a' : '#262a33')
                .borderRadius(10)
                .textAlign(TextAlign.Center)
                .width('100%')
                .height(40)
                .onClick(() => {
                  this.switchEp(ep);
                  this.showSheet = false;
                })
            }
            .height(40)
          }, (ep: number) => `${ep}`)
        }
        .columnsTemplate('1fr 1fr 1fr 1fr')
        .columnsGap(10)
        .rowsGap(10)
        .padding({ left: 16, right: 16, top: 4, bottom: 16 })
        .layoutWeight(1)
      } else {
        Column() {
          Text('暂无剧集')
            .fontSize(12)
            .fontColor('#5c6678')
            .padding({ top: 40 })
        }
        .width('100%')
        .layoutWeight(1)
      }

      Text('点选即切换播放')
        .fontSize(10.5)
        .fontColor('#5c6678')
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 6, bottom: 10 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#16181d')
  }

  @Builder
  commentsSheet() {
    Column() {
      this.sheetHeader('评论', `${fmtCount(this.commentCount())} 条`)

      if (this.cmItems.length === 0 && !this.cmLoading) {
        Column() {
          Text('还没有评论，来说两句吧')
            .fontSize(12)
            .fontColor('#5c6678')
            .padding({ top: 40 })
        }
        .width('100%')
        .layoutWeight(1)
      } else {
        List() {
          ForEach(this.cmItems, (c: Comment) => {
            ListItem() {
              this.commentItem(c)
            }
          }, (c: Comment) => `${c.id}`)
          ListItem() {
            Text(this.cmLoading ? '加载中…' : (this.cmPage >= this.cmPages ? '— 到底了 —' : ''))
              .fontSize(10.5)
              .fontColor('#5c6678')
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 8, bottom: 8 })
          }
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 16, right: 16 })
        .onReachEnd(() => {
          if (this.cmPage < this.cmPages) {
            this.loadComments(this.cmPage + 1);
          }
        })
      }

      Row({ space: 8 }) {
        TextInput({ text: this.cmText, placeholder: '说点什么…' })
          .layoutWeight(1)
          .height(38)
          .backgroundColor('#262a33')
          .fontColor('#e8eaf0')
          .placeholderColor('#5c6678')
          .borderRadius(19)
          .onChange((v: string) => {
            this.cmText = v;
          })
        Button() {
          Text('发送')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor('#ffffff')
        }
        .height(38)
        .borderRadius(19)
        .padding({ left: 18, right: 18 })
        .backgroundColor(this.cmSending ? '#8a3a4e' : '#ff4d6a')
        .onClick(() => {
          this.sendComment();
        })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 12 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#16181d')
  }

  @Builder
  commentItem(c: Comment) {
    Row({ space: 10 }) {
      Stack() {
        Circle({ width: 34, height: 34 })
          .fill(this.cmtColor(c.userId))
        if (c.nickname !== '') {
          Text(c.nickname.substring(0, 1))
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor('#ffffff')
        }
      }
      .width(34)
      .height(34)

      Column({ space: 4 }) {
        Row({ space: 6 }) {
          Text(c.nickname === '' ? `用户${c.userId}` : c.nickname)
            .fontSize(12)
            .fontColor('#8fa3c0')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (c.isPinned) {
            Text('置顶')
              .fontSize(9)
              .fontColor('#ffb84d')
              .backgroundColor('rgba(255,184,77,0.15)')
              .borderRadius(3)
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
          }
          Blank()
          Text(`${c.time}${c.ipRegion !== '' ? ` · ${c.ipRegion}` : ''}`)
            .fontSize(10)
            .fontColor('#5c6678')
        }
        .width('100%')

        Text(c.text)
          .fontSize(13)
          .fontColor('#e8eaf0')

        Row({ space: 10 }) {
          Text(`赞 ${fmtCount(c.likeCount)}`)
            .fontSize(10)
            .fontColor('#5c6678')
          Text(`回复 ${c.replyCount}`)
            .fontSize(10)
            .fontColor('#5c6678')
        }
        .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ top: 10, bottom: 10 })
  }

  build() {
    Stack() {
      // 卡片轮播：每页内嵌视频表面（画面随页面滑动）+ 封面遮罩 + 单击暂停
      Swiper() {
        ForEach(this.cards, (c: VideoCard, i: number) => {
          Stack() {
            // 视频表面：按视频宽高比定尺寸（横屏不拉伸）；旋转态尺寸对调
            XComponent({ id: `vp_${c.id}`, type: 'surface', controller: this.ctrlFor(c.id) })
              .width(this.rotated ? this.rotatedW() : '100%')
              .height(this.rotated ? this.scrW : (this.isLandscape() ? this.landscapeH() : '100%'))
              .backgroundColor(Color.Black)
              .rotate({ z: 1, angle: this.rotated ? 90 : 0, centerX: '50%', centerY: '50%' })
              .hitTestBehavior(HitTestMode.Transparent)
              .onLoad(() => {
                this.onPageLoad(c.id);
              })
            if (!this.playingIds.includes(c.id) && this.pageCover(c.id, i) !== '') {
              Image(coverUrl(this.pageCover(c.id, i)))
                .width('100%')
                .height('100%')
                .objectFit(ImageFit.Cover)
                .hitTestBehavior(HitTestMode.Transparent)
            }
            // 暂停时的大播放键（仅当前页）
            if (this.paused && this.curCard && c.id === this.curCard.id) {
              Stack() {
                Circle({ width: 66, height: 66 })
                  .fill('rgba(0,0,0,0.4)')
                Image($r('app.media.ic_play_f'))
                  .width(28)
                  .height(28)
              }
            }
          }
          .width('100%')
          .height('100%')
          .onTouch((e: TouchEvent) => {
            this.onTouchCard(e);
          })
          .gesture(TapGesture({ count: 1 }).onAction(() => {
            if (this.lock2x) {
              // 锁定态：第一次点按只解除锁定
              this.lock2x = false;
              playerService.setSpeed(media.PlaybackSpeed.SPEED_FORWARD_1_00_X);
              return;
            }
            this.togglePlay();
          }))
        }, (c: VideoCard) => `${c.id}`)
      }
      .vertical(true)
      .loop(false)
      .indicator(false)
      .cachedCount(1)
      // 长按 2x 期间禁用原生滚动，防止上滑被列表吃掉
      .disableSwipe(this.fs || this.long2x)
      .width('100%')
      .height('100%')
      .onChange((i: number) => {
        // 旧视频完全划走的瞬间立即停声画（新流 attach 后自动恢复播放）；
        // switching 标记防止这一瞬间的 onPaused 闪出暂停大按钮
        playerService.switching = true;
        playerService.pause();
        this.activate(i);
      })

      // 倍速状态胶囊（顶部居中）
      if (this.long2x || this.lock2x) {
        Text(this.lockHint ? '松手锁定 2x' : (this.lock2x ? '已锁定 2x · 点击解除' : '2x 倍速中'))
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor('#ffffff')
          .padding({ left: 12, right: 12, top: 5, bottom: 5 })
          .backgroundColor('rgba(0,0,0,0.65)')
          .borderRadius(14)
          .position({ x: '50%', y: 62 })
          .markAnchor({ x: '50%', y: 0 })
      }

      // 顶部：返回（片单模式）+ 横竖屏切换 + 静音/搜索（非全屏）+ 退出
      Row({ space: 8 }) {
        if (this.listIds.length > 0) {
          Button() {
            Image($r('app.media.ic_back'))
              .width(18)
              .height(18)
          }
          .type(ButtonType.Circle)
          .width(36)
          .height(36)
          .backgroundColor('rgba(0,0,0,0.4)')
          .onClick(() => {
            if (this.fs) {
              this.fs = false;
            } else {
              this.navStack.pop();
            }
          })
        }
        Blank()
        if (this.isLandscape() && (this.fs || this.rotated)) {
          Text(this.rotated ? '竖屏' : '横屏')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor('#ffffff')
            .padding({ left: 14, right: 14, top: 6, bottom: 6 })
            .backgroundColor('rgba(0,0,0,0.5)')
            .borderRadius(16)
            .margin({ right: 8 })
            .onClick(() => {
              this.rotated = !this.rotated;
            })
        }
        if (this.fs) {
          Button() {
            Image($r('app.media.ic_compress'))
              .width(18)
              .height(18)
          }
          .type(ButtonType.Circle)
          .width(36)
          .height(36)
          .backgroundColor('rgba(0,0,0,0.45)')
          .onClick(() => {
            this.fs = false;
            this.rotated = false;
          })
        } else {
          Button() {
            Image(this.muted ? $r('app.media.ic_vol_mute') : $r('app.media.ic_vol'))
              .width(17)
              .height(17)
          }
          .type(ButtonType.Circle)
          .width(36)
          .height(36)
          .backgroundColor('rgba(0,0,0,0.4)')
          .onClick(() => {
            this.muted = !this.muted;
            store.setMuted(this.muted);
            playerService.setMuted(this.muted);
          })
          Button() {
            Image($r('app.media.ic_search'))
              .width(18)
              .height(18)
          }
          .type(ButtonType.Circle)
          .width(36)
          .height(36)
          .margin({ left: 8 })
          .backgroundColor('rgba(0,0,0,0.4)')
          .onClick(() => {
            this.onOpenSearch();
          })
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10 })
      .position({ x: 0, y: 0 })
      .hitTestBehavior(HitTestMode.Transparent)

      // 右侧纵向操作栏（非全屏时）：底部对齐
      if (!this.fs) {
        Row() {
          Blank()
          Column({ space: 14 }) {
            // 作者头像 + 关注角标
            Stack() {
              Circle({ width: 44, height: 44 })
                .fill(this.avatarColor())
              Text(this.avatarChar())
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor('#ffffff')
                .position({ x: '50%', y: '50%' })
                .markAnchor({ x: '50%', y: '50%' })
              Circle({ width: 18, height: 18 })
                .fill(this.followed ? '#2a3040' : '#ff4d6a')
                .position({ x: 33, y: 33 })
              Image($r('app.media.ic_plus'))
                .width(10)
                .height(10)
                .position({ x: 37, y: 37 })
            }
            .width(44)
            .height(44)
            .onClick(() => {
              this.toggleFollow();
            })

            Column({ space: 3 }) {
              Image($r('app.media.ic_comment_f'))
                .width(26)
                .height(26)
                .onClick(() => {
                  this.openComments();
                })
              Text(fmtCount(this.commentCount()))
                .fontSize(10.5)
                .fontColor('#ffffff')
                .shadow({ radius: 3, color: 'rgba(0,0,0,0.7)', offsetX: 0, offsetY: 1 })
            }
            .alignItems(HorizontalAlign.Center)

            Column({ space: 3 }) {
              Image(this.faved ? $r('app.media.ic_star_f') : $r('app.media.ic_star'))
                .width(25)
                .height(25)
                .onClick(() => {
                  this.toggleFav();
                })
              Text(fmtCount(this.collectCount()))
                .fontSize(10.5)
                .fontColor(this.faved ? '#ffb84d' : '#ffffff')
                .shadow({ radius: 3, color: 'rgba(0,0,0,0.7)', offsetX: 0, offsetY: 1 })
            }
            .alignItems(HorizontalAlign.Center)

            Column({ space: 3 }) {
              if (this.dlStateFor() === 'active') {
                LoadingProgress()
                  .width(22)
                  .height(22)
                  .color('#ff4d6a')
              } else {
                Image($r('app.media.ic_download'))
                  .width(26)
                  .height(26)
                  .fillColor(this.dlStateFor() === 'done' ? '#ffb84d' : '#ffffff')
              }
              Text('下载')
                .fontSize(10.5)
                .fontColor(this.dlStateFor() === 'done' ? '#ffb84d' : '#ffffff')
                .shadow({ radius: 3, color: 'rgba(0,0,0,0.7)', offsetX: 0, offsetY: 1 })
            }
            .alignItems(HorizontalAlign.Center)
            .onClick(() => {
              this.onDownload();
            })

            Column({ space: 3 }) {
              Image($r('app.media.ic_list'))
                .width(25)
                .height(25)
                .onClick(() => {
                  this.sheetKind = 'ep';
                  this.showSheet = true;
                })
              Text('选集')
                .fontSize(10.5)
                .fontColor('#ffffff')
                .shadow({ radius: 3, color: 'rgba(0,0,0,0.7)', offsetX: 0, offsetY: 1 })
            }
            .alignItems(HorizontalAlign.Center)

          }
          .alignItems(HorizontalAlign.Center)
          .padding({ right: 14, bottom: 96 })
        }
        .width('100%')
        .height('100%')
        .alignItems(VerticalAlign.Bottom)
        .position({ x: 0, y: 0 })
        .hitTestBehavior(HitTestMode.Transparent)
      }

      // 底部：信息层 + 全屏按钮 + 进度条（底部对齐）
      Column() {
        Blank()
        if (!this.fs) {
          Row() {
            Column({ space: 6 }) {
              Row({ space: 8 }) {
                Text(`@${this.metaAuthor()}`)
                  .fontSize(15)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#ffffff')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .shadow({ radius: 4, color: 'rgba(0,0,0,0.7)', offsetX: 0, offsetY: 1 })
                if (this.metaEp() !== '') {
                  Text(this.metaEp())
                    .fontSize(10)
                    .fontColor('#ffffff')
                    .backgroundColor('rgba(255,255,255,0.15)')
                    .borderRadius(4)
                    .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                }
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)

              Text(this.metaTitle())
                .fontSize(13.5)
                .fontColor('#ffffff')
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .shadow({ radius: 4, color: 'rgba(0,0,0,0.7)', offsetX: 0, offsetY: 1 })

              if (this.errMsg !== '') {
                Text(`⚠ ${this.errMsg}`)
                  .fontSize(11)
                  .fontColor('#ff9a9a')
                  .maxLines(2)
              }
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Button() {
              Image($r('app.media.ic_expand'))
                .width(17)
                .height(17)
            }
            .type(ButtonType.Circle)
            .width(36)
            .height(36)
            .backgroundColor('rgba(0,0,0,0.45)')
            .onClick(() => {
              this.fs = true;
            })
          }
          .width('100%')
          .padding({ left: 14, right: 14, bottom: 6 })
          .alignItems(VerticalAlign.Bottom)
        } else {
          Row({ space: 12 }) {
            Image(this.paused ? $r('app.media.ic_play_f') : $r('app.media.ic_pause_f'))
              .width(18)
              .height(18)
              .onClick(() => {
                this.togglePlay();
              })
            Text(`${this.fmtTime(this.curMs)} / ${this.fmtTime(this.durMs)}`)
              .fontSize(11.5)
              .fontColor('#ffffff')
            Blank()
            Text(`${SPEED_STEPS[this.speedIdx]}x`)
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.speedIdx > 0 ? '#ff4d6a' : '#ffffff')
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .backgroundColor('rgba(0,0,0,0.45)')
              .borderRadius(12)
              .onClick(() => {
                this.cycleSpeed();
              })
          }
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 6 })
        }

        // 进度条
        Column() {
          if (this.dragging && this.durMs > 0) {
            Text(`${this.fmtTime(this.dragMs)} / ${this.fmtTime(this.durMs)}`)
              .fontSize(13)
              .fontWeight(FontWeight.Bold)
              .fontColor('#ffffff')
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .backgroundColor('rgba(0,0,0,0.7)')
              .borderRadius(8)
              .margin({ bottom: 8 })
          }
          Row() {
            Row()
              .width(`${this.barProgress() * 100}%`)
              .height(this.dragging ? 5 : 2.5)
              .backgroundColor(this.dragging ? '#ff4d6a' : '#ffffff')
              .borderRadius(2.5)
            Row()
              .layoutWeight(1)
              .height(this.dragging ? 5 : 2.5)
              .backgroundColor('rgba(255,255,255,0.2)')
              .borderRadius(2.5)
            if (this.dragging) {
              Circle({ width: 12, height: 12 })
                .fill('#ff4d6a')
                .margin({ left: -12 })
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .padding({ bottom: 8, top: 4 })
        .onAreaChange((oldArea: Area, newArea: Area) => {
          const w: number = newArea.width as number;
          this.barWidth = w > 0 ? w : 1;
        })
        .gesture(PanGesture({ direction: PanDirection.Horizontal, fingers: 1, distance: 5 })
          .onActionStart(() => {
            if (this.durMs <= 0) {
              return;
            }
            this.dragStartMs = this.curMs;
            this.dragMs = this.curMs;
            this.dragging = true;
            this.onBarDrag(0);
          })
          .onActionUpdate((e: GestureEvent) => {
            if (this.dragging) {
              this.onBarDrag(e.offsetX);
            }
          })
          .onActionEnd(() => {
            if (this.dragging) {
              this.endBarDrag();
            }
          }))
      }
      .width('100%')
      .height('100%')
      .position({ x: 0, y: 0 })
      .hitTestBehavior(HitTestMode.Transparent)

      // 播放状态提示
      if (this.playStateMsg !== '') {
        Text(this.playStateMsg)
          .fontSize(12)
          .fontColor('#ffcccc')
          .position({ x: '50%', y: '50%' })
          .markAnchor({ x: '50%', y: '50%' })
      }

      // 切集/连播加载指示
      if (this.epLoading) {
        Column({ space: 8 }) {
          LoadingProgress()
            .width(32)
            .height(32)
            .color('#e8eaf0')
          Text('切换中…')
            .fontSize(12)
            .fontColor('#c3cad6')
        }
        .alignItems(HorizontalAlign.Center)
        .padding({ left: 22, right: 22, top: 16, bottom: 16 })
        .backgroundColor('rgba(0,0,0,0.45)')
        .borderRadius(14)
        .position({ x: '50%', y: '50%' })
        .markAnchor({ x: '50%', y: '50%' })
      }

      // 加载态
      if (!this.ready && this.errMsg === '') {
        Column({ space: 10 }) {
          LoadingProgress()
            .width(36)
            .height(36)
            .color('#e8eaf0')
          Text('加载中…')
            .fontSize(12)
            .fontColor('#8fa3c0')
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#000000')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
    .onAreaChange((oldArea: Area, newArea: Area) => {
      this.scrW = newArea.width as number;
      this.scrH = newArea.height as number;
    })
    // 底部弹层（选集 / 评论共用一个 sheet，内容按 sheetKind 切换）
    .bindSheet($$this.showSheet, this.sheetBody(), {
      height: '72%',
      dragBar: true,
      showClose: false,
      backgroundColor: '#16181d'
    })
  }
}
