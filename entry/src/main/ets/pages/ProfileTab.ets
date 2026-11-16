/**
 * 我的 Tab：未登录→登录/注册卡；已登录→资料卡 + 收藏/历史横滑行 + 设置。
 * 对应旧工程 pages/Profile.tsx（深色外观行暂缓，主题在阶段 7 资源化时接入）。
 */
import { videoDetail, login, register, logout, me, clearMediaCache, coverUrl } from '../api';
import { VideoDetail, VideoCard, FeedNavParam, FavListNavParam } from '../model';
import { store, fmtCount } from '../store';
import { RowCard, Masonry } from '../components/Cards';
import { promptAction } from '@kit.ArkUI';

/** 无服务端列表 API，按本地 id 拉详情，单区最多拉这么多条 */
const MAX_CARDS = 50;

/** 收藏/历史区块 Builder 参数（$$ 按引用传递，内部随状态刷新） */
export interface MediaSectionParam {
  title: string;
  icon: Resource;
  count: number;
  cards: VideoCard[];
  loading: boolean;
  hint: string;
  kind: string;
}

@Component
export struct ProfileTab {
  navStack: NavPathStack = new NavPathStack();
  @State mode: string = 'login';
  @State username: string = '';
  @State password: string = '';
  @State email: string = '';
  @State busy: boolean = false;
  @State err: string = '';
  @State loggedIn: boolean = false;
  @State favCards: VideoCard[] = [];
  @State histCards: VideoCard[] = [];
  @State favLoading: boolean = false;
  @State histLoading: boolean = false;
  /** 退出登录进行中（弹窗确认 + API 调用 loading） */
  @State loggingOut: boolean = false;
  @State favCount: number = 0;
  @State histCount: number = 0;
  private favGen: number = 0;
  private histGen: number = 0;
  /** 区块数据签名（id 串），变化才重载 */
  private favSig: string = '';
  private histSig: string = '';
  private avatarColor: string = '#4a90d9';
  /** 已刷新过 me() 的用户 id（防止 setUser→onUpdate→syncUser→me 无限循环） */
  private meUid: number = -1;
  /** 详情缓存：收藏/历史命中缓存立即出数据，不再重复请求 */
  private detailCache: Map<number, VideoCard> = new Map();

  aboutToAppear(): void {
    this.syncUser();
    store.onUpdate = () => {
      this.syncUser();
    };
  }

  aboutToDisappear(): void {
    store.onUpdate = null;
  }

  private syncUser(): void {
    const u = store.user;
    this.loggedIn = u !== null;
    if (u) {
      this.avatarColor = ['#4a90d9', '#e056a7', '#3fbf8f', '#d98a3f', '#8f6fd9'][Math.abs(u.id) % 5];
      // 后台刷新服务端计数：只在登录用户变化时刷一次（me 成功后 setUser 会再进本方法，
      // uid 相同直接跳过，避免无限循环）
      if (u.id !== this.meUid) {
        this.meUid = u.id;
        me().then((fresh) => {
          if (store.user && store.user.id === fresh.id) {
            store.setUser(fresh);
          }
        }).catch(() => {
        });
      }
    } else {
      this.meUid = -1;
    }
    this.favCount = store.favs.length;
    this.histCount = store.history.length;
    this.loadSection('fav');
    this.loadSection('hist');
  }

  /** 收藏/历史区块数据：按本地 id 拉详情（缓存无条件写入；数据签名未变则跳过重载） */
  private loadSection(kind: string): void {
    if (!this.loggedIn) {
      this.setSection(kind, [], false);
      return;
    }
    const ids = (kind === 'fav' ? store.favs : store.history).slice(0, MAX_CARDS);
    const sig = ids.join(',');
    const sigOf = kind === 'fav' ? this.favSig : this.histSig;
    if (sig === sigOf && (kind === 'fav' ? !this.favLoading : !this.histLoading)) {
      return; // 数据没变化，不重复拉取
    }
    if (kind === 'fav') {
      this.favSig = sig;
    } else {
      this.histSig = sig;
    }
    if (ids.length === 0) {
      this.setSection(kind, [], false);
      return;
    }
    const gen = kind === 'fav' ? ++this.favGen : ++this.histGen;
    // 全部命中缓存：立即出数据，不发请求
    let allCached = true;
    for (const id of ids) {
      if (!this.detailCache.has(id)) {
        allCached = false;
        break;
      }
    }
    if (allCached) {
      this.setSection(kind, this.cachedList(ids), false);
      return;
    }
    this.setSection(kind, undefined, true);
    const missing: number[] = [];
    for (const id of ids) {
      if (!this.detailCache.has(id)) {
        missing.push(id);
      }
    }
    const jobs: Promise<VideoCard | null>[] = missing.map((id: number) => {
      return videoDetail(id).then((d: VideoDetail) => {
        const c = new VideoCard();
        c.id = d.id;
        c.title = d.title;
        c.cover = d.cover;
        c.episodeCount = d.episodeCount;
        c.isFinished = d.isFinished;
        c.hot = d.hot > 0 ? d.hot : d.likeCount;
        return c;
      }).catch((): VideoCard | null => null);
    });
    Promise.all(jobs).then((rs: (VideoCard | null)[]) => {
      // 缓存无条件写入（与代数无关，避免连环重载时缓存永远填不上）
      for (const r of rs) {
        if (r !== null) {
          this.detailCache.set(r.id, r);
        }
      }
      // gen 已变（登出 / 清缓存 / 更新一次的数据重载）：本次 UI 更新作废
      const cur = kind === 'fav' ? this.favGen : this.histGen;
      if (gen !== cur) {
        return;
      }
      this.setSection(kind, this.cachedList(ids), false);
    });
  }

  private cachedList(ids: number[]): VideoCard[] {
    const out: VideoCard[] = [];
    for (const id of ids) {
      const c = this.detailCache.get(id);
      if (c) {
        out.push(c);
      }
    }
    return out;
  }

  private setSection(kind: string, cards: VideoCard[] | undefined, loading: boolean): void {
    if (kind === 'fav') {
      if (cards !== undefined) {
        this.favCards = cards;
      }
      this.favLoading = loading;
    } else {
      if (cards !== undefined) {
        this.histCards = cards;
      }
      this.histLoading = loading;
    }
  }

  private openSection(kind: string, cards: VideoCard[], v: VideoCard): void {
    const ids = cards.map((x: VideoCard) => x.id);
    // @Prop 传递的是拷贝件，必须按 id 找下标（按引用会得到 -1）
    let idx = 0;
    for (let i = 0; i < cards.length; i++) {
      if (cards[i].id === v.id) {
        idx = i;
        break;
      }
    }
    const param: FeedNavParam = {
      'ids': ids,
      'title': kind === 'fav' ? '我的收藏' : '观看历史',
      'index': idx
    };
    this.navStack.pushPathByName('feedview', param);
  }

  private async submit(): Promise<void> {
    if (this.username.trim() === '' || this.password === '') {
      this.err = '请输入账号与密码';
      return;
    }
    this.busy = true;
    this.err = '';
    try {
      const u = this.mode === 'login'
        ? await login(this.username.trim(), this.password)
        : await register(this.username.trim(), this.password, this.email.trim());
      store.setUser(u);
      this.password = '';
      promptAction.showToast({ message: this.mode === 'login' ? `欢迎回来，${u.nickname || u.username}` : '注册成功' });
    } catch (e) {
      this.err = (e as Error).message;
    } finally {
      this.busy = false;
    }
  }

  private confirmLogout(): void {
    AlertDialog.show({
      title: '退出登录',
      message: '确定要退出当前账号吗？',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '退出',
        fontColor: '#ff4d6a',
        action: () => {
          this.doLogout();
        }
      }
    });
  }

  private async doLogout(): Promise<void> {
    if (this.loggingOut) {
      return;
    }
    this.loggingOut = true;
    try {
      await logout();
    } catch (e) {
      // 接口失败也照样清除本地登录态
    }
    store.setUser(null);
    this.detailCache.clear();
    this.favSig = '';
    this.histSig = '';
    this.loggingOut = false;
    promptAction.showToast({ message: '已退出登录' });
  }

  private confirmClear(): void {
    AlertDialog.show({
      title: '清理缓存',
      message: '将清除封面与播放列表缓存、喜欢与收藏标记、观看历史和搜索历史。账号登录状态会保留。',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '确定清理',
        fontColor: '#ff4d6a',
        action: () => {
          clearMediaCache();
          this.detailCache.clear();
          store.clearLocal().then(() => {
            this.syncUser();
            promptAction.showToast({ message: '缓存已清理' });
          });
        }
      }
    });
  }

  @Builder
  downloadsEntry() {
    Row({ space: 12 }) {
      Stack() {
        Image($r('app.media.ic_download'))
          .width(20)
          .height(20)
      }
      .width(40)
      .height(40)
      .backgroundColor('#ff4d6a')
      .borderRadius(10)

      Column({ space: 2 }) {
        Text('我的下载')
          .fontSize(14.5)
          .fontWeight(FontWeight.Medium)
          .fontColor('#e8eaf0')
        Text('离线缓存 · 阶段 6 接入')
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
    .onClick(() => {
      promptAction.showToast({ message: '下载引擎在阶段 6 接入' });
    })
  }

  /** 收藏/历史区块：$$ 按引用传参（按值传参不响应状态变化，会定格在首次求值） */
  @Builder
  mediaSection($$: MediaSectionParam) {
    Column() {
      Row({ space: 8 }) {
        Stack() {
          Image($$.icon)
            .width(15)
            .height(15)
            .fillColor('#ff4d6a')
        }
        .width(30)
        .height(30)
        .backgroundColor('#1d222e')
        .borderRadius(15)

        Text($$.title)
          .fontSize(13.5)
          .fontWeight(FontWeight.Medium)
          .fontColor('#e8eaf0')
        Text(`${$$.count}`)
          .fontSize(10.5)
          .fontColor('#8fa3c0')
          .padding({ left: 8, right: 8, top: 1, bottom: 1 })
          .backgroundColor('#1d222e')
          .borderRadius(10)
        Blank()
        if ($$.count > 0) {
          Row({ space: 2 }) {
            Text('全部')
              .fontSize(11.5)
              .fontColor('#ff4d6a')
            Image($r('app.media.ic_chev_r'))
              .width(12)
              .height(12)
              .fillColor('#ff4d6a')
          }
          .onClick(() => {
            const param: FavListNavParam = { 'kind': $$.kind, 'title': $$.title };
            this.navStack.pushPathByName('favlist', param);
          })
        }
      }
      .width('100%')

      if ($$.loading) {
        Row() {
          LoadingProgress()
            .width(22)
            .height(22)
            .color('#e8eaf0')
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .padding({ top: 20, bottom: 20 })
      } else if ($$.cards.length > 0) {
        Scroll() {
          Row({ space: 10 }) {
            ForEach($$.cards, (v: VideoCard) => {
              RowCard({ v: v, onOpen: () => {
                this.openSection($$.kind, $$.cards, v);
              } })
            }, (v: VideoCard) => `${v.id}-${$$.kind}`)
          }
          .padding({ left: 2, right: 2 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .align(Alignment.Start)
        .width('100%')
        .margin({ top: 10 })
      } else {
        Text($$.hint)
          .fontSize(11.5)
          .fontColor('#5c6678')
          .width('100%')
          .padding({ top: 14, bottom: 14 })
      }
    }
    .width('100%')
    .margin({ top: 16 })
  }

  @Builder
  loggedOutBody() {
    Column() {
      // 登录/注册卡
      Column() {
        Row({ space: 12 }) {
          Stack() {
            Image($r('app.media.ic_user'))
              .width(24)
              .height(24)
              .fillColor('#ffffff')
          }
          .width(52)
          .height(52)
          .backgroundColor(this.avatarColor)
          .borderRadius(26)

          Column({ space: 3 }) {
            Text(this.mode === 'login' ? '登录 ' : '注册 ')
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor('#e8eaf0')
            Text(this.mode === 'login' ? '账号密码登录，与官网同源' : '注册后可在多端同步')
              .fontSize(10.5)
              .fontColor('#8fa3c0')
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .width('100%')

        Row({ space: 4 }) {
          Text('登录')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.mode === 'login' ? '#ffffff' : '#8fa3c0')
            .backgroundColor(this.mode === 'login' ? '#ff4d6a' : Color.Transparent)
            .textAlign(TextAlign.Center)
            .height(32)
            .borderRadius(12)
            .layoutWeight(1)
            .onClick(() => {
              this.mode = 'login';
              this.err = '';
            })
          Text('注册')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.mode === 'register' ? '#ffffff' : '#8fa3c0')
            .backgroundColor(this.mode === 'register' ? '#ff4d6a' : Color.Transparent)
            .textAlign(TextAlign.Center)
            .height(32)
            .borderRadius(12)
            .layoutWeight(1)
            .onClick(() => {
              this.mode = 'register';
              this.err = '';
            })
        }
        .width('100%')
        .padding(4)
        .backgroundColor('#1d222e')
        .borderRadius(14)
        .margin({ top: 16 })

        TextInput({ text: this.username, placeholder: '账号（4-20 位字母/数字/下划线）' })
          .height(40)
          .fontSize(13)
          .fontColor('#e8eaf0')
          .placeholderColor('#5c6678')
          .backgroundColor('#1d222e')
          .borderRadius(10)
          .width('100%')
          .margin({ top: 14 })
          .onChange((v: string) => {
            this.username = v;
          })

        TextInput({ text: this.password, placeholder: '密码（6-20 位）' })
          .type(InputType.Password)
          .height(40)
          .fontSize(13)
          .fontColor('#e8eaf0')
          .placeholderColor('#5c6678')
          .backgroundColor('#1d222e')
          .borderRadius(10)
          .width('100%')
          .margin({ top: 10 })
          .onChange((v: string) => {
            this.password = v;
          })
          .onSubmit(() => {
            this.submit();
          })

        if (this.mode === 'register') {
          TextInput({ text: this.email, placeholder: '邮箱（可选）' })
            .height(40)
            .fontSize(13)
            .fontColor('#e8eaf0')
            .placeholderColor('#5c6678')
            .backgroundColor('#1d222e')
            .borderRadius(10)
            .width('100%')
            .margin({ top: 10 })
            .onChange((v: string) => {
              this.email = v;
            })
        }

        if (this.err !== '') {
          Text(this.err)
            .fontSize(11.5)
            .fontColor('#ff9a9a')
            .width('100%')
            .margin({ top: 10 })
        }

        Button() {
          Text(this.busy ? '处理中…' : (this.mode === 'login' ? '登录' : '注册并登录'))
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor('#ffffff')
        }
        .width('100%')
        .height(40)
        .borderRadius(12)
        .backgroundColor(this.busy ? '#8a3a4e' : '#ff4d6a')
        .margin({ top: 14 })
        .enabled(!this.busy)
        .onClick(() => {
          this.submit();
        })
      }
      .width('100%')
      .padding(20)
      .backgroundColor('#141821')
      .borderRadius(16)

      // 登录能做什么
      Column({ space: 8 }) {
        Row({ space: 6 }) {
          Image($r('app.media.ic_user_f'))
            .width(15)
            .height(15)
            .fillColor('#ff4d6a')
          Text('登录能做什么')
            .fontSize(12.5)
            .fontWeight(FontWeight.Medium)
            .fontColor('rgba(232,234,240,0.9)')
        }
        Text('· 点赞 / 收藏与官网账号同步')
          .fontSize(11.5)
          .fontColor('#8fa3c0')
        Text('· 按剧集记录观看进度')
          .fontSize(11.5)
          .fontColor('#8fa3c0')
        Text('· 发表评论与回复')
          .fontSize(11.5)
          .fontColor('#8fa3c0')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(16)
      .backgroundColor('#10141d')
      .borderRadius(12)
      .margin({ top: 20 })

      this.downloadsEntry()
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12 })
  }

  @Builder
  loggedInBody() {
    Column() {
      // 资料卡
      Row({ space: 14 }) {
        Stack() {
          Text(store.user ? (store.user.nickname === '' ? store.user.username.substring(0, 1) : store.user.nickname.substring(0, 1)) : '?')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor('#ffffff')
        }
        .width(56)
        .height(56)
        .backgroundColor(this.avatarColor)
        .borderRadius(28)

        Column({ space: 3 }) {
          Text(store.user ? store.user.nickname : '')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor('#e8eaf0')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(store.user ? `@${store.user.username} · ID ${store.user.id}` : '')
            .fontSize(11)
            .fontColor('#8fa3c0')
          Row({ space: 12 }) {
            Text() {
              Span('点赞 ')
                .fontSize(10.5)
                .fontColor('#8fa3c0')
              Span(store.user ? fmtCount(store.user.likeCount) : '')
                .fontSize(10.5)
                .fontWeight(FontWeight.Bold)
                .fontColor('#e8eaf0')
            }
            Text() {
              Span('收藏 ')
                .fontSize(10.5)
                .fontColor('#8fa3c0')
              Span(store.user ? fmtCount(store.user.collectCount) : '')
                .fontSize(10.5)
                .fontWeight(FontWeight.Bold)
                .fontColor('#e8eaf0')
            }
            Text() {
              Span('关注 ')
                .fontSize(10.5)
                .fontColor('#8fa3c0')
              Span(store.user ? fmtCount(store.user.followingCount) : '')
                .fontSize(10.5)
                .fontWeight(FontWeight.Bold)
                .fontColor('#e8eaf0')
            }
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Button() {
          Image($r('app.media.ic_logout'))
            .width(16)
            .height(16)
            .fillColor('#8fa3c0')
        }
        .type(ButtonType.Circle)
        .width(36)
        .height(36)
        .backgroundColor('#1d222e')
        .onClick(() => {
          this.confirmLogout();
        })
      }
      .width('100%')
      .padding(16)
      .backgroundColor('#141821')
      .borderRadius(16)

      this.downloadsEntry()

      // 我的收藏：一行横滑（样式对齐分类页频道行）
      this.mediaSection({
        'title': '我的收藏',
        'icon': $r('app.media.ic_star'),
        'count': this.favCount,
        'cards': this.favCards,
        'loading': this.favLoading,
        'hint': '还没有收藏，在剧集页点星标收藏',
        'kind': 'fav'
      })

      // 观看历史：一行横滑
      this.mediaSection({
        'title': '观看历史',
        'icon': $r('app.media.ic_clock'),
        'count': this.histCount,
        'cards': this.histCards,
        'loading': this.histLoading,
        'hint': '还没有观看记录，看过的剧集会出现在这里',
        'kind': 'hist'
      })

      if (this.histCards.length > 0) {
        Text('清空观看历史')
          .fontSize(12)
          .fontColor('#8fa3c0')
          .textAlign(TextAlign.Center)
          .width('100%')
          .height(36)
          .backgroundColor('#1d222e')
          .borderRadius(12)
          .margin({ top: 12 })
          .onClick(() => {
            store.clearHistory().then(() => {
              this.syncUser();
            });
          })
      }

      // 设置
      Column() {
        Row({ space: 12 }) {
          Stack() {
            Image($r('app.media.ic_info'))
              .width(15)
              .height(15)
              .fillColor('#ff4d6a')
          }
          .width(32)
          .height(32)
          .backgroundColor('#1d222e')
          .borderRadius(16)

          Column({ space: 2 }) {
            Text('关于')
              .fontSize(12.5)
              .fontColor('#e8eaf0')
            Text(' HarmonyOS 客户端')
              .fontSize(10.5)
              .fontColor('#8a93a6')
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Image($r('app.media.ic_chev_r'))
            .width(14)
            .height(14)
            .fillColor('#8fa3c0')
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 12, bottom: 12 })
        .onClick(() => {
          AlertDialog.show({
            title: '关于 ',
            message: '原生 ArkUI + Rust（OHOS NAPI）构建的鸿蒙客户端，播放采用沉浸式竖屏信息流。\n\n本项目仅供学习与交流，所有内容均来自上游站点，客户端不存储、不分发任何视频内容。请于 24 小时内删除相关资源，并支持正版。',
            autoCancel: true,
            alignment: DialogAlignment.Center,
            primaryButton: {
              value: '知道了',
              action: () => {
              }
            },
            secondaryButton: {
              value: '关闭',
              action: () => {
              }
            }
          });
        })

        Divider().color('rgba(255,255,255,0.05)').width('90%')

        Row({ space: 12 }) {
          Stack() {
            Image($r('app.media.ic_broom'))
              .width(15)
              .height(15)
              .fillColor('#ff4d6a')
          }
          .width(32)
          .height(32)
          .backgroundColor('#1d222e')
          .borderRadius(16)

          Column({ space: 2 }) {
            Text('清理缓存')
              .fontSize(12.5)
              .fontColor('#e8eaf0')
            Text('封面 / 播放缓存与本地记录')
              .fontSize(10.5)
              .fontColor('#8a93a6')
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Image($r('app.media.ic_chev_r'))
            .width(14)
            .height(14)
            .fillColor('#8fa3c0')
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 12, bottom: 12 })
        .onClick(() => {
          this.confirmClear();
        })
      }
      .width('100%')
      .backgroundColor('#10141d')
      .borderRadius(12)
      .margin({ top: 20 })

      Text(' · HarmonyOS 客户端')
        .fontSize(10)
        .fontColor('#5c6678')
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ top: 20 })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12 })
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        Row() {
          Text('我的')
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor('#e8eaf0')
          Blank()
        }
        .width('100%')
        .alignItems(VerticalAlign.Bottom)
        .padding({ left: 16, right: 16, top: 14, bottom: 6 })

        Scroll() {
          if (this.loggedIn) {
            this.loggedInBody();
          } else {
            Column() {
              this.loggedOutBody()
            }
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

      // 退出登录 loading 遮罩
      if (this.loggingOut) {
        Column({ space: 10 }) {
          LoadingProgress()
            .width(32)
            .height(32)
            .color('#e8eaf0')
          Text('退出中…')
            .fontSize(12)
            .fontColor('#c3cad6')
        }
        .alignItems(HorizontalAlign.Center)
        .padding({ left: 24, right: 24, top: 16, bottom: 16 })
        .backgroundColor('rgba(0,0,0,0.6)')
        .borderRadius(14)
      }
    }
    .width('100%')
    .height('100%')
  }
}

/* ── 收藏/历史查看全部（NavDestination，整页瀑布流） ── */
@Component
export struct FavListPage {
  navStack: NavPathStack = new NavPathStack();
  @State kind: string = 'fav';
  @State title: string = '';
  @State items: VideoCard[] = [];
  @State loading: boolean = true;
  @State total: number = 0;
  private gen: number = 0;
  private cache: Map<number, VideoCard> = new Map();

  aboutToAppear(): void {
    const arr: Array<Object> = this.navStack.getParamByName('favlist') as Array<Object>;
    if (arr && arr.length > 0) {
      const p = arr[arr.length - 1] as Record<string, Object>;
      this.kind = (p['kind'] as string) ?? 'fav';
      this.title = (p['title'] as string) ?? '';
    }
    this.load();
  }

  private async load(): Promise<void> {
    const gen = ++this.gen;
    const ids = (this.kind === 'fav' ? store.favs : store.history).slice(0, 100);
    this.total = this.kind === 'fav' ? store.favs.length : store.history.length;
    if (ids.length === 0) {
      this.items = [];
      this.loading = false;
      return;
    }
    const missing: number[] = [];
    for (const id of ids) {
      if (!this.cache.has(id)) {
        missing.push(id);
      }
    }
    if (missing.length === 0) {
      this.items = this.cached(ids);
      this.loading = false;
      return;
    }
    const jobs: Promise<VideoCard | null>[] = missing.map((id: number) => {
      return videoDetail(id).then((d: VideoDetail) => {
        const c = new VideoCard();
        c.id = d.id;
        c.title = d.title;
        c.cover = d.cover;
        c.episodeCount = d.episodeCount;
        c.isFinished = d.isFinished;
        c.hot = d.hot > 0 ? d.hot : d.likeCount;
        return c;
      }).catch((): VideoCard | null => null);
    });
    const rs = await Promise.all(jobs);
    if (gen !== this.gen) {
      return;
    }
    for (const r of rs) {
      if (r !== null) {
        this.cache.set(r.id, r);
      }
    }
    this.items = this.cached(ids);
    this.loading = false;
  }

  private cached(ids: number[]): VideoCard[] {
    const out: VideoCard[] = [];
    for (const id of ids) {
      const c = this.cache.get(id);
      if (c) {
        out.push(c);
      }
    }
    return out;
  }

  build() {
    NavDestination() {
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

          Column({ space: 2 }) {
            Text(this.title === '' ? (this.kind === 'fav' ? '我的收藏' : '观看历史') : this.title)
              .fontSize(17)
              .fontWeight(FontWeight.Bold)
              .fontColor('#e8eaf0')
            Text(`共 ${this.total} 条`)
              .fontSize(10.5)
              .fontColor('#8fa3c0')
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })

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
          Masonry({ items: this.items, onOpen: (v: VideoCard) => {
            const ids = this.items.map((x: VideoCard) => x.id);
            let idx = 0;
            for (let i = 0; i < this.items.length; i++) {
              if (this.items[i].id === v.id) {
                idx = i;
                break;
              }
            }
            const param: FeedNavParam = {
              'ids': ids,
              'title': this.kind === 'fav' ? '我的收藏' : '观看历史',
              'index': idx
            };
            this.navStack.pushPathByName('feedview', param);
          } })
            .layoutWeight(1)
            .padding({ left: 12, right: 12, bottom: 16 })
        } else {
          Column({ space: 8 }) {
            Text('这里还是空的')
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor('#8fa3c0')
            Text(this.kind === 'fav' ? '在剧集页点星标收藏' : '看过的剧集会出现在这里')
              .fontSize(11)
              .fontColor('#5c6678')
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
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
