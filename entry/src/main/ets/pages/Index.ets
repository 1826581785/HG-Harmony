/**
 * 启动页：白底 Hello World + 四角隐藏点击热区。
 * 解锁序列：左上 1 下 → 右上 1 下 → 左下 1 下 → 右下 10 下（点错任意角重置进度），
 * 序列完成后 replaceUrl 进入 Main。对应旧需求「伪装启动页」。
 * 全局初始化（hgInit/store.init/dl 回调）都在 EntryAbility.onCreate，不依赖本页。
 */
import { router } from '@kit.ArkUI';

/** 角落热区边长（px），稍微大一点、透明、无点击效果 */
const HOT = 90;

@Entry
@Component
struct Index {
  @State message: string = 'Hello World';
  /** 当前解锁步骤：0=左上 1=右上 2=左下 3=右下 */
  private step: number = 0;
  /** 右下角连击计数 */
  private brCount: number = 0;

  private tapCorner(c: string): void {
    if (this.step === 0 && c === 'tl') {
      this.step = 1;
    } else if (this.step === 1 && c === 'tr') {
      this.step = 2;
    } else if (this.step === 2 && c === 'bl') {
      this.step = 3;
    } else if (this.step === 3 && c === 'br') {
      this.brCount += 1;
      if (this.brCount >= 10) {
        this.step = 0;
        this.brCount = 0;
        router.replaceUrl({ url: 'pages/Main' }).catch(() => {
        });
        return;
      }
      return;
    } else {
      // 点错角 → 重置
      this.step = 0;
      this.brCount = 0;
      return;
    }
  }

  /** 透明热区：无背景无点击态，纯面积触发 */
  @Builder
  hot(c: string) {
    Row()
      .width(HOT)
      .height(HOT)
      .backgroundColor(Color.Transparent)
      .onClick(() => {
        this.tapCorner(c);
      })
  }

  build() {
    Stack() {
      // 四角热区层（铺满全屏，上下两行夹 Blank）
      Column() {
        Row() {
          this.hot('tl')
          Blank()
          this.hot('tr')
        }
        .width('100%')

        Blank()

        Row() {
          this.hot('bl')
          Blank()
          this.hot('br')
        }
        .width('100%')
      }
      .width('100%')
      .height('100%')

      Text(this.message)
        .fontSize(38)
        .fontWeight(FontWeight.Bold)
        .fontColor('#000000')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.White)
  }
}
