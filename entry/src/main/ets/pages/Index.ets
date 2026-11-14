import { hello, hgVersion, hgInit, hgSelftest } from 'libhg.so';

/**
 * 阶段 1 调试页：验证 dx150 协议链路（public 明文 + user/playback 加密通道）。
 * 正式 UI（阶段 3 起）接管后此页退役。
 */
@Entry
@Component
struct Index {
  @State message: string = hello();
  @State selftest: string = '点下方按钮跑协议自检';
  @State running: boolean = false;

  aboutToAppear(): void {
    // session.json 等持久化文件落在应用沙箱 filesDir
    hgInit(getContext(this).filesDir);
  }

  async runSelftest(): Promise<void> {
    this.running = true;
    this.selftest = '自检中…';
    try {
      const raw: string = await hgSelftest();
      const r: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
      const steps: Array<Record<string, Object>> = r.steps as Array<Record<string, Object>>;
      const lines: string[] = [];
      for (const s of steps) {
        const ok: boolean = s.ok as boolean;
        lines.push(`${ok ? '✓' : '✗'} ${s.step as string}${ok ? '' : ' — ' + (s.error as string ?? '')}`);
      }
      lines.push('', r.ok ? '全部通过' : '存在失败项');
      this.selftest = lines.join('\n');
    } catch (e) {
      this.selftest = `调用异常: ${JSON.stringify(e)}`;
    }
    this.running = false;
  }

  build() {
    Column({ space: 16 }) {
      Text(`hg-core ${hgVersion()} (rust on ohos)`)
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .alignSelf(ItemAlign.Center)

      Button(this.running ? '自检中…' : '协议自检')
        .width(200)
        .enabled(!this.running)
        .onClick(() => {
          this.runSelftest();
        })

      Scroll() {
        Text(this.selftest)
          .fontSize(13)
          .fontFamily('monospace')
          .padding(12)
      }
      .layoutWeight(1)
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
    }
    .padding(20)
    .height('100%')
    .width('100%')
    .backgroundColor('#0b0e15')
  }
}
