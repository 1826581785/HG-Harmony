/**
 * 主页：Navigation（页面栈）+ 底部 4 Tab（首页/搜索/分类/我的）。
 * 对应旧工程 App.tsx 的 AppBody + TabBar。
 */
import { HomeFeed } from './HomeFeed';

@Entry
@Component
struct Main {
  @State curTab: number = 0;
  @State navStack: NavPathStack = new NavPathStack();

  /** 返回键：栈交给 Navigation；无栈时回首页 Tab */
  onBackPress(): boolean {
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
  placeholderTab(title: string) {
    Column({ space: 8 }) {
      Text(title)
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor('#e8eaf0')
      Text('阶段 5 实现')
        .fontSize(12)
        .fontColor('#5a6478')
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
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
          this.placeholderTab('搜索')
        }
        .tabBar(this.tabItem('搜索', 1))

        TabContent() {
          this.placeholderTab('分类')
        }
        .tabBar(this.tabItem('分类', 2))

        TabContent() {
          this.placeholderTab('我的')
        }
        .tabBar(this.tabItem('我的', 3))
      }
      .barHeight(42)
      .barBackgroundColor('#10141d')
      .scrollable(false)
      .width('100%')
      .height('100%')
      .onChange((i: number) => {
        this.curTab = i;
      })
    }
    .mode(NavigationMode.Stack)
    .hideTitleBar(true)
    .hideToolBar(true)
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
