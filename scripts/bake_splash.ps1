# harmony-splash-mask · 启动图素材烘焙脚本
# 用途：把"渐变背景 + 透明底前景图"合成为启动整图（startIcon.png）。
#       系统门帘与原生遮罩页使用同一张图（等比铺满整屏），保证两层逐像素一致。
# 前提：Foreground 必须是【透明底】PNG。若不确定，脚本会自动采样四角 alpha 提示。
# 用法示例：
#   powershell -ExecutionPolicy Bypass -File bake_splash.ps1 -Foreground .\brand_foreground.png -Out .\startIcon.png
param(
  [Parameter(Mandatory = $true)][string]$Foreground,   # 透明底前景图（logo/插画/文案）
  [string]$Out = "$PWD\startIcon.png",                 # 输出路径（建议直接命名 startIcon.png）
  [int]$Width = 884,                                   # 画布宽：与主流手机屏比例接近（1:2.23）
  [int]$Height = 1970,                                 # 画布高：门帘在手机上按比例等比铺满整屏
  [string]$TopColor = '#DCF3F8',                       # 渐变顶色（与 AppScope color.json 的 start_window_background 一致）
  [string]$MidColor = '#E9F7FB',                       # 渐变中间色
  [string]$BottomColor = '#FFFFFF',                    # 渐变底色
  [double]$MidStop = 0.55                              # 中间色停靠位置（0~1）
)
Add-Type -AssemblyName System.Drawing
$ErrorActionPreference = 'Stop'

# 1. alpha 校验：透明底素材直接 source-over 叠加；白底素材会被压黑，须先抠透明
$fg = [System.Drawing.Bitmap]::FromFile($Foreground)
$samples = @(
  $fg.GetPixel(0, 0), $fg.GetPixel($fg.Width - 1, 0),
  $fg.GetPixel(0, $fg.Height - 1), $fg.GetPixel($fg.Width - 1, $fg.Height - 1)
)
$alphaSum = ($samples | ForEach-Object { $_.A } | Measure-Object -Sum).Sum
if ($alphaSum -gt 0) {
  Write-Warning "前景图四角 alpha 不为 0（可能是白底图）。白底请先抠透明，否则会盖住渐变或整体压黑。"
  Write-Warning ("四角 A 值: " + (($samples | ForEach-Object { $_.A }) -join ', '))
}

# 2. 铺垂直渐变（多停靠点让过渡更接近设计稿）
$canvas = New-Object System.Drawing.Bitmap($Width, $Height)
$g = [System.Drawing.Graphics]::FromImage($canvas)
$rect = New-Object System.Drawing.Rectangle(0, 0, $Width, $Height)
$brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, [System.Drawing.Color]::White, [System.Drawing.Color]::White, 90)
$blend = New-Object System.Drawing.Drawing2D.ColorBlend
$blend.Colors = @(
  [System.Drawing.ColorTranslator]::FromHtml($TopColor),
  [System.Drawing.ColorTranslator]::FromHtml($MidColor),
  [System.Drawing.ColorTranslator]::FromHtml($BottomColor)
)
$blend.Positions = @(0.0, [float]$MidStop, 1.0)
$brush.InterpolationColors = $blend
$g.FillRectangle($brush, $rect)

# 3. 前景图居中等比缩放后按 alpha 正常叠加（source-over，勿用 multiply）
$scale = [Math]::Min(($Width * 0.86) / $fg.Width, ($Height * 0.74) / $fg.Height)
$dw = [int]($fg.Width * $scale); $dh = [int]($fg.Height * $scale)
$dx = [int](($Width - $dw) / 2);  $dy = [int](($Height - $dh) / 2)
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$g.DrawImage($fg, $dx, $dy, $dw, $dh)

$g.Dispose(); $brush.Dispose(); $fg.Dispose()
$canvas.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$canvas.Dispose()
Write-Host "OK -> $Out ($Width x $Height)" -ForegroundColor Green
Write-Host "下一步：把输出图改名为 startIcon.png 放入 AppScope/resources/base/media/，并同步 SplashWindowPage.ets 的 backgroundColor 为 $TopColor"
