/**
 * 分类 Tab：4 频道横滑 + 吃瓜横滑 + 排行榜入口；频道详情页（排序 + 无限滚动）。
 * 对应旧工程 pages/Category.tsx。
 */
import { category, posts } from '../api';
import { VideoCard, Post, FeedNavParam, ChannelNavParam } from '../model';
import { RowCard, PostCard, Masonry, EmptyState } from '../components/Cards';

interface Channel {
  cate: string;
  name: string;
  desc: string;
}

const CHANNELS: Channel[] = [
  { 'cate': 'ai-duanju', 'name': 'AI成人短剧', 'desc': '高能反转 · 一口气看完' },
  { 'cate': 'ai-manju', 'name': 'AI成人漫剧', 'desc': '国创漫剧 · 每周更新' },
  { 'cate': 'ai-huanlian', 'name': 'AI换脸', 'desc': '换脸演绎 · 全新剧情' },
  { 'cate': 'ai-mogai', 'name': 'AI魔改', 'desc': '魔改名场面 · 脑洞大开' },
];

@Component
export struct CategoryTab {
  navStack: NavPathStack = new NavPathStack();
  onOpenRanks: () => void = () => {
  };
  onOpenPosts: () => void = () => {
  };
  @State rows: VideoCard[][] = [[], [], [], []];
  @State posts: Post[] = [];
  @State loading: boolean = true;

  aboutToAppear(): void {
    this.init();
  }

  private async init(): Promise<void> {
    const rs: VideoCard[][] = [[], [], [], []];
    const jobs: Promise<void>[] = [];
    for (let i = 0; i < CHANNELS.length; i++) {
      const idx = i;
      const ch = CHANNELS[idx];
      jobs.push(category(ch.cate, 1, 8).then((res) => {
        rs[idx] = res.items;
      }).catch(() => {
      }));
    }
    jobs.push(posts(1, 8).then((res) => {
      this.posts = res.items;
    }).catch(() => {
    }));
    await Promise.all(jobs);
    this.rows = rs;
    this.loading = false;
  }

  @Builder
  sectionHeader(name: string, desc: string, onOpenAll: () => void) {
    Row({ space: 10 }) {
      Stack() {
        Image($r('app.media.ic_grid'))
          .width(19)
          .height(19)
          .fillColor('#ff4d6a')
      }
      .width(36)
      .height(36)
      .backgroundColor('rgba(255,77,106,0.12)')
      .borderRadius(10)

      Column({ space: 2 }) {
        Text(name)
          .fontSize(15.5)
          .fontWeight(FontWeight.Medium)
          .fontColor('#e8eaf0')
        Text(desc)
          .fontSize(10.5)
          .fontColor('#8a93a6')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Row({ space: 2 }) {
        Text('全部')
          .fontSize(11.5)
          .fontColor('#8fa3c0')
        Image($r('app.media.ic_chev_r'))
          .width(13)
          .height(13)
          .fillColor('#8fa3c0')
      }
      .onClick(() => {
        onOpenAll();
      })
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 10 })
  }

  @Builder
  emptyRow() {
    Text(this.loading ? '加载中…' : '暂无内容')
      .fontSize(11.5)
      .fontColor('#5c6678')
      .height(150)
      .padding({ left: 4 })
  }

  build() {
    Column() {
      // 标题
      Row({ space: 10 }) {
        Text('分类')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor('#e8eaf0')
        Text(`${CHANNELS.length + 1} 个频道 · 每周持续上新`)
          .fontSize(11)
          .fontColor('#8fa3c0')
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)
      .padding({ left: 16, right: 16, top: 14, bottom: 6 })

      Scroll() {
        Column() {
          // 排行榜入口
          Row({ space: 12 }) {
            Stack() {
              Image($r('app.media.ic_trophy'))
                .width(20)
                .height(20)
            }
            .width(40)
            .height(40)
            .backgroundColor('#ff4d6a')
            .borderRadius(10)

            Column({ space: 2 }) {
              Text('排行榜')
                .fontSize(14.5)
                .fontWeight(FontWeight.Medium)
                .fontColor('#e8eaf0')
              Text('热播榜 · 推荐榜 · 潜力榜')
                .fontSize(10.5)
                .fontColor('#8a93a6')
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Image($r('app.media.ic_chev_r'))
              .width(16)
              .height(16)
              .fillColor('#8fa3c0')
          }
          .width('100%')
          .padding(14)
          .backgroundColor('#141821')
          .borderRadius(12)
          .margin({ left: 16, right: 16, top: 8, bottom: 20 })
          .onClick(() => {
            this.onOpenRanks();
          })

          // 4 频道
          ForEach(CHANNELS, (ch: Channel, ci: number) => {
            Column() {
              this.sectionHeader(ch.name, ch.desc, () => {
                const param: ChannelNavParam = { 'cate': ch.cate, 'name': ch.name };
                this.navStack.pushPathByName('channel', param);
              })
              Scroll() {
                Row({ space: 10 }) {
                  if (this.rows[ci].length === 0) {
                    this.emptyRow();
                  }
                  ForEach(this.rows[ci], (v: VideoCard) => {
                    RowCard({ v: v, onOpen: () => {
                      const ids = this.rows[ci].map((x: VideoCard) => x.id);
                      const param: FeedNavParam = { 'ids': ids, 'title': ch.name, 'index': this.rows[ci].indexOf(v) };
                      this.navStack.pushPathByName('feedview', param);
                    } })
                  }, (v: VideoCard) => `${v.id}`)
                }
                .padding({ left: 16, right: 16 })
              }
              .scrollable(ScrollDirection.Horizontal)
              .scrollBar(BarState.Off)
              .align(Alignment.Start)
              .width('100%')
            }
            .margin({ bottom: 20 })
          }, (ch: Channel) => ch.cate)

          // 吃瓜
          Column() {
            this.sectionHeader('黄果吃瓜', '圈内爆料 · 每日更新', () => {
              this.onOpenPosts();
            })
            Scroll() {
              Row({ space: 10 }) {
                if (this.posts.length === 0) {
                  this.emptyRow();
                }
                ForEach(this.posts, (p: Post) => {
                  Column() {
                    PostCard({ p: p, onOpen: () => {
                      this.navStack.pushPathByName('post', p.id);
                    } })
                  }
                  .width(104)
                }, (p: Post) => `${p.id}`)
              }
              .padding({ left: 16, right: 16 })
            }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
            .align(Alignment.Start)
            .width('100%')
          }
          .margin({ bottom: 20 })

          Text('— 已展示全部频道 —')
            .fontSize(10.5)
            .fontColor('#5c6678')
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ bottom: 24 })
        }
        .width('100%')
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.TopStart)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0b0e15')
  }
}

/* ── 频道详情页（NavDestination）── */
@Component
export struct ChannelPage {
  navStack: NavPathStack = new NavPathStack();
  @State cate: string = '';
  @State name: string = '';
  @State sort: string = '最新';
  @State items: VideoCard[] = [];
  @State page: number = 0;
  @State pages: number = 1;
  @State loading: boolean = false;
  @State errMsg: string = '';
  private loadGen: number = 0;

  aboutToAppear(): void {
    const arr: Array<Object> = this.navStack.getParamByName('channel') as Array<Object>;
    if (arr && arr.length > 0) {
      const p = arr[arr.length - 1] as Record<string, Object>;
      this.cate = (p['cate'] as string) ?? '';
      this.name = (p['name'] as string) ?? '';
    }
    this.loadMore();
  }

  private async loadMore(): Promise<void> {
    if (this.loading || this.page >= this.pages) {
      return;
    }
    this.loading = true;
    const gen = ++this.loadGen;
    const next = this.page + 1;
    try {
      const res = await category(this.cate, next, 20);
      if (gen !== this.loadGen) {
        return;
      }
      const seen = new Set<number>(this.items.map((x: VideoCard) => x.id));
      this.items = this.items.concat(res.items.filter((x: VideoCard) => !seen.has(x.id)));
      this.page = next;
      this.pages = res.pages > next ? res.pages : next;
      this.errMsg = '';
    } catch (e) {
      if (gen === this.loadGen) {
        this.errMsg = (e as Error).message;
      }
    } finally {
      if (gen === this.loadGen) {
        this.loading = false;
      }
    }
  }

  /** 客户端排序：最新按 id 倒序、最热按热度、高分按评分 */
  private sorted(): VideoCard[] {
    return this.items.slice().sort((a: VideoCard, b: VideoCard) => {
      if (this.sort === '最热') {
        return b.hot - a.hot;
      }
      if (this.sort === '高分') {
        return b.score - a.score;
      }
      return b.id - a.id;
    });
  }

  build() {
    NavDestination() {
      Column() {
        // 头部：返回 + 名称 + 排序
        Column() {
          Row({ space: 10 }) {
            Button() {
              Image($r('app.media.ic_back'))
                .width(19)
                .height(19)
            }
            .type(ButtonType.Circle)
            .width(38)
            .height(38)
            .backgroundColor('rgba(255,255,255,0.08)')
            .onClick(() => {
              this.navStack.pop();
            })

            Stack() {
              Image($r('app.media.ic_grid'))
                .width(20)
                .height(20)
            }
            .width(40)
            .height(40)
            .backgroundColor('#ff4d6a')
            .borderRadius(10)

            Column({ space: 2 }) {
              Text(this.name)
                .fontSize(17)
                .fontWeight(FontWeight.Bold)
                .fontColor('#e8eaf0')
                .maxLines(1)
              Text(`已加载 ${this.page}/${Math.max(this.pages, 1)} 页`)
                .fontSize(10.5)
                .fontColor('#8a93a6')
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
          }
          .width('100%')

          Row({ space: 8 }) {
            ForEach(['最新', '最热', '高分'], (s: string) => {
              Text(s)
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.sort === s ? '#ff4d6a' : '#8fa3c0')
                .backgroundColor(this.sort === s ? 'rgba(255,77,106,0.12)' : '#1d222e')
                .textAlign(TextAlign.Center)
                .padding({ left: 16, right: 16, top: 6, bottom: 6 })
                .borderRadius(14)
                .onClick(() => {
                  this.sort = s;
                })
            }, (s: string) => s)
          }
          .width('100%')
          .margin({ top: 12 })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 14 })

        if (this.items.length > 0) {
          Masonry({ items: this.sorted(), hasLoadMore: true, onLoadMore: () => {
            this.loadMore();
          }, onOpen: (v: VideoCard) => {
            const list = this.sorted();
            const ids = list.map((x: VideoCard) => x.id);
            // @Prop 是拷贝件，按 id 找下标
            let idx = 0;
            for (let i = 0; i < list.length; i++) {
              if (list[i].id === v.id) {
                idx = i;
                break;
              }
            }
            const param: FeedNavParam = { 'ids': ids, 'title': this.name, 'index': idx };
            this.navStack.pushPathByName('feedview', param);
          } })
            .layoutWeight(1)
            .padding({ left: 12, right: 12, bottom: 16 })
        } else if (this.errMsg !== '' && this.items.length === 0 && !this.loading) {
          Column() {
            EmptyState({ title: '加载失败', sub: this.errMsg, action: '重试', onAction: () => {
              this.loadMore();
            } })
          }
          .layoutWeight(1)
        } else {
          Column() {
            LoadingProgress()
              .width(32)
              .height(32)
              .color('#e8eaf0')
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        }

        if (this.loading && this.items.length > 0) {
          Row() {
            LoadingProgress()
              .width(22)
              .height(22)
              .color('#e8eaf0')
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .padding({ top: 8, bottom: 8 })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#0b0e15')
    }
    .hideTitleBar(true)
    .backgroundColor('#0b0e15')
  }
}
