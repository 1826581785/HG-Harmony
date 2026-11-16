/**
 * 首页信息流：竖向 Swiper + 每页内嵌 XComponent（单 AVPlayer 切流）。
 * 对应旧工程 Home.tsx + Feed.tsx。
 * 交互：抖音式底部进度条；右侧操作栏；沉浸全屏（横屏视频可旋转 90°）。
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
  @State playingIds: number[] = [];
  @State paused: boolean = false;
  @State playStateMsg: string = '';
  /** 沉浸全屏：放 AppStorage，Main 的 onBackPress 能读到（返回键优先退全屏） */
  @StorageLink('feedFs') @Watch('onFsChange') fs: boolean = false;
  @State rotated: boolean = false;
  @State videoW: number = 0;
  @State videoH: number = 0;
  @State scrW: number = 0;
  @State scrH: number = 0;
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

  aboutToAppear(): void {
    this.muted = store.muted;
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
    };
    playerService.onPaused = () => {
      this.paused = true;
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

  private onFsChange(): void {
    if (!this.fs) {
      this.rotated = false;
    }
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
    this.paused = false;
    this.playStateMsg = '';
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
        }).catch(() => {
        });
      } else if (di === index) {
        this.curDetail = this.detailCache.get(cid) ?? null;
      }
    }
    // 播放地址
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
    if (gen !== this.loadGen) {
      return;
    }
    this.errMsg = '';
    const sid = this.surfaces.get(card.id) ?? '';
    if (sid === '') {
      return; // surface 尚未 onLoad，onPageLoad 会再触发 activate
    }
    playerService.setMuted(this.muted);
    playerService.attach(url, sid);
    store.addHistory(card.id);
    if (index >= this.cards.length - 3) {
      this.loadPage(this.page + 1);
    }
  }

  /* ── 元信息 ── */

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
    promptAction.showToast({ message: this.liked ? '已加入喜欢' : '已取消喜欢' });
  }

  private async toggleFav(): Promise<void> {
    if (!this.curCard) {
      return;
    }
    this.faved = await store.toggleFav(this.curCard.id);
    promptAction.showToast({ message: this.faved ? '已收藏' : '已取消收藏' });
  }

  private async toggleFollow(): Promise<void> {
    const uid = this.authorId();
    if (uid <= 0) {
      return;
    }
    this.followed = await store.toggleFollow(uid);
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
            if (!this.playingIds.includes(c.id)) {
              Image(coverUrl(c.cover))
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
          .gesture(TapGesture({ count: 1 }).onAction(() => {
            this.togglePlay();
          }))
        }, (c: VideoCard) => `${c.id}`)
      }
      .vertical(true)
      .loop(false)
      .indicator(false)
      .cachedCount(1)
      .disableSwipe(this.fs)
      .width('100%')
      .height('100%')
      .onChange((i: number) => {
        this.activate(i);
      })

      // 顶部：静音 + 搜索（非全屏时）；全屏时：横屏切换（横屏视频）+ 退出
      Row() {
        Blank()
        if (!this.fs && this.rotated) {
          Button() {
            Text('竖屏')
              .fontSize(12)
              .fontColor('#ffffff')
          }
          .height(32)
          .backgroundColor('rgba(0,0,0,0.45)')
          .onClick(() => {
            this.rotated = false;
          })
        }
        if (this.fs && this.videoW > this.videoH) {
          Button() {
            Text('横屏')
              .fontSize(12)
              .fontColor('#ffffff')
          }
          .height(32)
          .backgroundColor('rgba(0,0,0,0.45)')
          .margin({ right: 8 })
          .onClick(() => {
            this.rotated = true;
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
                  promptAction.showToast({ message: '评论面板在阶段 4 接入' });
                })
              Text(fmtCount(this.commentCount()))
                .fontSize(10.5)
                .fontColor('#ffffff')
                .shadow({ radius: 3, color: 'rgba(0,0,0,0.7)', offsetX: 0, offsetY: 1 })
            }
            .alignItems(HorizontalAlign.Center)

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
  }
}
