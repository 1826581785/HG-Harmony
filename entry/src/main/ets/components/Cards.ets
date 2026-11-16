/**
 * 共享卡片组件：瀑布流卡 / 横滑卡 / 榜单行 / 帖子卡 / 空态。
 * 对应旧工程 components/cards.tsx + ui.tsx 的 Empty。
 */
import { VideoCard, RankItem, Post } from '../model';
import { coverUrl } from '../api';
import { fmtCount } from '../store';

@Component
export struct WaterfallCard {
  v: VideoCard = new VideoCard();
  onOpen: () => void = () => {
  };

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Image(coverUrl(this.v.cover))
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
        .draggable(false)
      // 底部渐变遮罩 + 信息
      Column() {
        Text(this.v.title)
          .fontSize(11.5)
          .fontWeight(FontWeight.Medium)
          .fontColor('#ffffff')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Row() {
          Text(this.v.authorName === '' ? '黄果短剧' : this.v.authorName)
            .fontSize(9.5)
            .fontColor('rgba(255,255,255,0.65)')
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Image($r('app.media.ic_heart_f'))
            .width(10)
            .height(10)
            .opacity(0.7)
          Text(fmtCount(this.v.likeCount))
            .fontSize(9.5)
            .fontColor('rgba(255,255,255,0.75)')
            .margin({ left: 2 })
        }
        .width('100%')
        .margin({ top: 4 })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding(8)

      // 左上角：完结/更新角标
      Text(this.v.isFinished ? '已完结' : `更新至${this.v.episodeCount}集`)
        .fontSize(9)
        .fontWeight(FontWeight.Bold)
        .fontColor('#ffffff')
        .padding({ left: 5, right: 5, top: 1.5, bottom: 1.5 })
        .backgroundColor('#ff4d6a')
        .borderRadius(5)
        .position({ x: 6, y: 6 })
      // 右上角：热度
      Row({ space: 2 }) {
        Image($r('app.media.ic_play_f'))
          .width(9)
          .height(9)
        Text(fmtCount(this.v.hot))
          .fontSize(9)
          .fontWeight(FontWeight.Medium)
          .fontColor('rgba(255,255,255,0.9)')
      }
      .padding({ left: 5, right: 5, top: 1.5, bottom: 1.5 })
      .backgroundColor('rgba(0,0,0,0.45)')
      .borderRadius(5)
      .position({ x: '100%', y: 6 })
      .markAnchor({ x: '100%', y: 0 })
      .translate({ x: -6 })
    }
    .width('100%')
    .aspectRatio(0.76)
    .clip(true)
    .borderRadius(10)
    .backgroundColor('#161a23')
    .onClick(() => {
      this.onOpen();
    })
  }
}

/** 近无缝双列瀑布流容器（items 用 @Prop：父组件数据变化时子组件同步刷新，排序/追加才生效） */
@Component
export struct Masonry {
  @Prop items: VideoCard[] = [];
  onOpen: (v: VideoCard) => void = () => {
  };
  /** 触底回调（可选，频道页无限滚动用） */
  onLoadMore: () => void = () => {
  };
  hasLoadMore: boolean = false;

  build() {
    WaterFlow() {
      ForEach(this.items, (v: VideoCard) => {
        FlowItem() {
          WaterfallCard({ v: v, onOpen: () => {
            this.onOpen(v);
          } })
        }
      }, (v: VideoCard) => `${v.id}`)
    }
    .columnsTemplate('1fr 1fr')
    .columnsGap(4)
    .rowsGap(4)
    .width('100%')
    .onReachEnd(() => {
      if (this.hasLoadMore) {
        this.onLoadMore();
      }
    })
  }
}

@Component
export struct RowCard {
  v: VideoCard = new VideoCard();
  onOpen: () => void = () => {
  };

  build() {
    Column({ space: 6 }) {
      Stack({ alignContent: Alignment.Bottom }) {
        Image(coverUrl(this.v.cover))
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .draggable(false)
        Column()
          .width('100%')
          .height('50%')
          .linearGradient({ angle: 180, colors: [['rgba(0,0,0,0)', 0], ['rgba(0,0,0,0.75)', 1]] })
        Text(this.v.isFinished ? '完结' : `${this.v.episodeCount}集`)
          .fontSize(8.5)
          .fontWeight(FontWeight.Bold)
          .fontColor('#ffffff')
          .padding({ left: 5, right: 5, top: 1.5, bottom: 1.5 })
          .backgroundColor('#ff4d6a')
          .borderRadius(5)
          .position({ x: 6, y: 6 })
        Row({ space: 2 }) {
          Image($r('app.media.ic_play_f'))
            .width(9)
            .height(9)
          Text(fmtCount(this.v.hot))
            .fontSize(9)
            .fontWeight(FontWeight.Medium)
            .fontColor('rgba(255,255,255,0.9)')
            .shadow({ radius: 3, color: 'rgba(0,0,0,0.7)', offsetX: 0, offsetY: 1 })
        }
        .position({ x: '100%', y: '100%' })
        .markAnchor({ x: '100%', y: '100%' })
        .translate({ x: -6, y: -6 })
      }
      .width('100%')
      .aspectRatio(0.752)
      .clip(true)
      .borderRadius(10)
      .backgroundColor('#161a23')

      Text(this.v.title)
        .fontSize(11.5)
        .fontWeight(FontWeight.Medium)
        .fontColor('#e8eaf0')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      Text(this.v.tags.slice(0, 2).join(' · '))
        .fontSize(10)
        .fontColor('#8a93a6')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
    }
    .width(104)
    .onClick(() => {
      this.onOpen();
    })
  }
}

@Component
export struct RankRow {
  item: RankItem = new RankItem();
  metricMax: number = 1;
  onOpen: () => void = () => {
  };

  build() {
    Row({ space: 12 }) {
      // 名次（前三高亮）
      Text(`${this.item.rank}`)
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.item.rank === 1 ? '#ffffff' : (this.item.rank <= 3 ? '#ff4d6a' : '#5c6678'))
        .width(28)
        .height(28)
        .textAlign(TextAlign.Center)
        .backgroundColor(this.item.rank === 1 ? '#ff4d6a' : 'transparent')
        .borderRadius(14)

      Image(coverUrl(this.item.cover))
        .width(52)
        .height(68)
        .objectFit(ImageFit.Cover)
        .borderRadius(10)
        .backgroundColor('#1d222e')
        .draggable(false)

      Column({ space: 6 }) {
        Text(this.item.title)
          .fontSize(12.5)
          .fontWeight(FontWeight.Medium)
          .fontColor('#e8eaf0')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Row({ space: 8 }) {
          Text(this.item.tags.slice(0, 2).join(' · '))
            .fontSize(10)
            .fontColor('#5c6678')
            .layoutWeight(1)
            .maxLines(1)
          Text(`${this.item.metricLabel} ${fmtCount(this.item.metricValue)}`)
            .fontSize(10)
            .fontWeight(FontWeight.Bold)
            .fontColor('#ff4d6a')
        }
        .width('100%')
        // 指标条
        Stack({ alignContent: Alignment.Start }) {
          Row()
            .width('100%')
            .height(3)
            .backgroundColor('#262a33')
            .borderRadius(2)
          Row()
            .width(`${Math.max(6, Math.round(this.item.metricValue / Math.max(1, this.metricMax) * 100))}%`)
            .height(3)
            .backgroundColor('#ff4d6a')
            .borderRadius(2)
        }
        .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding(10)
    .backgroundColor(this.item.rank <= 3 ? '#1d222e' : '#141821')
    .borderRadius(12)
    .margin({ bottom: 8 })
    .onClick(() => {
      this.onOpen();
    })
  }
}

@Component
export struct PostCard {
  p: Post = new Post();
  /** 卡片宽（列表页双列瀑布 / 频道页横滑 104） */
  wide: boolean = false;
  onOpen: () => void = () => {
  };

  build() {
    Column({ space: 6 }) {
      Stack({ alignContent: Alignment.Bottom }) {
        Image(coverUrl(this.p.cover))
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .draggable(false)
        Column()
          .width('100%')
          .height(this.wide ? '66%' : '50%')
          .linearGradient({ angle: 180, colors: [['rgba(0,0,0,0)', 0], ['rgba(0,0,0,0.85)', 1]] })
        Column({ space: 4 }) {
          Text(this.p.title)
            .fontSize(this.wide ? 11.5 : 11.5)
            .fontWeight(FontWeight.Medium)
            .fontColor('#ffffff')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .shadow({ radius: 3, color: 'rgba(0,0,0,0.7)', offsetX: 0, offsetY: 1 })
          Row({ space: 3 }) {
            Image($r('app.media.ic_fire_f'))
              .width(10)
              .height(10)
              .opacity(0.8)
            Text(fmtCount(this.p.hot))
              .fontSize(9.5)
              .fontColor('rgba(255,255,255,0.75)')
          }
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding(8)
      }
      .width('100%')
      .aspectRatio(this.wide ? 0.78 : 0.752)
      .clip(true)
      .borderRadius(10)
      .backgroundColor('#161a23')
    }
    .width('100%')
    .onClick(() => {
      this.onOpen();
    })
  }
}

@Component
export struct EmptyState {
  @Prop icon: string = 'search';
  title: string = '';
  sub: string = '';
  action: string = '';
  onAction: () => void = () => {
  };

  build() {
    Column({ space: 8 }) {
      Image(this.icon === 'clock' ? $r('app.media.ic_clock') :
        (this.icon === 'star' ? $r('app.media.ic_star') : $r('app.media.ic_search')))
        .width(26)
        .height(26)
        .opacity(0.5)
      Text(this.title)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor('#8fa3c0')
      if (this.sub !== '') {
        Text(this.sub)
          .fontSize(11)
          .fontColor('#5c6678')
          .textAlign(TextAlign.Center)
      }
      if (this.action !== '') {
        Text(this.action)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor('#ff4d6a')
          .padding({ left: 18, right: 18, top: 7, bottom: 7 })
          .backgroundColor('rgba(255,77,106,0.12)')
          .borderRadius(16)
          .margin({ top: 6 })
          .onClick(() => {
            this.onAction();
          })
      }
    }
    .width('100%')
    .padding({ top: 48, bottom: 32 })
  }
}
