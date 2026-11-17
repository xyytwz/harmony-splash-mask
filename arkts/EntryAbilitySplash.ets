/**
 * harmony-splash-mask · EntryAbility 接入模板
 *
 * 这不是独立可编译文件：把下面的常量与成员方法并入你自己的 EntryAbility
 * （uni-app 鸿蒙工程：继承 UniEntryAbility；纯鸿蒙工程：继承 UIAbility）。
 *
 * 为什么要改 EntryAbility：遮罩子窗口必须在 onWindowStageCreate 中、且在
 * super.onWindowStageCreate 之前发起（fire-and-forget）——只有这里能赶在系统门帘
 * 移除之前把遮罩画出来。这是整个方案唯一无法被插件自动化的一步。
 */
import window from '@ohos.window';
import display from '@ohos.display';
import { hilog } from '@kit.PerformanceAnalysisKit';
import Want from '@ohos.app.ability.Want';
import AbilityLaunchParam from '@ohos.app.ability.AbilityLaunchParam';

const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'SplashMask';
// 与 SplashWindowPage.ets 中的 SPLASH_WINDOW_NAME 逐字一致
const SPLASH_WINDOW_NAME = 'splash_mask_window';
const SPLASH_PAGE_PATH = 'pages/SplashWindowPage';
// 启动页顶色：与 startIcon 素材顶部渐变色一致（门帘移除瞬间遮罩未就绪时的兜底色）
const SPLASH_BG_COLOR = '#FFDCF3F8';

// ================= 生命周期 =================

onCreate(want: Want, launchParam: AbilityLaunchParam.LaunchParam): void {
  // —— uni-app 鸿蒙工程：注入 JS → 原生桥，JS 侧调 uni.closeSplashMask() ——
  // 重复调用无害（SplashWindowPage 内 closing 标志幂等防重）
  Reflect.set(uni, 'closeSplashMask', (): void => {
    AppStorage.setOrCreate('splashMaskClose', 1);
  });
  // —— 纯鸿蒙工程：不需要桥，直接 AppStorage.setOrCreate('splashMaskClose', 1) 即可 ——
}

onWindowStageCreate(windowStage: window.WindowStage): void {
  // 1. 遮罩子窗口：提前到 super 之前发起（fire-and-forget），赶在门帘移除前画出来
  this.openSplashWindow(windowStage);
  // 2. uni-app 工程：super 是 UniEntryAbility 的 runtime 启动；纯鸿蒙工程改为 super.onWindowStageCreate(windowStage)
  super.onWindowStageCreate(windowStage);
  // 3. 主窗口底色轮询重试（入场转场动画期单次设置必失败，作为门帘移除瞬间的兜底层）
  this.retryMainBg(windowStage, 1);
}

onWindowStageDestroy(): void {
  // 兜底收口：页面内 destroySelf 因异常未执行时，销毁期再补一次
  try {
    const w = window.findWindow(SPLASH_WINDOW_NAME);
    if (w) {
      w.destroyWindow();
    }
  } catch (e) {
    // 窗口不存在时抛异常，属正常（已销毁），吞掉
  }
}

// ================= 启动遮罩 =================

private async openSplashWindow(windowStage: window.WindowStage): Promise<void> {
  try {
    // 注意：resize 不能用主窗口 windowRect——onWindowStageCreate 正逢系统入场转场动画，
    // windowRect 是动画中间态的小矩形，会把遮罩开小导致四周露黑。必须用物理屏宽高。
    const d = display.getDefaultDisplaySync();
    const sub = await windowStage.createSubWindow(SPLASH_WINDOW_NAME);
    await sub.resize(d.width, d.height);
    await sub.moveWindowTo(0, 0);
    await sub.loadContent(SPLASH_PAGE_PATH);
    // 子窗口底色必须在 loadContent 之后、showWindow 之前设置：
    // loadContent 前调用会报 1300002（uiContent is null）静默失败，底色默认白
    try {
      await sub.setWindowBackgroundColor(SPLASH_BG_COLOR);
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'sub bg set failed: %{public}s', (e as Error).message);
    }
    await sub.showWindow();
    hilog.info(LOG_DOMAIN, LOG_TAG, 'splash window opened');
  } catch (e) {
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'openSplashWindow failed: %{public}s', (e as Error).message);
  }
}

private retryMainBg(windowStage: window.WindowStage, attempt: number): void {
  // 主窗口底色：入场转场动画期 setWindowBackgroundColor 报 1300002（window state abnormal），
  // 轮询重试跨过动画期后设上启动页顶色——门帘移除瞬间若遮罩未就绪，露出的是顶色而不是白色
  windowStage.getMainWindow().then((mainWindow: window.Window) => {
    try {
      mainWindow.setWindowBackgroundColor(SPLASH_BG_COLOR);
      hilog.info(LOG_DOMAIN, LOG_TAG, 'main bg set ok (attempt %{public}d)', attempt);
    } catch (err) {
      if (attempt < 40) {
        setTimeout(() => this.retryMainBg(windowStage, attempt + 1), 5);
      }
    }
  }).catch(() => {
    if (attempt < 40) {
      setTimeout(() => this.retryMainBg(windowStage, attempt + 1), 5);
    }
  });
}
