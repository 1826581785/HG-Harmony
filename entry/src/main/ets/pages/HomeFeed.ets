/**
 * 首页信息流：竖向 Swiper + 单 XComponent/单 AVPlayer 切流。
 * 对应旧工程 Home.tsx + Feed.tsx。
 * 交互：抖音式底部进度条（平时细条，拖动变粗 + 时间气泡，松手 seek）；
 * 右侧纵向操作栏；播放成功前显示封面。
 */
import { VideoCard, VideoDetail } from '../model';
import { feed, videoDetail, playUrl, coverUrl, ensureMedia } from '../api';
import { fmtCount, store } from '../store';
import { playerService } from '../player/PlayerService';
import { promptAction } from '@kit.ArkUI';

@Component
export struct HomeFeed {
  navStack: NavPathStack = new NavPathStack();
  onOpenSearch: () => void = () => {
  };
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
  @State coverVisible: boolean = true;
  @State playStateMsg: string = '';
  private surfaceId: string = '';
  private xcController: XComponentController = new XComponentController();
  private detailCache: Map<number, VideoDetail> = new Map();
  private urlCache: Map<string, string> = new Map();
  private page: number = 0;
  private pages: number = 1;
  private loadingMore: boolean = false;
  private loadGen: number = 0;
  /** 进度条热区宽度（onAreaChange 记录） */
  private barWidth: number = 1;
  private dragStartMs: number = 0;

  aboutToAppear(): void {
    this.muted = store.muted;
    playerService.onTime = (ms: number) => {
      this.curMs = ms;
    };
    playerService.onDuration = (ms: number) => {
      this.durMs = ms;
    };
    playerService.onPlaying = () => {
      this.coverVisible = false;
      this.playStateMsg = '';
    };
    playerService.onPaused = () => {
    };
    playerService.onCompleted = () => {
      this.playStateMsg = '播放结束';
    };
    playerService.onError = (msg: string) => {
      this.playStateMsg = msg;
    };
    this.initFeed();
  }

  aboutToDisappear(): void {
    playerService.release();
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
    if (this.loadingMore || this.done) {
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
    const card = this.cards[index];
    this.curCard = card;
    this.curMs = 0;
    this.durMs = 0;
    this.playStateMsg = '';
    this.coverVisible = true;
    this.liked = store.isLiked(card.id);
    this.faved = store.isFav(card.id);
    this.followed = store.isFollowed(this.authorId());
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
        }).catch(() => {
        });
      } else if (di === index) {
        this.curDetail = this.detailCache.get(cid) ?? null;
      }
    }
    // 播放
    const key = `${card.id}:1`;
    let url = this.urlCache.get(key) ?? '';
    if (url === '') {
      try {
        url = await playUrl(card.id, 1);
        this.urlCache.set(key, url);
      } catch (e) {
        if (gen === this.loadGen) {
          this.errMsg = (e as Error).message;
        }
        return;
      }
    }
    if (gen !== this.loadGen || this.surfaceId === '') {
      return;
    }
    this.errMsg = '';
    playerService.setMuted(this.muted);
    playerService.attach(url, this.surfaceId);
    store.addHistory(card.id);
    // 预取下一页
    if (index >= this.cards.length - 3) {
      this.loadPage(this.page + 1);
    }
  }

  private coverOf(): string {
    const raw = (this.curDetail && this.curDetail.cover !== '') ? this.curDetail.cover : (this.curCard ? this.curCard.cover : '');
    return coverUrl(raw);
  }

  private metaTitle(): string {
    return (this.curDetail && this.curDetail.title !== '') ? this.curDetail.title : (this.curCard ? this.curCard.title : '');
  }

  private metaAuthor(): string {
    return (this.curDetail && this.curDetail.authorName !== '') ? this.curDetail.authorName : (this.curCard ? this.curCard.authorName : '');
  }

  private metaEp(): string {
    const d = this.curDetail;
    if (d && d.episodes.length > 0) {
      return `第 1/${d.episodes.length} 集`;
    }
    return '';
  }

  private likeCount(): number {
    const base = this.curDetail ? this.curDetail.likeCount : (this.curCard ? this.curCard.likeCount : 0);
    return base + (this.liked ? 1 : 0);
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

  private async toggleFollow(): Promise<void> {
    const uid = this.authorId();
    if (uid <= 0) {
      return;
    }
    this.followed = await store.toggleFollow(uid);
    promptAction.showToast({ message: this.followed ? '已关注' : '已取消关注' });
  }

  private commentCount(): number {
    return this.curDetail ? this.curDetail.commentCount : (this.curCard ? this.curCard.commentCount : 0);
  }

  private collectCount(): number {
    const base = this.curDetail ? this.curDetail.collectCount : (this.curCard ? this.curCard.collectCount : 0);
    return base + (this.faved ? 1 : 0);
  }

  private async toggleLike(): Promise<void> {
    if (!this.curCard) {
      return;
    }
    this.liked = await store.toggleLike(this.curCard.id);
    promptAction.showToast({ message: this.liked ? '已加入喜欢' : '已取消喜欢' });
  }

  private async toggleFav(): Promise<void> {
    if (!this.curCard) {
      return;
    }
    this.faved = await store.toggleFav(this.curCard.id);
    promptAction.showToast({ message: this.faved ? '已收藏' : '已取消收藏' });
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

  build() {
    Stack() {
      // 卡片轮播（每页显示封面）
      Swiper() {
        ForEach(this.cards, (c: VideoCard, i: number) => {
          Stack() {
            Image(coverUrl(c.cover))
              .width('100%')
              .height('100%')
              .objectFit(ImageFit.Cover)
          }
          .width('100%')
          .height('100%')
        }, (c: VideoCard) => `${c.id}`)
      }
      .vertical(true)
      .loop(false)
      .indicator(false)
      .cachedCount(1)
      .width('100%')
      .height('100%')
      .onChange((i: number) => {
        this.activate(i);
      })

      // 单一视频表面：切页时由 PlayerService 换流；触摸放行给 Swiper
      XComponent({ id: 'feedplayer', type: 'surface', controller: this.xcController })
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.Transparent)
        .onLoad(() => {
          this.surfaceId = this.xcController.getXComponentSurfaceId();
          if (this.cards.length > 0) {
            this.activate(this.activeIndex);
          }
        })

      // 封面遮罩：出画面后隐藏
      if (this.coverVisible) {
        Image(this.coverOf())
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .hitTestBehavior(HitTestMode.Transparent)
      }

      // 顶部：静音 + 搜索（与原 Android 端 Home.tsx 一致：右上角两枚圆钮）
      Row() {
        Blank()
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
      .width('100%')
      .padding({ left: 16, right: 16, top: 10 })
      .hitTestBehavior(HitTestMode.Transparent)

      // 右侧纵向操作栏（头像+关注 / 点赞 / 评论 / 收藏 / 下载 / 选集 / 分享）
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

        // 点赞
        Column({ space: 3 }) {
          Image(this.liked ? $r('app.media.ic_heart_f') : $r('app.media.ic_heart'))
            .width(27)
            .height(27)
            .onClick(() => {
              this.toggleLike();
            })
          Text(fmtCount(this.likeCount()))
            .fontSize(10.5)
            .fontColor('#ffffff')
            .shadow({ radius: 3, color: 'rgba(0,0,0,0.7)', offsetX: 0, offsetY: 1 })
        }
        .alignItems(HorizontalAlign.Center)

        // 评论
        Column({ space: 3 }) {
          Image($r('app.media.ic_comment_f'))
            .width(26)
            .height(26)
            .onClick(() => {
              promptAction.showToast({ message: '评论面板在阶段 4 接入' });
            })
          Text(fmtCount(this.commentCount()))
            .fontSize(10.5)
            .fontColor('#ffffff')
            .shadow({ radius: 3, color: 'rgba(0,0,0,0.7)', offsetX: 0, offsetY: 1 })
        }
        .alignItems(HorizontalAlign.Center)

        // 收藏
        Column({ space: 3 }) {
          Image(this.faved ? $r('app.media.ic_star_f') : $r('app.media.ic_star'))
            .width(26)
            .height(26)
            .onClick(() => {
              this.toggleFav();
            })
          Text(fmtCount(this.collectCount()))
            .fontSize(10.5)
            .fontColor('#ffffff')
            .shadow({ radius: 3, color: 'rgba(0,0,0,0.7)', offsetX: 0, offsetY: 1 })
        }
        .alignItems(HorizontalAlign.Center)

        // 下载
        Column({ space: 3 }) {
          Image($r('app.media.ic_download'))
            .width(26)
            .height(26)
            .onClick(() => {
              promptAction.showToast({ message: '下载引擎在阶段 6 接入' });
            })
          Text('下载')
            .fontSize(10.5)
            .fontColor('#ffffff')
            .shadow({ radius: 3, color: 'rgba(0,0,0,0.7)', offsetX: 0, offsetY: 1 })
        }
        .alignItems(HorizontalAlign.Center)

        // 选集
        Column({ space: 3 }) {
          Image($r('app.media.ic_list'))
            .width(25)
            .height(25)
            .onClick(() => {
              promptAction.showToast({ message: '选集面板在阶段 4 接入' });
            })
          Text('选集')
            .fontSize(10.5)
            .fontColor('#ffffff')
            .shadow({ radius: 3, color: 'rgba(0,0,0,0.7)', offsetX: 0, offsetY: 1 })
        }
        .alignItems(HorizontalAlign.Center)

        // 分享
        Column({ space: 3 }) {
          Image($r('app.media.ic_link'))
            .width(25)
            .height(25)
            .onClick(() => {
              promptAction.showToast({ message: '分享功能在阶段 4 接入' });
            })
          Text('分享')
            .fontSize(10.5)
            .fontColor('#ffffff')
            .shadow({ radius: 3, color: 'rgba(0,0,0,0.7)', offsetX: 0, offsetY: 1 })
        }
        .alignItems(HorizontalAlign.Center)
      }
      .alignItems(HorizontalAlign.Center)
      .position({ x: '100%', y: '100%' })
      .markAnchor({ x: '100%', y: '100%' })
      .padding({ right: 14, bottom: 150 })

      // 左下信息层
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
      .width('100%')
      .padding({ left: 14, right: 76, bottom: 44 })
      .position({ y: '100%' })
      .markAnchor({ y: '100%' })
      .hitTestBehavior(HitTestMode.Transparent)

      // 底部进度条（抖音式：平时细条，拖动变粗 + 时间气泡）
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
      .padding({ left: 0, right: 0, bottom: 6, top: 10 })
      .position({ y: '100%' })
      .markAnchor({ y: '100%' })
      .onAreaChange((oldArea: Area, newArea: Area) => {
        const w: number = newArea.width as number;
        this.barWidth = w > 0 ? w : 1;
      })
      .gesture(PanGesture({ direction: PanDirection.Horizontal, fingers: 1, distance: 5 })
        .onActionStart((e: GestureEvent) => {
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

      // 播放状态提示（非覆盖：显示在信息层上方）
      if (this.playStateMsg !== '') {
        Text(this.playStateMsg)
          .fontSize(12)
          .fontColor('#ffcccc')
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
  }
}
