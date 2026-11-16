import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { hgInit } from 'libhg.so';
import { store } from '../store';
import { dlOnState, dlRestore } from '../api';
import { DlTask } from '../model';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    // 绑定 Rust 会话/数据目录（session.json 持久化 token），必须在任何业务调用前
    try {
      hgInit(this.context.filesDir);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'hgInit failed: %{public}s', JSON.stringify(err));
    }
    // 本地数据（喜欢/收藏/历史/静音/音量/搜索历史）preferences 持久化，必须在页面构建前启动加载
    store.init(this.context).catch((err: Error) => {
      hilog.error(DOMAIN, 'testTag', 'store.init failed: %{public}s', err.message);
    });
    // 下载引擎：先注册状态回调（快照 JSON → AppStorage 'dlTasks'），再恢复中断任务续传
    // 注意：napi ThreadsafeFunction 默认 CalleeHandled=true，JS 回调收到 (err, data) 两个参数
    dlOnState((err: Object | null, json: string) => {
      try {
        const tasks: Object = JSON.parse(json) as Object;
        AppStorage.setOrCreate<DlTask[]>('dlTasks', Array.isArray(tasks) ? (tasks as DlTask[]) : []);
      } catch (e) {
        hilog.error(DOMAIN, 'testTag', 'dlOnState parse failed: %{public}s', String(e));
      }
    });
    dlRestore().catch((err: Error) => {
      hilog.error(DOMAIN, 'testTag', 'dlRestore failed: %{public}s', err.message);
    });
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    // 入口页 = Index（Hello World 伪装页，四角隐藏序列解锁后跳 Main）
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}