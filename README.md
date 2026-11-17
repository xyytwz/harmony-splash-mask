# harmony-splash-mask

鸿蒙 APP 冷启动零白屏方案：**系统门帘（startIcon）与原生 ArkUI 子窗口遮罩使用同一张图**，两层逐像素一致、交接零跳动，配合主窗口底色轮询兜底与双信号竞速撤除，真机实测冷启动全程白屏占比 0%，比安卓端原生启动图方案还要丝滑。

适用于：**uni-app 打包鸿蒙 APP**（`app-harmony` 工程）与**纯鸿蒙原生工程**。

## 为什么会有白屏

鸿蒙冷启动的呈现链路：

```
进程启动 → 系统门帘（startIcon）→ 主窗口首帧 → 页面渲染
```

门帘移除的时机是**主窗口首帧就绪**，早于 webview/页面完成绘制，于是出现三段问题：

1. 门帘消失 → 页面未绘制：**白屏空档**；
2. 门帘与遮罩/页面交接：两套绘制逐像素差异 → **"微调对齐"跳动**；
3. 遮罩淡出 → 最终页未上屏：**淡出露白**。

官方 `startWindowBackground` 只支持纯色，做不了渐变整图；uni-app 内置启动图本质是 webview 内容，盖不住空档。

## 核心思路：不问"用什么盖白屏"，问"能不能让两边一样"

系统门帘显示的 `startIcon` 恰好支持整图等比铺满（竖版渐变启动图 884x1970 实测在手机上边到边、无蒙版裁切）。与其让遮罩去适配门帘，**不如让遮罩和门帘直接是同一张图**——两层逐像素一致，交接时理论上就不存在任何变化。

```
onWindowStageCreate
  ├─ openSplashWindow（提前到 super 之前发起，fire-and-forget）
  │    ├─ createSubWindow('splash_mask_window') + resize(物理屏宽高) + moveWindowTo(0,0)
  │    ├─ loadContent(SplashWindowPage)          ← 同一张 startIcon，Cover + syncLoad
  │    ├─ setWindowBackgroundColor（顶色，须在 loadContent 之后）
  │    └─ showWindow
  └─ super.onWindowStageCreate（runtime 启动）

页面就绪 → closeSplashMask() → AppStorage → @Watch → 160ms 淡出 → destroyWindow
```

三个关键设计：

1. **同源单图**：遮罩页渲染与门帘同一资源 `startIcon`，`ImageFit.Cover` + `syncLoad(true)`——
   syncLoad 同步解码保证首次冷启（解码无缓存）首帧 buffer 即含完整内容，不闪白；
2. **主窗口底色轮询重试**：入场转场动画期 `setWindowBackgroundColor` 必报 1300002，
   5ms × 40 次重试跨过动画期设上顶色——门帘移除瞬间若遮罩未就绪，露出的是顶色不是白色；
3. **双信号竞速撤遮罩**：未登录路径挂登录页 `onReady`、已登录路径挂首页数据就绪，
   谁先到谁撤（幂等防重）——每条路径都等**自己的最终页**上屏后才淡出，露白机制性消除。

## 快速接入（uni-app 鸿蒙工程）

### 第 1 步：烘焙启动图素材

准备一张**透明底**前景 PNG（logo/插画/文案），运行脚本合成渐变整图：

```powershell
powershell -ExecutionPolicy Bypass -File scripts/bake_splash.ps1 `
  -Foreground .\brand_foreground.png -Out .\startIcon.png
```

把输出改名为 `startIcon.png` 放入 `AppScope/resources/base/media/`。
同时把 `AppScope/resources/base/element/color.json` 的 `start_window_background` 改为渐变顶色。

> 素材要求：宽高比接近主流手机屏（默认 884x1970 ≈ 1:2.23）。门帘在手机上是等比铺满整屏；
> tablet/2in1 等非手机比例可能留边或轻微裁切，应用内遮罩 Cover 会很快接管。

### 第 2 步：加入遮罩页

复制 `arkts/SplashWindowPage.ets` 到 `entry/src/main/ets/pages/`，
并在 `entry/src/main/resources/base/profile/main_pages.json` 注册：

```json
{ "src": ["pages/Index", "pages/SplashWindowPage"] }
```

### 第 3 步：并入 EntryAbility 模板

把 `arkts/EntryAbilitySplash.ets` 中的常量与成员方法并入你的 `EntryAbility`
（uni-app 工程：继承 `UniEntryAbility`）。要点：

- `openSplashWindow(windowStage)` 调用必须放在 **`super.onWindowStageCreate` 之前**；
- `SPLASH_BG_COLOR` 与你的渐变顶色保持一致；
- 纯鸿蒙工程：去掉 `uni` 桥注入，改用 `AppStorage.setOrCreate('splashMaskClose', 1)` 直发信号。

### 第 4 步：uni-app 侧挂撤除信号

参考 `uni-app/splash-close-signals.vue.snippet`，在**每条启动路径的最终页**挂信号
（`#ifdef APP-HARMONY` 条件编译隔离）：

- 未登录路径最终页（如登录页）：`onReady` + 50ms 调 `uni.closeSplashMask()`；
- 已登录路径最终页（如首页）：首屏数据就绪 + 250ms 调 `uni.closeSplashMask()`；
- 只有一条启动路径时，只挂那一条即可。

### 第 5 步：真机验证

```bash
hdc shell "hilog | grep --line-buffered -E 'SplashMask|NotifyCompleteFirstFrameDrawing|subWindowBufferAvailable' > /data/local/tmp/splash.log"
# 冷启若干次后拉回日志，核对：门帘移除（NotifyCompleteFirstFrameDrawing）
# 与遮罩首帧（subWindowBufferAvailable）的时间差应 ≤ 16ms（一帧）
```

## 排查工具与五轮根因（为什么会有这五处坑）

取证方法：hilog **设备端** grep 过滤落盘（主机端缓冲区会被其他 App 日志刷屏轮转），
`hdc snapshot_display` 带时间戳连拍 + 顶部白屏占比分析。

| 轮 | 现象 | 根因 | 修复 |
|---|---|---|---|
| 1 | 遮罩四周黑边 | 入场转场动画期主窗口 windowRect 是动画中间态小矩形，据此 resize 开小了 | resize 用 `display.getDefaultDisplaySync()` 物理屏宽高 |
| 2 | 门帘→遮罩交接 35ms 白闪 | `setWindowBackgroundColor` 在 loadContent 前调用报 1300002 **静默失败**；门帘移除早于遮罩首帧约 35ms | 底色挪到 loadContent 之后；主窗口底色轮询重试兜底。竞态压到 2~6ms |
| 3 | "微调对齐"跳动 + 首次冷启闪白 | 遮罩与门帘两套独立绘制逐像素差异；Image 异步解码无缓存 | startIcon 同源单图 Cover + `syncLoad(true)` |
| 4 | 撤遮罩露白 | 信号挂首页数据就绪，未登录路径最终页（登录页）上屏更晚 | 双信号竞速取先到 |
| 5 | 启动页偏久 | 撤除链路延时与淡出 | 首页延时 250ms + 淡出 160ms（实测 100ms 会露白） |

## 参数表

| 参数 | 值 | 位置 | 说明 |
|---|---|---|---|
| 登录页信号延时 | 50ms | uni-app 片段 | 已上屏即撤，无网络依赖 |
| 首页信号延时 | 250ms | uni-app 片段 | 覆盖首页图片/组件上屏；100ms 会露白 |
| 淡出时长 | 160ms / EaseIn | SplashWindowPage | 首页很重可改回 260ms |
| 安全兜底 | 4s | SplashWindowPage | JS 信号丢失也不困住用户 |
| 主窗口底色重试 | 5ms × 40 次 | EntryAbility 模板 | 跨过入场转场动画期 |

## 已知边界

- tablet/2in1 等非手机比例下门帘 startIcon 可能留边或轻微裁切，应用内遮罩 Cover 会很快接管；
- 门帘期（进程启动 + runtime 首帧约 1s）与 webview 加载期属架构固有成本，压缩空间在撤除延时与淡出时长；
- `setWindowBackgroundColor` 返回 void，不可链式 `.catch`，请用 try/catch；`getMainWindowSync` 调用过早报 1300002，须用 `getMainWindow().then` + 重试。

## 博文

实战全过程复盘（含 AI 方案对比与人机协作方法论）：

- 博客园：https://www.cnblogs.com/xyyt/p/23696775
- 掘金：https://juejin.cn/post/7708953356711133219

## License

[MIT](./LICENSE)
