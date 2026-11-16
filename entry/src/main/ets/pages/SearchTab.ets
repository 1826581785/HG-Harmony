/**
 * 搜索 Tab：搜索栏 + 历史/热门题材 + 瀑布流结果 + 加载更多。
 * 对应旧工程 pages/Search.tsx 的主体部分。
 */
import { search } from '../api';
import { VideoCard, FeedNavParam } from '../model';
import { LengthMetrics } from '@kit.ArkUI';
import { store } from '../store';
import { Masonry, EmptyState } from '../components/Cards';

const HOT_TAGS: string[] = ['都市', '逆袭', '古风', '系统', '后宫', '校园', '仙侠', '职场', '大男主', '御姐', '脑洞', '奇幻'];

@Component
export struct SearchTab {
  navStack: NavPathStack = new NavPathStack();
  onOpenRanks: () => void = () => {
  };
  @State q: string = '';
  @State submitted: string = '';
  @State items: VideoCard[] = [];
  @State hist: string[] = [];
  @State page: number = 0;
  @State pages: number = 1;
  @State loading: boolean = false;
  @State err: string = '';
  private loadGen: number = 0;

  aboutToAppear(): void {
    this.hist = store.searchHist;
  }

  private async run(keyword: string, p: number): Promise<void> {
    if (p > 1 && (p > this.pages || this.loading)) {
      return;
    }
    if (p === 1) {
      this.items = [];
      this.pages = 1;
    }
    const gen = ++this.loadGen;
    this.loading = true;
    this.err = '';
    try {
      const res = await search(keyword, p, 20);
      if (gen !== this.loadGen) {
        return;
      }
      const base = p === 1 ? [] : this.items;
      const seen = new Set<number>(base.map((x: VideoCard) => x.id));
      this.items = base.concat(res.items.filter((x: VideoCard) => !seen.has(x.id)));
      this.page = p;
      this.pages = res.pages;
    } catch (e) {
      if (gen === this.loadGen) {
        this.err = (e as Error).message;
      }
    } finally {
      if (gen === this.loadGen) {
        this.loading = false;
      }
    }
  }

  private submit(keyword: string): void {
    const k = keyword.trim();
    if (k === '') {
      return;
    }
    this.q = k;
    this.submitted = k;
    store.addSearch(k).then(() => {
      this.hist = store.searchHist;
    });
    this.run(k, 1);
  }

  private clearInput(): void {
    this.q = '';
    this.submitted = '';
    this.items = [];
    this.page = 0;
    this.err = '';
  }

  /** 换一批：随机热门题材 */
  private rollTag(): void {
    const t = HOT_TAGS[Math.floor(Math.random() * HOT_TAGS.length)];
    this.submit(t);
  }

  @Builder
  idleBody() {
    Column() {
      if (this.hist.length > 0) {
        Column() {
          Row() {
            Text('搜索历史')
              .fontSize(13)
              .fontWeight(FontWeight.Bold)
              .fontColor('#e8eaf0')
            Blank()
            Text('清空')
              .fontSize(11)
              .fontColor('#8fa3c0')
              .onClick(() => {
                store.clearSearchHist().then(() => {
                  this.hist = [];
                });
              })
          }
          .width('100%')

          Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Start, space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(8) } }) {
            ForEach(this.hist, (h: string) => {
              Text(h)
                .fontSize(12)
                .fontColor('rgba(232,234,240,0.8)')
                .padding({ left: 14, right: 14, top: 6, bottom: 6 })
                .backgroundColor('#1d222e')
                .borderRadius(16)
                .onClick(() => {
                  this.submit(h);
                })
            }, (h: string) => h)
          }
          .width('100%')
          .margin({ top: 10 })
        }
        .width('100%')
      }

      Column() {
        Row() {
          Row({ space: 6 }) {
            Image($r('app.media.ic_fire_f'))
              .width(15)
              .height(15)
              .fillColor('#ff4d6a')
            Text('热门题材')
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor('rgba(232,234,240,0.9)')
          }
          Blank()
          Text('完整榜单 ›')
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor('#ff4d6a')
            .onClick(() => {
              this.onOpenRanks();
            })
        }
        .width('100%')

        Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Start, space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(8) } }) {
          ForEach(HOT_TAGS, (t: string) => {
            Text(t)
              .fontSize(12)
              .fontColor('rgba(232,234,240,0.85)')
              .padding({ left: 12, right: 12, top: 5, bottom: 5 })
              .backgroundColor('#1d222e')
              .borderRadius(14)
              .onClick(() => {
                this.submit(t);
              })
          }, (t: string) => t)
        }
        .width('100%')
        .margin({ top: 12 })
      }
      .width('100%')
      .padding(14)
      .backgroundColor('#141821')
      .borderRadius(12)
      .margin({ top: 20 })

      Row() {
        Text('为你推荐')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor('#e8eaf0')
        Blank()
        Row({ space: 4 }) {
          Image($r('app.media.ic_refresh'))
            .width(13)
            .height(13)
            .fillColor('#8fa3c0')
          Text('换一批')
            .fontSize(11.5)
            .fontColor('#8fa3c0')
        }
        .onClick(() => {
          this.rollTag();
        })
      }
      .width('100%')
      .margin({ top: 24, bottom: 10 })

      Text('输入关键词后按回车搜索，也可以点上面的题材直接看片单。')
        .fontSize(11.5)
        .fontColor('#5c6678')
        .lineHeight(18)
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
  }

  @Builder
  resultBody() {
    Column() {
      Text(`「${this.submitted}」共 ${this.items.length} 条结果`)
        .fontSize(11.5)
        .fontColor('#8fa3c0')
        .width('100%')
        .margin({ top: 4, bottom: 8 })

      if (this.items.length > 0) {
        Masonry({ items: this.items, onOpen: (v: VideoCard) => {
          const ids = this.items.map((x: VideoCard) => x.id);
          // @Prop 是拷贝件，按 id 找下标
          let idx = 0;
          for (let i = 0; i < this.items.length; i++) {
            if (this.items[i].id === v.id) {
              idx = i;
              break;
            }
          }
          const param: FeedNavParam = { 'ids': ids, 'title': `搜索 · ${this.submitted}`, 'index': idx };
          this.navStack.pushPathByName('feedview', param);
        } })
      } else if (this.loading) {
        Column() {
          LoadingProgress()
            .width(32)
            .height(32)
            .color('#e8eaf0')
        }
        .width('100%')
        .padding({ top: 48 })
      } else {
        EmptyState({ title: this.err !== '' ? this.err : '没有找到相关内容', sub: '换个关键词试试，比如「都市」「逆袭」', action: '看看热榜', onAction: () => {
          this.onOpenRanks();
        } })
      }

      Row() {
        if (this.items.length > 0) {
          if (this.loading) {
            LoadingProgress()
              .width(24)
              .height(24)
              .color('#e8eaf0')
          } else if (this.page < this.pages) {
            Text('加载更多')
              .fontSize(12)
              .fontColor('rgba(232,234,240,0.85)')
              .padding({ left: 20, right: 20, top: 8, bottom: 8 })
              .backgroundColor('#1d222e')
              .borderRadius(16)
              .onClick(() => {
                this.run(this.submitted, this.page + 1);
              })
          } else {
            Text('— 已经到底啦 —')
              .fontSize(10.5)
              .fontColor('#5c6678')
          }
        }
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .padding({ top: 16, bottom: 16 })
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
  }

  build() {
    Column() {
      // 搜索栏 + 排行榜入口
      Row({ space: 10 }) {
        Row({ space: 8 }) {
          Image($r('app.media.ic_search'))
            .width(16)
            .height(16)
            .fillColor('#8fa3c0')
          TextInput({ text: this.q, placeholder: '搜索短剧、作者、题材…' })
            .layoutWeight(1)
            .height(40)
            .fontSize(13.5)
            .fontColor('#e8eaf0')
            .placeholderColor('#5c6678')
            .backgroundColor(Color.Transparent)
            .border({ width: 0 })
            .padding(0)
            .onChange((v: string) => {
              this.q = v;
            })
            .onSubmit(() => {
              this.submit(this.q);
            })
          if (this.q !== '') {
            Stack() {
              Circle({ width: 18, height: 18 })
                .fill('#2a3040')
              Image($r('app.media.ic_close'))
                .width(9)
                .height(9)
                .fillColor('#8fa3c0')
            }
            .onClick(() => {
              this.clearInput();
            })
          }
        }
        .layoutWeight(1)
        .height(44)
        .padding({ left: 14, right: 14 })
        .backgroundColor('#1d222e')
        .borderRadius(12)
        .alignItems(VerticalAlign.Center)

        Button() {
          Image($r('app.media.ic_trophy'))
            .width(19)
            .height(19)
        }
        .type(ButtonType.Normal)
        .width(44)
        .height(44)
        .borderRadius(12)
        .backgroundColor('#ff4d6a')
        .onClick(() => {
          this.onOpenRanks();
        })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })

      Scroll() {
        if (this.submitted === '') {
          this.idleBody();
        } else {
          this.resultBody();
        }
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
