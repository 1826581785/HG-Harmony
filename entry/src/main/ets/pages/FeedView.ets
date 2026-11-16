/**
 * 片单播放页（NavDestination）：复用 HomeFeed 的播放流，按传入 id 列表播放。
 * 搜索 / 榜单 / 频道 / 收藏历史入口统一 push('feedview', {ids, title})。
 */
import { HomeFeed } from './HomeFeed';

@Component
export struct FeedPage {
  navStack: NavPathStack = new NavPathStack();
  @State ids: number[] = [];
  @State startIdx: number = 0;

  aboutToAppear(): void {
    const arr: Array<Object> = this.navStack.getParamByName('feedview') as Array<Object>;
    if (arr && arr.length > 0) {
      const p = arr[arr.length - 1] as Record<string, Object>;
      this.ids = (p['ids'] as Array<number>) ?? [];
      this.startIdx = (p['index'] as number) ?? 0;
    }
  }

  build() {
    NavDestination() {
      if (this.ids.length > 0) {
        HomeFeed({ navStack: this.navStack, listIds: this.ids, startIdx: this.startIdx })
      }
    }
    .hideTitleBar(true)
    .backgroundColor('#000000')
  }
}
