import { hello, hgVersion, hgInit, hgSelftest, hgMediaStart, hgPlay, hgMediaUrl, hgMediaSelftest } from 'libhg.so';
import { media } from '@kit.MediaKit';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * 阶段 1/2 调试页：dx150 协议链路 + 本地媒体服务 + AVPlayer AES-128 HLS spike。
 * 正式 UI（阶段 3 起）接管后此页退役。
 */
@Entry
@Component
struct Index {
  @State message: string = hello();
  @State protoTest: string = '未执行';
  @State mediaTest: string = '未执行';
  @State playMsg: string = '未播放';
  @State running: boolean = false;
  private surfaceId: string = '';
  private xcController: XComponentController = new XComponentController();
  private player: media.AVPlayer | null = null;

  aboutToAppear(): void {
    // session.json 等持久化文件落在应用沙箱 filesDir
    hgInit(getContext(this).filesDir);
  }

  private fmtSteps(r: Record<string, Object>): string {
    const lines: string[] = [];
    const steps = r.steps as Array<Record<string, Object>> ?? [];
    for (const s of steps) {
      const ok: boolean = s.ok as boolean;
      let line = `${ok ? '✓' : '✗'} ${s.step as string}`;
      if (ok && s.len !== undefined) {
        line += ` (len ${s.len as number})`;
      }
      if (!ok) {
        line += ` — ${s.error as string ?? JSON.stringify(s)}`;
      }
      lines.push(line);
    }
    lines.push('', r.ok ? '全部通过' : '存在失败项');
    return lines.join('\n');
  }

  private env(raw: string): Record<string, Object> {
    return JSON.parse(raw) as Record<string, Object>;
  }

  async runProto(): Promise<void> {
    this.running = true;
    this.protoTest = '自检中…';
    try {
      this.protoTest = this.fmtSteps(this.env(await hgSelftest()));
    } catch (e) {
      this.protoTest = `调用异常: ${(e as BusinessError).message ?? String(e)}`;
    }
    this.running = false;
  }

  async runMedia(): Promise<void> {
    this.running = true;
    this.mediaTest = '自检中…';
    try {
      this.mediaTest = this.fmtSteps(this.env(await hgMediaSelftest()));
    } catch (e) {
      this.mediaTest = `调用异常: ${(e as BusinessError).message ?? String(e)}`;
    }
    this.running = false;
  }

  async runPlay(): Promise<void> {
    try {
      const start = this.env(await hgMediaStart());
      if (start.ok !== true) {
        this.playMsg = '媒体服务启动失败';
        return;
      }
      const playEnv = this.env(await hgPlay(117, 3));
      if (playEnv.ok !== true) {
        this.playMsg = `取播放地址失败: ${playEnv.error as string}`;
        return;
      }
      const data = playEnv.data as Record<string, Object>;
      const videoUrl = data.video_url as string;
      const urlEnv = this.env(hgMediaUrl(videoUrl));
      if (urlEnv.ok !== true) {
        this.playMsg = `代理地址生成失败: ${urlEnv.error as string}`;
        return;
      }
      const localUrl = (urlEnv.data as Record<string, Object>).url as string;
      this.playMsg = '加载中…';

      if (this.player) {
        try { await this.player.release(); } catch (e) { /* 忽略 */ }
        this.player = null;
      }
      const p = await media.createAVPlayer();
      p.on('error', (err: BusinessError) => {
        this.playMsg = `播放错误(${err.code}): ${err.message}`;
      });
      p.on('stateChange', async (state: string) => {
        if (state === 'initialized') {
          // initialized 状态下才能绑 surface 并 prepare
          p.surfaceId = this.surfaceId;
          try {
            await p.prepare();
            await p.play();
            this.player = p;
            this.playMsg = '播放中';
          } catch (e) {
            this.playMsg = `prepare/play 异常: ${(e as BusinessError).message ?? String(e)}`;
          }
        } else if (state === 'completed' || state === 'stopped') {
          this.playMsg = '播放结束';
        }
      });
      // 赋 url 后 AVPlayer 异步进入 initialized，prepare 由状态回调驱动
      p.url = localUrl;
      this.playMsg = '初始化中…';
    } catch (e) {
      this.playMsg = `调用异常: ${(e as BusinessError).message ?? String(e)}`;
    }
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        Text(`hg-core ${hgVersion()} (rust on ohos)`)
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor('#e8eaf0')
          .alignSelf(ItemAlign.Center)

        XComponent({ id: 'player', type: 'surface', controller: this.xcController })
          .width('100%')
          .height(220)
          .backgroundColor('#000000')
          .onLoad(() => {
            this.surfaceId = this.xcController.getXComponentSurfaceId();
          })

        Text(this.playMsg)
          .fontSize(13)
          .fontFamily('monospace')
          .fontColor('#d8dee9')

        Button('播放测试（AVPlayer）')
          .width(220)
          .enabled(!this.running)
          .onClick(() => {
            this.runPlay();
          })

        Divider().strokeWidth(1).color('#39435a')

        Button('媒体自检（本地服务）')
          .width(220)
          .enabled(!this.running)
          .onClick(() => {
            this.runMedia();
          })
        Text(this.mediaTest)
          .fontSize(13)
          .fontFamily('monospace')
          .fontColor('#a8b6cc')

        Divider().strokeWidth(1).color('#39435a')

        Button('协议自检（dx150）')
          .width(220)
          .enabled(!this.running)
          .onClick(() => {
            this.runProto();
          })
        Text(this.protoTest)
          .fontSize(13)
          .fontFamily('monospace')
          .fontColor('#a8b6cc')
      }
      .padding(16)
      .width('100%')
    }
    .height('100%')
    .width('100%')
    .backgroundColor('#0b0e15')
  }
}
