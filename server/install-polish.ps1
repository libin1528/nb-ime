# 在 ITX 上把「识别后润色」用的小模型注册成「登录后自动启动、后台运行」的计划任务，并立即启动。
# 用的是 CapsWriter 自带的 llama-server（Vulkan 版），模型放在用户目录下的 nb-llm\。
# 用法（在 ITX 上，以登录用户身份）：powershell -NoProfile -File install-polish.ps1
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$bin = Join-Path $env:USERPROFILE "CapsWriter-Offline\core\server\engines\llama\bin\llama-server.exe"
$dir = Join-Path $env:USERPROFILE "nb-llm"   # 模型放的位置不一样就改这里
$model = "Qwen3.5-4B-Q8_0.gguf"
$user = "$env:COMPUTERNAME\$env:USERNAME"   # 经 ssh 跑时 USERDOMAIN 是 WORKGROUP，解析不出账户

# 只听本机，客户端走 ssh 隧道；-np 1 一次一句；--no-mmap 权重整份进显存，不占着内存；
# --reasoning-budget 0 关掉思考，整理文字用不着；这版 llama.cpp 配 Qwen3.5 不认它，照样先想（一句 15 秒），
# 所以再用 --chat-template-kwargs 默认关掉。NB 客户端每次请求自己也带 enable_thinking:false；
# ClawChat 的语音输入发的是通用 OpenAI 请求、带不了这个字段，靠这里（2026-11-03）
$argline = "-m `"$dir\$model`" --host 127.0.0.1 --port 6017 -ngl 99 -c 4096 -np 1 --jinja --reasoning-budget 0 " +
        "--chat-template-kwargs `"{\`"enable_thinking\`":false}`" " +
        "--no-webui --no-mmap --log-file `"$dir\server.log`""
Stop-ScheduledTask -TaskName NBPolishLLM -ErrorAction SilentlyContinue
$action = New-ScheduledTaskAction -Execute $bin -Argument $argline -WorkingDirectory $dir
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 5 `
    -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -Priority 2
# 优先级 2 = 高于正常。不写的话计划任务默认 7（低于正常）：CPU 抢不过别的程序，内存也最先被换出去，ITX 一忙识别就慢（10-29 查出来的）
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType S4U -RunLevel Limited
Register-ScheduledTask -TaskName NBPolishLLM -Action $action -Trigger $trigger -Settings $settings `
    -Principal $principal -Description "NB 输入法识别后润色用的小模型（llama-server + Qwen3.5-4B）" -Force | Out-Null
Start-ScheduledTask -TaskName NBPolishLLM
Start-Sleep 15
(Get-ScheduledTask -TaskName NBPolishLLM).State
try { (Invoke-WebRequest -UseBasicParsing http://127.0.0.1:6017/health).Content } catch { "还没起来：$_" }
