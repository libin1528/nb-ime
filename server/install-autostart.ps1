[Console]::OutputEncoding = [Text.Encoding]::UTF8
Get-Process start_server -ErrorAction SilentlyContinue | Stop-Process -Force
$t = Get-ScheduledTask -TaskName ClawChatWinrigAgent
"agent principal: " + $t.Principal.UserId + " logon=" + $t.Principal.LogonType + " run=" + $t.Principal.RunLevel
$dir = "C:\Users\qyqx1\CapsWriter-Offline"
$action = New-ScheduledTaskAction -Execute "$dir\start_server.exe" -WorkingDirectory $dir
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $t.Principal.UserId
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId $t.Principal.UserId -LogonType S4U -RunLevel Limited
Register-ScheduledTask -TaskName CapsWriterServer -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description "CapsWriter 语音识别服务端（Mac 上的 ITX 语音输入用）" -Force | Out-Null
Start-ScheduledTask -TaskName CapsWriterServer
Start-Sleep 12
(Get-ScheduledTask -TaskName CapsWriterServer).State
Get-Process start_server -ErrorAction SilentlyContinue | ForEach-Object { $_.Id.ToString() + " session=" + $_.SessionId + " " + [math]::Round($_.WorkingSet64/1MB) + "MB" }
Get-NetTCPConnection -LocalPort 6016 -State Listen -ErrorAction SilentlyContinue | ForEach-Object { "listen " + $_.LocalAddress }
Get-Content -Tail 4 -Encoding UTF8 "$dir\logs\server_latest.log"
