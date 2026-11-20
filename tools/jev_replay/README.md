# Jev 语音输入回放实验

在 Mac 测试机上生成并回放 20 条合成语音。题目包含虚构专名和中英混说。各组共用 `context.json` 中的词表与固定替换，包括公开的项目名称、仓库里的公开规则，以及用于这次实验的合成条目。两条合成规则取自首轮回放的实际错写，用来验证用户已有规则如何参与后续判断。标准答案只供评分。

| 组别 | 识别与处理 |
|---|---|
| 速度模式基线 | 实验开始时的 Apple SpeechTranscriber 参数，接现有固定替换、热词纠正和中档润色 |
| 苹果信号 | 加置信度和转写候选。低于 0.80 时标记，有候选高出 0.15 才替换 |
| 苹果信号 + Jev | 批量复核苹果提出的片段，可选一个原有识别候选。替换要求选择概率至少 0.75、置信度至少 0.55 |
| Jev 整句候选 | 每个候选分别代回整句，让 Jev 在完整版本之间选择 |
| Jev 挖空待判词 | 把待判片段换成空格，让 Jev 选择填入空格的候选 |
| Jev 补候选 | 保留 Apple 候选，在本机用现有热词表和通用同音词典补候选，再用现有 Jev 问法 |
| Jev 分词 + 整句复判 | 首次请求判断相邻字词间的边界，第二次在整句中判断切出来的词，并复核原候选 |

各组使用同一生产润色实现。候选替换使用 Apple 备选和所选实验组允许补充的词，并保护原文中已有的热词和固定替换位置。确认的候选进入现有润色流程。完全相同的润色输入共用单次实际测量。时间从模拟松键算起，包含 250 毫秒尾音、定稿、决策请求和润色，截止于结果可用。正式质量模式、UI 和系统粘贴的耗时需另行实测。

`--compare-prompts` 在每条录音上用同一份 Apple 定稿、同一组候选和同一套替换门槛跑三种问法。每组各发一次批量请求，逐句轮换请求顺序。整句和挖空问法把原转写移出请求的共用上下文，疑似错误题仍描述原片段。三组均完成的句子进入配对比较。耗时差逐句相减，再取中位数和 P95，以苹果信号组及现有 Jev 问法分别为基准。

`--with-candidate-expansion` 在同一份 Apple 定稿上比较原候选和补候选。现有汉字热词按不带声调的整词拼音匹配，英文热词与 Apple 写法做有限的拼写近似匹配。通用词典只补 Apple 已标出的汉字片段，按含声调的拼音查找，最多补三个高频同音词。已有热词与固定替换的保护照常应用。词典在计时前加载，每句实际查词的耗时算进松键等待。两组都在 Apple 定稿后请求 Jev，预览阶段没有发请求。

`preview.py` 按原来的速度重放同一批 PCM。Apple 每次产出预览就向评估器输出当时的全文和候选。键还按着且至少有一个候选替换时发真实 Jev 请求，每句最多四次，同时最多两次。定稿后，只有全文、片段位置、候选内容和顺序都一致，才复用同一句在松键前发出的请求。Apple 基础判断和最终替换仍以定稿为准。版本不匹配时立即发定稿请求，丢弃过期的回复。串行组与这类回退共用同一笔定稿请求的实际测量。有可复用结果时，串行组另发真实的定稿请求。`preview-results.json` 记录每句的预览事件、请求时间、复用或回退原因及配对结果。

`preview.py --by-segment` 让两组使用相同的片段问法和补候选规则。在原有 Apple 片段外，用分词器找可查同音词的汉字词，并用完整拉丁词补英文热词，因此预览没有 Apple 备选时也能开始查词。每道题只看待判词和左右各三个记号，汉字按字、连续英文按词计。键按着时，右边三个记号都已出现，而且原词、两侧上下文及候选连续两次相同，才批量发问。两组以同一固定顺序排列候选，并使用原来的替换阈值。

定稿时从同一句已完成的回复中逐片段匹配。其余片段合为一笔补问，旧请求仍未返回时直接补问。串行组在相同的 Apple 定稿上一次问完。完全没有命中时，两组共用这一笔定稿请求。有部分命中时，分别实测全量请求和补问的等待。`segment-preview-results.json` 保存逐句复用数、补问和最终结果。

在项目根目录运行以下命令。Mac 测试机需要已安装苹果简体中文识别资源和 `ffmpeg`。先通过测试机共享队列拿锁，再执行。润色地址通过 `NB_EXPERIMENT_POLISH_PORT` 指定本机 SSH 转发端口，默认 16017。Jev 使用 `TYPESAFE_API_KEY`，请求内容仅包含合成语音的转写、相关候选和共用测试词表。

```sh
bash tools/jev_replay/capture.sh /tmp/nbime-jev
python3 tools/jev_replay/evaluate.py /tmp/nbime-jev --with-segmentation
```

已有回放结果时，可直接用原来的 `capture.jsonl` 与 `probe` 重跑三种问法。

```sh
python3 tools/jev_replay/evaluate.py /tmp/nbime-jev --compare-prompts
```

补候选组使用测试机上的隔离 Python 环境。

```sh
python3 -m venv /tmp/nbime-jev/.venv
/tmp/nbime-jev/.venv/bin/python -m pip install pypinyin==0.55.0 jieba==0.42.1
/tmp/nbime-jev/.venv/bin/python tools/jev_replay/evaluate.py /tmp/nbime-jev --with-candidate-expansion
```

预览对照使用已有的 `audio/*.pcm`，更新探针后直接重放。

```sh
bash tools/jev_replay/capture.sh /tmp/nbime-jev --compile-only
/tmp/nbime-jev/.venv/bin/python tools/jev_replay/preview.py /tmp/nbime-jev
/tmp/nbime-jev/.venv/bin/python tools/jev_replay/preview.py /tmp/nbime-jev --by-segment
```

`capture.jsonl` 保存两种配置的本机识别和耗时。`results.json` 保存逐句的提醒、候选修改、最终文本、耗时和总计。以忽略大小写和标点的参考文本评分，标到实际错误处算命中，标到好词算误报。分词组另存一组诊断数据，撤下 Jev 给出低于 0.25 疑似概率的标记。目标词改对与误改分别在候选替换后、润色后计数，整句编辑距离同时检查目标词以外的变化。

候选覆盖率以 Apple 首选转写中目标词出错的句子为分母。先检查 Apple 的原始备选片段能否拼回完整的正确目标词，再用同一口径检查筛选后的 Apple 候选和补充后的候选。后两项遵循热词与固定替换保护，允许组合不重叠的片段。参考答案仅在评分时参与检查。
