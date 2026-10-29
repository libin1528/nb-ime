# 在 ITX 上把「识别后润色」用的小模型注册成「登录后自动启动、后台运行」的计划任务，并立即启动。
# 用的是 CapsWriter 自带的 llama-server（Vulkan 版），模型放在用户目录下的 nb-llm\。
# 用法（在 ITX 上，以登录用户身份）：powershell -NoProfile -File install-polish.ps1
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$bin = Join-Path $env:USERPROFILE "CapsWriter-Offline\core\server\engines\llama\bin\llama-server.exe"
$dir = Join-Path $env:USERPROFILE "nb-llm"   # 模型放的位置不一样就改这里
$model = "Qwen3.5-4B-Q8_0.gguf"
$user = "$env:COMPUTERNAME\$env:USERNAME"   # 经 ssh 跑时 USERDOMAIN 是 WORKGROUP，解析不出账户

# 只听本机，客户端走 ssh 隧道；-np 1 一次一句；--no-mmap 权重整份进显存，不占着内存；
# --reasoning-budget 0 关掉思考，整理文字用不着
$argline = "-m `"$dir\$model`" --host 127.0.0.1 --port 6017 -ngl 99 -c 4096 -np 1 --jinja --reasoning-budget 0 " +
        "--no-webui --no-mmap --log-file `"$dir\server.log`""
Stop-ScheduledTask -TaskName NBPolishLLM -ErrorAction SilentlyContinue
$action = New-ScheduledTaskAction -Execute $bin -Argument $argline -WorkingDirectory $dir
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 5 `
    -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType S4U -RunLevel Limited
Register-ScheduledTask -TaskName NBPolishLLM -Action $action -Trigger $trigger -Settings $settings `
    -Principal $principal -Description "NB 输入法识别后润色用的小模型（llama-server + Qwen3.5-4B）" -Force | Out-Null
Start-ScheduledTask -TaskName NBPolishLLM
Start-Sleep 15
(Get-ScheduledTask -TaskName NBPolishLLM).State
try { (Invoke-WebRequest -UseBasicParsing http://127.0.0.1:6017/health).Content } catch { "还没起来：$_" }
