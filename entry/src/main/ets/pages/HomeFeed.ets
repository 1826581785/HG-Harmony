/**
 * 首页信息流：竖向 Swiper + 单 XComponent/单 AVPlayer 切流。
 * 对应旧工程 Home.tsx + Feed.tsx 的信息流部分。
 * 阶段 3 范围：分页加载、预取、播放地址缓存、观看历史、静音、右下信息层。
 */
import { VideoCard, VideoDetail } from '../model';
import { feed, videoDetail, playUrl, coverUrl, ensureMedia } from '../api';
import { store } from '../store';
import { playerService } from '../player/PlayerService';

@Component
export struct HomeFeed {
  navStack: NavPathStack = new NavPathStack();
  @State cards: VideoCard[] = [];
  @State activeIndex: number = 0;
  @State loading: boolean = false;
  @State done: boolean = false;
  @State errMsg: string = '';
  /** 视频元信息缓存（当前卡片的标题/作者/集数） */
  @State curDetail: VideoDetail | null = null;
  @State curCard: VideoCard | null = null;
  @State muted: boolean = true;
  @State ready: boolean = false;
  private surfaceId: string = '';
  private xcController: XComponentController = new XComponentController();
  private detailCache: Map<number, VideoDetail> = new Map();
  private urlCache: Map<string, string> = new Map();
  private page: number = 0;
  private pages: number = 1;
  private loadingMore: boolean = false;
  private loadGen: number = 0;

  aboutToAppear(): void {
    this.muted = store.muted;
    this.initFeed();
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

  private coverOf(c: VideoCard | null, d: VideoDetail | null): string {
    const raw = (d && d.cover !== '') ? d.cover : (c ? c.cover : '');
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

  build() {
    Stack() {
      // 卡片轮播（每页显示封面 + 底部信息）
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

      // 单一视频表面：叠在整个 Swiper 之上，切页时由 PlayerService 换流
      XComponent({ id: 'feedplayer', type: 'surface', controller: this.xcController })
        .width('100%')
        .height('100%')
        .onLoad(() => {
          this.surfaceId = this.xcController.getXComponentSurfaceId();
          if (this.cards.length > 0) {
            this.activate(this.activeIndex);
          }
        })

      // 底部信息层文字带阴影保证可读（渐变遮罩阶段 4 再补）

      // 顶部：静音 + 搜索
      Row() {
        Blank()
        Button(this.muted ? '🔇' : '🔊')
          .width(36)
          .height(36)
          .fontSize(16)
          .backgroundColor('rgba(0,0,0,0.45)')
          .onClick(() => {
            this.muted = !this.muted;
            store.setMuted(this.muted);
            playerService.setMuted(this.muted);
          })
        Button('🔍')
          .width(36)
          .height(36)
          .fontSize(15)
          .margin({ left: 8 })
          .backgroundColor('rgba(0,0,0,0.45)')
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10 })
      .hitTestBehavior(HitTestMode.Transparent)

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
      .padding({ left: 14, right: 76, bottom: 64 })
      .position({ y: '100%' })
      .markAnchor({ y: '100%' })
      .hitTestBehavior(HitTestMode.Transparent)

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
