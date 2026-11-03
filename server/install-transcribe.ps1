# 在 ITX 上把 OpenAI 兼容的转写接口（transcribe_api.py，转给 CapsWriter 识别）注册成「登录后自动启动、后台运行」的计划任务，并立即启动。
# 给 ClawChat 的语音输入测试用，NB 输入法自己不走它。要先把 transcribe_api.py 和 ffmpeg.exe 放进用户目录下的 nb-transcribe\。
# 用法（在 ITX 上，以登录用户身份）：powershell -NoProfile -ExecutionPolicy Bypass -File install-transcribe.ps1
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$dir = Join-Path $env:USERPROFILE "nb-transcribe"   # 放的位置不一样就改这里
$user = "$env:COMPUTERNAME\$env:USERNAME"   # 经 ssh 跑时 USERDOMAIN 是 WORKGROUP，解析不出账户
# 要真的 python.exe，不要 WindowsApps 里那个跳去应用商店的占位
$py = Get-Command python.exe -All -ErrorAction SilentlyContinue | Where-Object { $_.Source -notmatch "WindowsApps" } | Select-Object -First 1 -ExpandProperty Source
if (-not $py) { throw "没找到 Python，先装 3.9 以上（只用标准库，不用 pip）" }
if (-not (Test-Path "$dir\ffmpeg.exe")) { throw "$dir\ffmpeg.exe 不在" }

# 只听本机，客户端走 ssh 隧道；识别服务在 6016
$argline = "`"$dir\transcribe_api.py`" --port 6018 --asr ws://127.0.0.1:6016 --ffmpeg `"$dir\ffmpeg.exe`" --log `"$dir\server.log`""
Stop-ScheduledTask -TaskName NBTranscribeAPI -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "Name='python.exe'" | Where-Object { $_.CommandLine -match "transcribe_api" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
$action = New-ScheduledTaskAction -Execute $py -Argument $argline -WorkingDirectory $dir
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 5 `
    -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -Priority 2
# 优先级 2 = 高于正常，和识别、润色两个任务一样（见 README「进程优先级」）
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType S4U -RunLevel Limited
Register-ScheduledTask -TaskName NBTranscribeAPI -Action $action -Trigger $trigger -Settings $settings `
    -Principal $principal -Description "OpenAI 兼容的转写接口，转给 CapsWriter（ClawChat 语音输入测试用）" -Force | Out-Null
Start-ScheduledTask -TaskName NBTranscribeAPI
Start-Sleep 3
(Get-ScheduledTask -TaskName NBTranscribeAPI).State
try { (Invoke-WebRequest -UseBasicParsing http://127.0.0.1:6018/v1/models).Content } catch { "还没起来：$_" }
