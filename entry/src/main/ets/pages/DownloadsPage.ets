/**
 * 我的下载页（NavDestination）：下载中/已下载双子 Tab + 任务行（进度/速度/分片/操作）。
 * 对应旧工程 pages/Downloads.tsx。
 * 任务快照由 Rust 经 dlOnState 回调实时推送到 AppStorage('dlTasks')；
 * 已完成行用 SaveButton 安全组件保存到系统图库（photoAccessHelper，免权限弹窗）。
 */
import { dlList, dlVerify, dlPause, dlResume, dlRetry, dlRemove, dlFile } from '../api';
import { DlTask } from '../model';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { promptAction } from '@kit.ArkUI';

const STATUS_TEXT: Record<string, string> = {
  'queued': '排队中',
  'running': '下载中',
  'paused': '已暂停',
  'muxing': '合成 MP4 中',
  'saving': '保存中',
  'done': '已完成',
  'failed': '失败',
};

function fmt1(n: number): string {
  return n >= 10 ? n.toFixed(0) : n.toFixed(1);
}

@Component
export struct DownloadsPage {
  navStack: NavPathStack = new NavPathStack();
  @StorageLink('dlTasks') dlTasks: DlTask[] = [];
  @State tab: string = 'active';

  aboutToAppear(): void {
    // 校验已完成文件是否还在磁盘上；兜底拉一次快照（回调异常丢失时）
    dlVerify().catch(() => {
    });
    dlList().then((tasks: DlTask[]) => {
      AppStorage.setOrCreate<DlTask[]>('dlTasks', tasks);
    }).catch(() => {
    });
  }

  private active(): DlTask[] {
    return (this.dlTasks ?? []).filter((t: DlTask) => t.status !== 'done');
  }

  private finished(): DlTask[] {
    return (this.dlTasks ?? []).filter((t: DlTask) => t.status === 'done');
  }

  /** 保存到系统图库（SaveButton 安全组件点击内触发，免权限弹窗） */
  private async saveToGallery(t: DlTask): Promise<void> {
    try {
      const path: string = await dlFile(t.id);
      if (path === '') {
        promptAction.showToast({ message: '文件不存在，可能已被清理' });
        return;
      }
      const ctx = getContext(this);
      const helper = photoAccessHelper.getPhotoAccessHelper(ctx);
      const req = photoAccessHelper.MediaAssetChangeRequest.createVideoAssetRequest(ctx, path);
      await helper.applyChanges(req);
      promptAction.showToast({ message: '已保存到图库' });
    } catch (e) {
      promptAction.showToast({ message: (e as Error).message });
    }
  }

  @Builder
  taskRow(t: DlTask) {
    Row({ space: 12 }) {
      // 集数徽章 / 完成图标
      Stack() {
        if (t.status === 'done') {
          Image($r('app.media.ic_download'))
            .width(18)
            .height(18)
            .fillColor('#ffb84d')
        } else {
          Text(`第${t.ep}集`)
            .fontSize(11)
            .fontWeight(FontWeight.Bold)
            .fontColor('#ff4d6a')
        }
      }
      .width(40)
      .height(40)
      .backgroundColor('#1d222e')
      .borderRadius(10)

      Column({ space: 4 }) {
        Row({ space: 8 }) {
          Text(t.title)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor('#e8eaf0')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(`第${t.ep}集`)
            .fontSize(10.5)
            .fontColor('#8a93a6')
        }
        .width('100%')

        if (t.status === 'done') {
          Text(t.file ?? '已保存')
            .fontSize(11)
            .fontColor('#8a93a6')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        } else {
          // 进度条
          Stack({ alignContent: Alignment.Start }) {
            Row()
              .width('100%')
              .height(5)
              .borderRadius(3)
              .backgroundColor('#1d222e')
            Row()
              .width(`${t.mb_total > 0 ? Math.min(100, (t.mb_done / t.mb_total) * 100) : 0}%`)
              .height(5)
              .borderRadius(3)
              .backgroundColor(t.status === 'failed' ? '#e05a5a' : '#ff4d6a')
          }
          .width('100%')

          Row({ space: 6 }) {
            Text(STATUS_TEXT[t.status] ?? t.status)
              .fontSize(10.5)
              .fontColor(t.status === 'failed' ? '#e05a5a' : '#8a93a6')
            if (t.status === 'running' || t.status === 'saving' || t.status === 'muxing') {
              Text(`${fmt1(t.speed)} MB/s`)
                .fontSize(10.5)
                .fontColor('#ff4d6a')
            }
            Text(`${fmt1(t.mb_done)}/${t.mb_total > 0 ? fmt1(t.mb_total) : '?'} MB`)
              .fontSize(10.5)
              .fontColor('#8a93a6')
            Text(`${t.seg_done}/${t.seg_total > 0 ? t.seg_total : '?'} 段`)
              .fontSize(10.5)
              .fontColor('#5c6678')
          }
          .width('100%')

          if (t.error !== null && t.error !== '') {
            Text(t.error)
              .fontSize(10.5)
              .fontColor('#e05a5a')
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // 操作区
      Column({ space: 6 }) {
        if (t.status === 'running') {
          Text('暂停')
            .fontSize(11)
            .fontColor('#e8eaf0')
            .backgroundColor('#1d222e')
            .borderRadius(8)
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .onClick(() => {
              dlPause(t.id).catch(() => {
              });
            })
        }
        if (t.status === 'paused') {
          Text('继续')
            .fontSize(11)
            .fontColor('#ffffff')
            .backgroundColor('#ff4d6a')
            .borderRadius(8)
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .onClick(() => {
              dlResume(t.id).catch(() => {
              });
            })
        }
        if (t.status === 'failed') {
          Text('重试')
            .fontSize(11)
            .fontColor('#ffffff')
            .backgroundColor('#ff4d6a')
            .borderRadius(8)
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .onClick(() => {
              dlRetry(t.id).catch(() => {
              });
            })
        }
        if (t.status === 'done') {
          SaveButton()
            .onClick((event: ClickEvent, result: SaveButtonOnClickResult) => {
              if (result === SaveButtonOnClickResult.SUCCESS) {
                this.saveToGallery(t);
              } else {
                promptAction.showToast({ message: '保存授权失败，请重试' });
              }
            })
        }
        Image($r('app.media.ic_close'))
          .width(15)
          .height(15)
          .fillColor('#8a93a6')
          .onClick(() => {
            dlRemove(t.id).catch(() => {
            });
          })
      }
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .border({ width: { bottom: 0.5 }, color: '#1d222e' })
  }

  build() {
    NavDestination() {
      Column() {
        // 头部
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

          Text('我的下载')
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor('#e8eaf0')
        }
        .width('100%')
        .padding({ left: 12, right: 16, top: 10, bottom: 10 })

        // 子 Tab
        Row() {
          ForEach([['active', `下载中 (${this.active().length})`], ['done', `已下载 (${this.finished().length})`]], (kv: string[]) => {
            Text(kv[1])
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.tab === kv[0] ? '#ffffff' : '#8fa3c0')
              .backgroundColor(this.tab === kv[0] ? '#ff4d6a' : '#1d222e')
              .textAlign(TextAlign.Center)
              .height(32)
              .borderRadius(12)
              .layoutWeight(1)
              .onClick(() => {
                this.tab = kv[0];
              })
          }, (kv: string[]) => kv[0])
        }
        .width('100%')
        .padding(4)
        .backgroundColor('#141821')
        .borderRadius(14)
        .margin({ left: 16, right: 16, top: 4, bottom: 8 })

        // 列表
        Scroll() {
          Column() {
            if (this.tab === 'active') {
              if (this.active().length > 0) {
                ForEach(this.active(), (t: DlTask) => {
                  this.taskRow(t)
                }, (t: DlTask) => `${t.id}_${t.status}_${t.seg_done}_${t.mb_done.toFixed(1)}`)
              } else {
                Column({ space: 8 }) {
                  Image($r('app.media.ic_download'))
                    .width(26)
                    .height(26)
                    .opacity(0.5)
                  Text('暂无下载任务')
                    .fontSize(13)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#8fa3c0')
                  Text('在播放页右侧点下载按钮即可离线观看')
                    .fontSize(11)
                    .fontColor('#5c6678')
                }
                .width('100%')
                .margin({ top: 120 })
              }
            } else {
              if (this.finished().length > 0) {
                ForEach(this.finished(), (t: DlTask) => {
                  this.taskRow(t)
                }, (t: DlTask) => `${t.id}_${t.file}`)
              } else {
                Column({ space: 8 }) {
                  Image($r('app.media.ic_download'))
                    .width(26)
                    .height(26)
                    .opacity(0.5)
                  Text('还没有已下载的内容')
                    .fontSize(13)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#8fa3c0')
                }
                .width('100%')
                .margin({ top: 120 })
              }
            }
          }
          .width('100%')
          .padding({ bottom: 24 })
        }
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
        .width('100%')
        .layoutWeight(1)
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#0b0e15')
    }
    .hideTitleBar(true)
    .backgroundColor('#0b0e15')
  }
}
