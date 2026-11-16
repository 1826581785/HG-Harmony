/**
 * 主页：Navigation（页面栈）+ 底部 4 Tab（首页/搜索/分类/我的）。
 * 对应旧工程 App.tsx 的 AppBody + TabBar。
 * 页面栈：feedview 片单播放 / ranks 排行榜 / channel 频道详情 / posts 吃瓜列表 / post 吃瓜详情。
 */
import { HomeFeed } from './HomeFeed';
import { SearchTab } from './SearchTab';
import { CategoryTab, ChannelPage } from './CategoryTab';
import { ProfileTab, FavListPage } from './ProfileTab';
import { RankPage } from './RankPage';
import { PostsPage, PostDetailPage } from './PostsTab';
import { DownloadsPage } from './DownloadsPage';
import { FeedPage } from './FeedView';
import { boot } from '../api';
import { store } from '../store';
import { playerService } from '../player/PlayerService';
import { window } from '@kit.ArkUI';

@Entry
@Component
struct Main {
  @State curTab: number = 0;
  @State navStack: NavPathStack = new NavPathStack();

  aboutToAppear(): void {
    // 主体深色 → 状态栏内容（文字/图标）改白色（启动页 Index 白底用默认黑色）
    window.getLastWindow(getContext(this)).then((w: window.Window) => {
      w.setWindowSystemBarProperties({ statusBarContentColor: '#ffffff' });
    }).catch(() => {
    });
    // 恢复登录态（token 在 Rust session.json，重启后 boot 返回 user）
    boot().then((u) => {
      store.setUser(u);
    }).catch(() => {
    });
  }

  /** 返回键：沉浸全屏 → 页面栈 → 回首页 Tab → 退出 */
  onBackPress(): boolean {
    if (AppStorage.get<boolean>('feedFs') === true) {
      AppStorage.set<boolean>('feedFs', false);
      return true;
    }
    if (this.navStack.size() > 0) {
      this.navStack.pop();
      return true;
    }
    if (this.curTab !== 0) {
      this.curTab = 0;
      return true;
    }
    return false; // 默认行为：退出应用
  }

  @Builder
  pageMap(name: string) {
    if (name === 'feedview') {
      FeedPage({ navStack: this.navStack })
    } else if (name === 'ranks') {
      RankPage({ navStack: this.navStack })
    } else if (name === 'channel') {
      ChannelPage({ navStack: this.navStack })
    } else if (name === 'posts') {
      PostsPage({ navStack: this.navStack })
    } else if (name === 'post') {
      PostDetailPage({ navStack: this.navStack })
    } else if (name === 'favlist') {
      FavListPage({ navStack: this.navStack })
    } else if (name === 'downloads') {
      DownloadsPage({ navStack: this.navStack })
    }
  }

  build() {
    Navigation(this.navStack) {
      Tabs({ index: this.curTab, barPosition: BarPosition.End }) {
        TabContent() {
          HomeFeed({
            navStack: this.navStack,
            onOpenSearch: () => {
              this.curTab = 1;
            }
          })
        }
        .tabBar(this.tabItem('首页', 0))

        TabContent() {
          SearchTab({
            navStack: this.navStack,
            onOpenRanks: () => {
              this.navStack.pushPathByName('ranks', '');
            }
          })
        }
        .tabBar(this.tabItem('搜索', 1))

        TabContent() {
          CategoryTab({
            navStack: this.navStack,
            onOpenRanks: () => {
              this.navStack.pushPathByName('ranks', '');
            },
            onOpenPosts: () => {
              this.navStack.pushPathByName('posts', '');
            }
          })
        }
        .tabBar(this.tabItem('分类', 2))

        TabContent() {
          ProfileTab({ navStack: this.navStack })
        }
        .tabBar(this.tabItem('我的', 3))
      }
      .barHeight(42)
      .barBackgroundColor('#10141d')
      .scrollable(false)
      .width('100%')
      .height('100%')
      .onChange((i: number) => {
        // 离开首页时暂停播放流（片单页/详情页需要独占播放器）；回来后由 HomeFeed 恢复
        AppStorage.setOrCreate('feedTabVisible', i === 0);
        if (i !== 0) {
          playerService.pause();
        }
        this.curTab = i;
      })
    }
    .mode(NavigationMode.Stack)
    .hideTitleBar(true)
    .hideToolBar(true)
    .navDestination(this.pageMap)
    .width('100%')
    .height('100%')
    .backgroundColor('#0b0e15')
  }

  @Builder
  tabItem(label: string, index: number) {
    Column({ space: 4 }) {
      Text(label)
        .fontSize(13)
        .fontWeight(this.curTab === index ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.curTab === index ? '#e8eaf0' : '#5a6478')
      Circle({ width: 3, height: 3 })
        .fill(this.curTab === index ? '#e8eaf0' : Color.Transparent)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }
}
