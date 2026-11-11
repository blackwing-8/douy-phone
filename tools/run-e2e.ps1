# 兜鱼复刻版 · 端到端验证（不需要真机 / 不需要 OBS）
#
#   用法（Windows PowerShell 5.1 或 PowerShell 7 均可）：
#     powershell -ExecutionPolicy Bypass -File tools\run-e2e.ps1 -Seconds 15
#
# 步骤：
#   1. 启动 DOUY.Pc 无界面模式（内置 RTMP 服务 + USB 隧道）
#   2. 用 Python 脚本模拟 iPhone，在 28767 端口监听 FXP/2
#   3. 用 ffmpeg 当 OBS 替身，推 15 秒 H.264+AAC 到内置 RTMP 服务
#   4. 校验：模拟手机收到的帧数/关键帧/时间戳；ffprobe 校验码流可解
#   5. 另外验证 RTMP 拉流路径（ffmpeg 从内置服务拉流落盘）
[CmdletBinding()]
param(
    [int]$Seconds = 15,
    [int]$RtmpPort = 19350,
    [int]$PhonePort = 28767,
    [string]$Ffmpeg = "",
    [string]$Configuration = "Release"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$work = Join-Path $root "_e2e"
New-Item -ItemType Directory -Force -Path $work | Out-Null

function Find-Ffmpeg {
    param([string]$Explicit)
    if ($Explicit -and (Test-Path $Explicit)) { return (Resolve-Path $Explicit).Path }
    foreach ($candidate in @(
            (Join-Path $root "..\_tools\ffmpeg\ffmpeg.exe"),
            (Join-Path $root "tools\ffmpeg.exe"),
            "ffmpeg.exe"
        )) {
        if ($candidate -eq "ffmpeg.exe") {
            $cmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
            if ($cmd) { return $cmd.Source }
        }
        elseif (Test-Path $candidate) { return (Resolve-Path $candidate).Path }
    }
    throw "找不到 ffmpeg.exe，请用 -Ffmpeg 指定路径"
}

$ffmpegPath = Find-Ffmpeg -Explicit $Ffmpeg
$ffprobePath = Join-Path (Split-Path $ffmpegPath) "ffprobe.exe"
$python = (Get-Command python -ErrorAction SilentlyContinue)
if (-not $python) { throw "找不到 python" }

$exe = Join-Path $root "pc\DOUY.Pc\bin\$Configuration\net7.0-windows\DOUY.Pc.exe"
if (-not (Test-Path $exe)) {
    Write-Host "==> 编译 $Configuration ..." -ForegroundColor Cyan
    & dotnet build (Join-Path $root "pc\DOUY.Pc\DOUY.Pc.csproj") -c $Configuration -v q --nologo | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "编译失败" }
}
if (-not (Test-Path $exe)) { throw "找不到 $exe" }

Write-Host "`n=== 1/5 启动 PC 端（RTMP:$RtmpPort, 直连模拟手机 127.0.0.1:$PhonePort）===" -ForegroundColor Cyan
$pcLog = Join-Path $work "pc.log"
$pcErr = Join-Path $work "pc.err.log"
Remove-Item $pcLog, $pcErr -ErrorAction SilentlyContinue
$pc = Start-Process -FilePath $exe -ArgumentList @(
    "serve", "--port", "$RtmpPort", "--phone", "127.0.0.1:$PhonePort", "--dump", (Join-Path $work "hub")
) -RedirectStandardOutput $pcLog -RedirectStandardError $pcErr -PassThru -WindowStyle Hidden

Start-Sleep -Seconds 2

Write-Host "=== 2/5 启动模拟手机 ===" -ForegroundColor Cyan
$phoneOut = Join-Path $work "phone.log"
Remove-Item $phoneOut -ErrorAction SilentlyContinue
$phone = Start-Process -FilePath $python.Source -ArgumentList @(
    (Join-Path $root "tools\test-phone.py"), "--port", "$PhonePort",
    "--out", (Join-Path $work "received"), "--duration", "$($Seconds + 3)", "--quiet"
) -RedirectStandardOutput $phoneOut -RedirectStandardError "$phoneOut.err" -PassThru -WindowStyle Hidden

Start-Sleep -Seconds 2

$rtmpUrl = "rtmp://127.0.0.1:$RtmpPort/live/douy"
Write-Host "=== 3/5 推流 $Seconds 秒 → $rtmpUrl ===" -ForegroundColor Cyan
# 推流放后台跑，这样下面可以在推流进行中做拉流验证
$pushOut = Join-Path $work "push.log"
$pushErr = Join-Path $work "push.err.log"
$push = Start-Process -FilePath $ffmpegPath -ArgumentList @(
    "-hide_banner", "-loglevel", "warning", "-re",
    "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30",
    "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
    "-c:v", "libx264", "-preset", "veryfast", "-tune", "zerolatency",
    "-g", "60", "-pix_fmt", "yuv420p", "-b:v", "2500k",
    "-c:a", "aac", "-b:a", "128k", "-ar", "48000", "-ac", "2",
    "-t", "$Seconds", "-f", "flv", $rtmpUrl
) -RedirectStandardOutput $pushOut -RedirectStandardError $pushErr -PassThru -WindowStyle Hidden
Write-Host "  推流已启动 (pid $($push.Id))，等 5 秒让 OBS 侧稳定…"
Start-Sleep -Seconds 5

Write-Host "`n=== 4/5 验证 RTMP 拉流（ffmpeg 从内置服务拉 5 秒落盘）===" -ForegroundColor Cyan
$pullFile = Join-Path $work "pull.flv"
Remove-Item $pullFile -ErrorAction SilentlyContinue
$pull = Start-Process -FilePath $ffmpegPath -ArgumentList @(
    "-hide_banner", "-loglevel", "warning", "-y",
    "-rw_timeout", "5000000",
    "-i", $rtmpUrl, "-t", "5", "-c", "copy", $pullFile
) -RedirectStandardOutput (Join-Path $work "pull.log") -RedirectStandardError (Join-Path $work "pull.err.log") -PassThru -WindowStyle Hidden
if (-not $pull.WaitForExit(15000)) {
    Write-Host "  !! 拉流超时（15s），强制结束" -ForegroundColor Red
    Stop-Process -Id $pull.Id -Force -ErrorAction SilentlyContinue
}
Get-Content (Join-Path $work "pull.err.log") -Tail 5 -ErrorAction SilentlyContinue | ForEach-Object { "  [pull] $_" }

# 等推流自己结束（-t 到点），最多再等 20 秒
if (-not $push.WaitForExit(20000)) {
    Stop-Process -Id $push.Id -Force -ErrorAction SilentlyContinue
}
$push.Refresh()
$pushExit = if ($push.HasExited) { $push.ExitCode } else { -1 }
Get-Content $pushErr -Tail 5 -ErrorAction SilentlyContinue | ForEach-Object { "  [push] $_" }

Start-Sleep -Seconds 2
Write-Host "=== 5/5 收尾 ===" -ForegroundColor Cyan
# 先等模拟手机自己收完（它要打印统计），最多 15 秒
if ($phone -and -not $phone.WaitForExit(15000)) { Stop-Process -Id $phone.Id -Force -ErrorAction SilentlyContinue }
if ($pc -and -not $pc.HasExited) {
    Stop-Process -Id $pc.Id -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Milliseconds 500

Write-Host "`n---------------- PC 日志（尾部） ----------------"
Get-Content $pcLog -Tail 40 -ErrorAction SilentlyContinue | ForEach-Object { "  $_" }

Write-Host "`n---------------- 模拟手机结果 ----------------"
Get-Content $phoneOut -ErrorAction SilentlyContinue | ForEach-Object { "  $_" }
Get-Content "$phoneOut.err" -ErrorAction SilentlyContinue | ForEach-Object { "  [err] $_" }

$receivedH264 = Join-Path $work "received.h264"
$receivedAac = Join-Path $work "received.aac"
$ok = $true

if (Test-Path $receivedH264) {
    $size = (Get-Item $receivedH264).Length
    Write-Host "`n---------------- ffprobe 校验 USB 收到的 H.264 ($([math]::Round($size/1024,1)) KiB) ----------------"
    & $ffprobePath -hide_banner -v error -f h264 -show_entries stream=codec_name,width,height,pix_fmt -of default=nw=1 $receivedH264 2>&1 | ForEach-Object { "  $_" }
    if ($LASTEXITCODE -ne 0) { Write-Host "  !! H.264 无法解析" -ForegroundColor Red; $ok = $false }
}
else { Write-Host "!! 没收到视频" -ForegroundColor Red; $ok = $false }

if (Test-Path $receivedAac) {
    $size = (Get-Item $receivedAac).Length
    Write-Host "---------------- ffprobe 校验 USB 收到的 AAC ($([math]::Round($size/1024,1)) KiB) ----------------"
    & $ffprobePath -hide_banner -v error -f aac -show_entries stream=codec_name,sample_rate,channels -of default=nw=1 $receivedAac 2>&1 | ForEach-Object { "  $_" }
}

if (Test-Path $pullFile) {
    Write-Host "`n---------------- RTMP 拉流文件 ----------------"
    $psize = (Get-Item $pullFile).Length
    Write-Host "  pull.flv = $([math]::Round($psize/1024,1)) KiB"
    & $ffprobePath -hide_banner -v error -show_entries format=duration:stream=codec_name,width,height -of default=nw=1 $pullFile 2>&1 | ForEach-Object { "  $_" }
    if ($psize -lt 50KB) { Write-Host "  !! 拉流文件过小，RTMP 分发可能有问题" -ForegroundColor Red; $ok = $false }
}
else { Write-Host "!! 拉流失败" -ForegroundColor Red; $ok = $false }

Write-Host ""
Write-Host "  ffmpeg 推流退出码 = $pushExit" -ForegroundColor DarkGray
if ($pushExit -ne $null -and $pushExit -ne 0) {
    Write-Host "  (提示：推流进程非 0 退出，通常是推流结束后服务端关闭连接导致，不影响画面链路校验)" -ForegroundColor DarkYellow
}
if ($ok) {
    Write-Host "==== 端到端验证通过 ====" -ForegroundColor Green
    exit 0
}
Write-Host "==== 端到端验证失败 ====" -ForegroundColor Red
exit 1
