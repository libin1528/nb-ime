# 在 ITX 上把 CapsWriter 服务端注册成「登录后自动启动、后台运行」的计划任务，并立即启动。
# 用法（在 ITX 上，以部署用户身份打开管理员 PowerShell）：powershell -NoProfile -File install-autostart.ps1
#Requires -RunAsAdministrator
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$dir = Join-Path $env:USERPROFILE "CapsWriter-Offline"   # 解压的位置不一样就改这里
$user = "$env:USERDOMAIN\$env:USERNAME"

# IFEO 按映像名生效：本项目主进程与识别子进程都叫 start_server.exe，不对 python.exe 等通用名设置。
# CpuPriorityClass 的 6 = AboveNormal，与计划任务的 Priority 2 是两套编号。
# 只设置这一项，重复执行不影响 PerfOptions 中其它值；写入失败时不停止现有服务。
if (-not (Test-Path "$dir\start_server.exe" -PathType Leaf)) { throw "没找到 $dir\start_server.exe" }
$perfOptions = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\start_server.exe\PerfOptions'
New-Item -Path $perfOptions -Force -ErrorAction Stop | Out-Null
New-ItemProperty -Path $perfOptions -Name CpuPriorityClass -PropertyType DWord -Value 6 -Force -ErrorAction Stop | Out-Null

Get-Process start_server -ErrorAction SilentlyContinue | Stop-Process -Force
$action = New-ScheduledTaskAction -Execute "$dir\start_server.exe" -WorkingDirectory $dir
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 5 `
    -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -Priority 2
# S4U：不弹控制台窗口，不打扰 ITX 桌面上的 Windows 自动化测试；Vulkan 在这种会话里照样能用显卡
# 任务 Priority 2 保持主进程高于正常；子进程由上面的 IFEO 补齐。CPU 优先级不保证内存驻留。
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType S4U -RunLevel Limited
Register-ScheduledTask -TaskName CapsWriterServer -Action $action -Trigger $trigger -Settings $settings `
    -Principal $principal -Description "CapsWriter 语音识别服务端（语音输入法 Mac 客户端用）" -Force | Out-Null
Start-ScheduledTask -TaskName CapsWriterServer
Start-Sleep 12
(Get-ScheduledTask -TaskName CapsWriterServer).State
Get-Content -Tail 4 -Encoding UTF8 "$dir\logs\server_latest.log"
