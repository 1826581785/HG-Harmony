/**
 * 吃瓜：帖子列表（双列瀑布 + 无限滚动）与帖子详情（封面视频 + 正文）。
 * 对应旧工程 pages/Posts.tsx；正文 HTML 降级为清洗后的纯文本渲染。
 */
import { postDetail, posts, coverUrl, proxyUrl, ensureMedia } from '../api';
import { Post, PostDetailData } from '../model';
import { PostCard, EmptyState } from '../components/Cards';
import { playerService } from '../player/PlayerService';
import { promptAction, LengthMetrics } from '@kit.ArkUI';

/* ── HTML 降级清洗：块级标签换行，剥掉其余标签与样式，反转义常用实体 ── */
function htmlToText(html: string): string {
  let s = html;
  s = s.replace(/<style[\s\S]*?<\/style>/gi, '');
  s = s.replace(/<script[\s\S]*?<\/script>/gi, '');
  s = s.replace(/<br\s*\/?>/gi, '\n');
  s = s.replace(/<\/(p|div|h[1-6]|li|tr|blockquote|section)>/gi, '\n');
  s = s.replace(/<li[^>]*>/gi, '· ');
  s = s.replace(/<img[^>]*>/gi, '');
  s = s.replace(/<[^>]+>/g, '');
  s = s.replace(/&nbsp;/g, ' ');
  s = s.replace(/&amp;/g, '&');
  s = s.replace(/&lt;/g, '<');
  s = s.replace(/&gt;/g, '>');
  s = s.replace(/&quot;/g, '"');
  s = s.replace(/&#39;/g, "'");
  s = s.replace(/\n{3,}/g, '\n\n');
  return s.trim();
}

/* ── 帖子列表（NavDestination） ── */
@Component
export struct PostsPage {
  navStack: NavPathStack = new NavPathStack();
  @State items: Post[] = [];
  @State page: number = 0;
  @State pages: number = 1;
  @State loading: boolean = false;
  private loadGen: number = 0;

  aboutToAppear(): void {
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
      const res = await posts(next, 20);
      if (gen !== this.loadGen) {
        return;
      }
      const seen = new Set<number>(this.items.map((x: Post) => x.id));
      this.items = this.items.concat(res.items.filter((x: Post) => !seen.has(x.id)));
      this.page = next;
      this.pages = res.pages > next ? res.pages : next;
    } catch (e) {
      // 静默：列表加载失败不打扰
    } finally {
      if (gen === this.loadGen) {
        this.loading = false;
      }
    }
  }

  build() {
    NavDestination() {
      Column() {
        Row({ space: 8 }) {
          Button() {
            Image($r('app.media.ic_back'))
              .width(19)
              .height(19)
          }
          .type(ButtonType.Circle)
          .width(36)
          .height(36)
          .backgroundColor('rgba(255,255,255,0.08)')
          .onClick(() => {
            this.navStack.pop();
          })
          Text('黄果吃瓜')
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor('#e8eaf0')
          Text('圈内爆料')
            .fontSize(10.5)
            .fontColor('#8fa3c0')
          Blank()
        }
        .width('100%')
        .padding({ left: 12, right: 16, top: 10, bottom: 10 })

        if (this.items.length > 0) {
          WaterFlow() {
            ForEach(this.items, (p: Post) => {
              FlowItem() {
                PostCard({ p: p, wide: true, onOpen: () => {
                  this.navStack.pushPathByName('post', p.id);
                } })
              }
            }, (p: Post) => `${p.id}`)
          }
          .columnsTemplate('1fr 1fr')
          .columnsGap(8)
          .rowsGap(8)
          .layoutWeight(1)
          .padding({ left: 12, right: 12, bottom: 16 })
          .onReachEnd(() => {
            this.loadMore();
          })
        } else if (this.loading) {
          Column() {
            LoadingProgress()
              .width(32)
              .height(32)
              .color('#e8eaf0')
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          Column() {
            EmptyState({ title: '暂无吃瓜内容', sub: '稍后再来看看' })
          }
          .layoutWeight(1)
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

/* ── 帖子详情（NavDestination，网页式浏览 + 内嵌播放） ── */
@Component
export struct PostDetailPage {
  navStack: NavPathStack = new NavPathStack();
  @State p: PostDetailData | null = null;
  @State errMsg: string = '';
  @State playing: boolean = false;
  private postId: number = 0;
  private ctrl: XComponentController = new XComponentController();
  private surfaceId: string = '';

  aboutToAppear(): void {
    const arr: Array<Object> = this.navStack.getParamByName('post') as Array<Object>;
    if (arr && arr.length > 0) {
      const v = arr[arr.length - 1] as number;
      this.postId = v ?? 0;
    }
    this.load();
  }

  aboutToDisappear(): void {
    this.stopPlayer();
  }

  private stopPlayer(): void {
    this.playing = false;
    playerService.pause();
    playerService.release();
  }

  private async load(): Promise<void> {
    try {
      const d = await postDetail(this.postId);
      this.p = d;
    } catch (e) {
      this.errMsg = (e as Error).message;
    }
  }

  private async startPlay(): Promise<void> {
    const d = this.p;
    if (!d || d.videoUrl === '') {
      promptAction.showToast({ message: '该帖子没有视频' });
      return;
    }
    try {
      const sid = await this.ctrl.getXComponentSurfaceId();
      this.surfaceId = sid;
      playerService.playGate = null; // 详情页自己决定起播，不用首页的闸门
      playerService.setMuted(false);
      playerService.attach(await this.playableUrl(d), sid);
      this.playing = true;
    } catch (e) {
      promptAction.showToast({ message: (e as Error).message });
    }
  }

  /** 确保媒体服务在跑，再取代理地址 */
  private async playableUrl(d: PostDetailData): Promise<string> {
    await ensureMedia();
    return proxyUrl(d.videoUrl);
  }

  build() {
    NavDestination() {
      Column() {
        Row({ space: 8 }) {
          Button() {
            Image($r('app.media.ic_back'))
              .width(19)
              .height(19)
          }
          .type(ButtonType.Circle)
          .width(36)
          .height(36)
          .backgroundColor('rgba(255,255,255,0.08)')
          .onClick(() => {
            this.stopPlayer();
            this.navStack.pop();
          })
          Text('吃瓜详情')
            .fontSize(13.5)
            .fontWeight(FontWeight.Medium)
            .fontColor('#e8eaf0')
          Blank()
        }
        .width('100%')
        .padding({ left: 12, right: 16, top: 10, bottom: 10 })

        if (this.errMsg !== '') {
          Column() {
            EmptyState({ title: '加载失败', sub: this.errMsg })
          }
          .layoutWeight(1)
        } else if (this.p === null) {
          Column() {
            LoadingProgress()
              .width(32)
              .height(32)
              .color('#e8eaf0')
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          Scroll() {
            Column() {
              // 顶部媒体区
              Stack({ alignContent: Alignment.Center }) {
                if (this.playing) {
                  XComponent({ id: `post_vp_${this.p.id}`, type: 'surface', controller: this.ctrl })
                    .width('100%')
                    .height('100%')
                    .backgroundColor(Color.Black)
                } else {
                  Image(coverUrl(this.p.cover))
                    .width('100%')
                    .height('100%')
                    .objectFit(ImageFit.Cover)
                    .draggable(false)
                  Stack() {
                    Circle({ width: 56, height: 56 })
                      .fill('rgba(0,0,0,0.5)')
                    Image($r('app.media.ic_play_f'))
                      .width(22)
                      .height(22)
                  }
                  .onClick(() => {
                    this.startPlay();
                  })
                }
              }
              .width('100%')
              .height(300)
              .backgroundColor(Color.Black)
              .clip(true)

              Column() {
                Text(this.p.title)
                  .fontSize(17)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#e8eaf0')
                  .lineHeight(24)

                Row({ space: 12 }) {
                  Text(this.p.publishTime)
                    .fontSize(10.5)
                    .fontColor('#8fa3c0')
                  if (this.p.authorName !== '') {
                    Text(this.p.authorName)
                      .fontSize(10.5)
                      .fontColor('#8fa3c0')
                  }
                }
                .width('100%')
                .margin({ top: 8 })

                Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Start, space: { main: LengthMetrics.vp(6), cross: LengthMetrics.vp(6) } }) {
                  ForEach(this.p.tags.slice(0, 8), (t: string) => {
                    Text(`#${t}`)
                      .fontSize(10.5)
                      .fontColor('rgba(232,234,240,0.75)')
                      .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                      .backgroundColor('#1d222e')
                      .borderRadius(10)
                  }, (t: string) => t)
                }
                .width('100%')
                .margin({ top: 10 })

                if (this.p.content !== '') {
                  Text(this.p.contentIsHtml ? htmlToText(this.p.content) : this.p.content)
                    .fontSize(12.5)
                    .fontColor('rgba(232,234,240,0.8)')
                    .lineHeight(20)
                    .width('100%')
                    .padding(14)
                    .backgroundColor('#141821')
                    .borderRadius(12)
                    .margin({ top: 14 })
                }
              }
              .padding({ left: 16, right: 16, top: 14, bottom: 24 })
            }
            .width('100%')
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
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
