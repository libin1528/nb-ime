# 在 ITX 上把 CapsWriter 服务端注册成「登录后自动启动、后台运行」的计划任务，并立即启动。
# 用法（在 ITX 上，以登录用户身份）：powershell -NoProfile -File install-autostart.ps1
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$dir = "C:\Users\qyqx1\CapsWriter-Offline"
$user = "$env:USERDOMAIN\$env:USERNAME"

Get-Process start_server -ErrorAction SilentlyContinue | Stop-Process -Force
$action = New-ScheduledTaskAction -Execute "$dir\start_server.exe" -WorkingDirectory $dir
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 5 `
    -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
# S4U：不弹控制台窗口，不打扰 ITX 桌面上的 Windows 自动化测试；Vulkan 在这种会话里照样能用显卡
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType S4U -RunLevel Limited
Register-ScheduledTask -TaskName CapsWriterServer -Action $action -Trigger $trigger -Settings $settings `
    -Principal $principal -Description "CapsWriter 语音识别服务端（语音输入法 Mac 客户端用）" -Force | Out-Null
Start-ScheduledTask -TaskName CapsWriterServer
Start-Sleep 12
(Get-ScheduledTask -TaskName CapsWriterServer).State
Get-Content -Tail 4 -Encoding UTF8 "$dir\logs\server_latest.log"
