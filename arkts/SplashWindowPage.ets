/**
 * harmony-splash-mask · 遮罩页
 *
 * 由宿主 EntryAbility 创建一个与主窗口等大、盖在其上的全屏子窗口并加载本页。
 * 原生 ArkUI 首帧即绘，遮住 webview 冷启动的白屏空档。
 *
 * 核心设计：遮罩页直接复用系统门帘同一资源 startIcon（等比铺满整屏），
 * 两层逐像素一致，门帘 → 遮罩交接零跳动；syncLoad 同步解码保证首次冷启
 * （图片解码无缓存）首帧 buffer 即含完整内容，不闪白。
 *
 * JS 侧就绪后调 uni.closeSplashMask()（或直接置 AppStorage）→ 本页 160ms 淡出并销毁子窗口。
 */
import window from '@ohos.window';
import { hilog } from '@kit.PerformanceAnalysisKit';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'SplashMask';
// 与宿主 EntryAbility 中 createSubWindow 的窗口名逐字一致，销毁时按名查找。
const SPLASH_WINDOW_NAME = 'splash_mask_window';

@Entry
@Component
struct SplashWindowPage {
  // 整页淡出：撤遮罩时先透明再销毁窗口。
  // 注意：内容层不要做淡入——门帘与遮罩是同一张图，首帧即全显才能无缝交接，
  // 内容从透明淡入会造成门帘 → 遮罩交接时"中间闪一下"。
  @State rootOpacity: number = 1;
  // 原生/JS 关闭信号：EntryAbility 收到 uni.closeSplashMask() 后把该全局存储置 1
  @StorageProp('splashMaskClose') @Watch('onCloseSignal') closeFlag: number = 0;
  private closing: boolean = false;
  private safetyTimer: number = -1;

  aboutToAppear(): void {
    // 兜底：极端情况下 JS 就绪信号丢失（如首页异常），4s 后自动撤遮罩，绝不困住用户
    this.safetyTimer = setTimeout(() => {
      this.doClose();
    }, 4000);
    // 信号可能早于本页创建（首页极快就绪）：此时 @Watch 不会在初始化触发，主动补判一次
    if (this.closeFlag > 0) {
      this.doClose();
    }
  }

  onCloseSignal(): void {
    if (this.closeFlag > 0) {
      this.doClose();
    }
  }

  doClose(): void {
    if (this.closing) {
      return;
    }
    this.closing = true;
    if (this.safetyTimer >= 0) {
      clearTimeout(this.safetyTimer);
      this.safetyTimer = -1;
    }
    this.getUIContext().animateTo({
      // 160ms 快速淡出：压缩启动页尾段时长；EaseIn 前段透明度变化缓，底部页面上屏窗口仍足够。
      // 实测若撤除过早（底部页未上屏）会露白：uni 侧应等"最终可见目标页"就绪后再发信号。
      duration: 160,
      curve: Curve.EaseIn,
      onFinish: () => {
        this.destroySelf();
      }
    }, () => {
      this.rootOpacity = 0;
    });
  }

  destroySelf(): void {
    try {
      const w = window.findWindow(SPLASH_WINDOW_NAME);
      if (w) {
        w.destroyWindow().then(() => {
          hilog.info(LOG_DOMAIN, LOG_TAG, 'splash window destroyed');
        }).catch((e: Error) => {
          hilog.warn(LOG_DOMAIN, LOG_TAG, 'destroyWindow failed: %{public}s', e.message);
        });
      }
    } catch (e) {
      // findWindow 在窗口不存在时抛异常，属正常（重复关闭），吞掉
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'destroySelf: %{public}s', (e as Error).message);
    }
  }

  build() {
    Stack() {
      // 与系统门帘(startIcon)同一资源、同一排版：门帘把这张整图等比铺满整屏（边到边），
      // 遮罩用同图 Cover 铺满后两层逐像素一致，交接时不再有任何"对不齐"的跳动。
      // syncLoad 同步解码：首帧 buffer 就绪时图已就绪——第一次冷启（图片解码无缓存）
      // 不会再出现"门帘有内容 → 遮罩先纯底色 → 内容才出现"的闪白。
      Image($r('app.media.startIcon'))
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
        .syncLoad(true)
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Center)
    .backgroundColor('#DCF3F8') // 遮罩底色：与启动图顶色一致，改了素材请同步改这里
    .opacity(this.rootOpacity)
  }
}
