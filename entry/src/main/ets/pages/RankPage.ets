/**
 * 排行榜页（NavDestination）：热播/推荐/潜力 3 子 Tab + 指标条行。
 * 对应旧工程 pages/Search.tsx 的 RankPage。
 */
import { rank } from '../api';
import { RankItem, FeedNavParam } from '../model';
import { RankRow, EmptyState } from '../components/Cards';

const RANK_TABS: string[][] = [
  ['hot', '热播榜', '按热力指数排序'],
  ['recommend', '推荐榜', '按推荐值排序'],
  ['potential', '潜力榜', '按潜力值排序'],
];

@Component
export struct RankPage {
  navStack: NavPathStack = new NavPathStack();
  @State tab: string = 'hot';
  @State items: RankItem[] = [];
  @State loading: boolean = true;
  @State errMsg: string = '';
  private loadGen: number = 0;

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    const gen = ++this.loadGen;
    const kind = this.tab;
    this.loading = true;
    this.errMsg = '';
    try {
      const res = await rank(kind);
      if (gen !== this.loadGen) {
        return;
      }
      this.items = res;
    } catch (e) {
      if (gen === this.loadGen) {
        this.items = [];
        this.errMsg = (e as Error).message;
      }
    } finally {
      if (gen === this.loadGen) {
        this.loading = false;
      }
    }
  }

  private metricMax(): number {
    let m = 1;
    for (const it of this.items) {
      if (it.metricValue > m) {
        m = it.metricValue;
      }
    }
    return m;
  }

  private openRank(item: RankItem): void {
    const ids = this.items.map((x: RankItem) => x.videoId);
    const param: FeedNavParam = { 'ids': ids, 'title': 'HG 热榜', 'index': this.items.indexOf(item) };
    this.navStack.pushPathByName('feedview', param);
  }

  build() {
    NavDestination() {
      Column() {
        // 头部
        Column() {
          Row({ space: 8 }) {
            Stack() {
              Text('🏆')
                .fontSize(18)
            }
            .width(36)
            .height(36)
            .backgroundColor('#ff4d6a')
            .borderRadius(10)

            Column({ space: 2 }) {
              Text('HG 热榜')
                .fontSize(22)
                .fontWeight(FontWeight.Bold)
                .fontColor('#e8eaf0')
              Text(`${(RANK_TABS.find((t: string[]) => t[0] === this.tab) ?? RANK_TABS[0])[2]} · 每 10 分钟更新`)
                .fontSize(11)
                .fontColor('#8fa3c0')
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
          }
          .width('100%')

          Row({ space: 4 }) {
            ForEach(RANK_TABS, (t: string[]) => {
              Text(t[1])
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.tab === t[0] ? '#ffffff' : '#8fa3c0')
                .backgroundColor(this.tab === t[0] ? '#ff4d6a' : '#1d222e')
                .textAlign(TextAlign.Center)
                .height(32)
                .borderRadius(12)
                .layoutWeight(1)
                .onClick(() => {
                  if (this.tab !== t[0]) {
                    this.tab = t[0];
                    this.load();
                  }
                })
            }, (t: string[]) => t[0])
          }
          .width('100%')
          .padding(4)
          .backgroundColor('#141821')
          .borderRadius(14)
          .margin({ top: 12 })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 14, bottom: 14 })

        if (this.loading) {
          Column() {
            LoadingProgress()
              .width(32)
              .height(32)
              .color('#e8eaf0')
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else if (this.items.length > 0) {
          Scroll() {
            Column() {
              ForEach(this.items, (it: RankItem) => {
                RankRow({ item: it, metricMax: this.metricMax(), onOpen: () => {
                  this.openRank(it);
                } })
              }, (it: RankItem) => `${it.videoId}-${it.rank}-${this.tab}`)
            }
            .width('100%')
            .padding({ left: 14, right: 14, top: 4, bottom: 24 })
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
        } else {
          Column() {
            EmptyState({ title: this.errMsg !== '' ? this.errMsg : '榜单暂时为空', sub: '稍后再来看看，或者去首页刷刷推荐' })
          }
          .layoutWeight(1)
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
