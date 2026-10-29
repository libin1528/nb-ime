<p align="center">
  <img src="design/readme/icon.png" width="112" alt="NB 輸入法のアイコン">
</p>

<h1 align="center">NB 输入法 · NB 音声入力</h1>

<p align="center">
  押して話し、離すと入力。自分の環境だけのために作った Mac 用の音声入力です。<br>
  <b>そのまま使う製品ではなく、AI に渡すための「コンテキスト」です。</b>
</p>

<p align="center">
  <a href="README.md">简体中文</a> · <a href="README.en.md">English</a> · <b>日本語</b>
</p>

<p align="center">
  <img alt="macOS 26+" src="https://img.shields.io/badge/macOS-26%2B-000000?logo=apple&logoColor=white">
  <img alt="Swift / AppKit" src="https://img.shields.io/badge/Swift-AppKit-F05138?logo=swift&logoColor=white">
  <img alt="No dependencies" src="https://img.shields.io/badge/dependencies-none-34C759">
  <img alt="MIT" src="https://img.shields.io/badge/license-MIT-0A84FF">
</p>

<p align="center">
  <img src="design/readme/capsule-morph.gif" width="640" alt="録音カプセル：キーを押すと現れ、話しながら広がって文字を表示し、離すと認識・入力して縮んで消える">
</p>

> アプリの画面、`docs/` の記録、コミットメッセージは中国語です。最近の AI コーディングツールなら問題なく読めます。リポジトリごと渡してください。

## ソフトウェアは自分で作る

> これからのツールは、ワンクリックで入れる完成品とは限らない。AI に渡せるコンテキストかもしれない。

NB には目的が二つあり、優先順位があります。

1. **第一に、自分にいちばん合う音声入力を作ること。** 対象は私の環境だけです。Mac が一台と、LAN 内で音声認識を動かす GPU マシンが一台。話すときは中国語と英語が混ざり、自分のプロジェクトの固有名詞がたくさん出てきます。改良はいつも、自分で使っていて不便だったところから始まります。公開に値する製品にするためではありません。これからも自分の考えで手を入れ続けます。
2. **第二に、その成果をコンテキストとして共有すること。** そのまま clone しても、たぶん動きません。でも自分の音声入力を作りたいなら、このリポジトリを AI コーディングツール（Claude Code、Codex、Cursor など）に渡してください。ここに残した判断、実測データ、ハマりどころを参考に、**あなたの**環境に合った**あなたの**版を作らせるのが狙いです。

ソフトウェアではなく、参考資料として扱ってください。

## コンテキストとして使う

いちばん手軽なのは、clone して AI コーディングツールを開き、こう頼むことです。

```text
このリポジトリは、ある人が自分用に作った Mac の音声入力です。まず README、docs/、
git log を読んで、各機能がなぜそう作られているか、どこでハマったかを把握して。
そのうえで私に合う版を作るのを手伝って：認識は ____ で動かしたい、
よく話す言語は ____、いちばん欲しい機能は ____。
```

おすすめの読む順番（人にも AI にも）：

| まず読む | 中身 |
|---|---|
| [`docs/`](docs/) | 各イテレーションの作業指示と記録：決めたこと、実測データと結論、ハマりどころ |
| `git log` | どのコミットにも「何を、なぜ変えたか」が書いてあり、順に読めばプロジェクトの成長記録になる |
| [`design/`](design/) | モックアップ、各回の変更前後のスクリーンショット、整形の比較ページ |
| [`client-mac/Sources/`](client-mac/Sources/) | 機能ごとに分かれた Swift のコード。下の「参考になるところ」を参照 |
| [`server/`](server/) | サーバーのデプロイと自動起動、Windows でのハマりどころ |

## 私の環境

何を前提に書かれているかが分かれば、どこを差し替えればいいかも分かります。

| | 私の場合 | たぶん差し替えるところ |
|---|---|---|
| クライアント | macOS 26、ネイティブの Swift / AppKit、メニューバー常駐、サードパーティ依存なし | OS のバージョン（カプセルに Liquid Glass を使用） |
| 認識 | LAN 内の Windows GPU マシン（RX 6700 XT）で [CapsWriter-Offline](https://github.com/HaujetZhao/CapsWriter-Offline) + Qwen3-ASR-1.7B | 認識をどこで動かすか：Mac 上、クラウド API、別のモデル |
| 接続 | Mac から ssh トンネル経由。音声は家の外に出ない | LAN に直接、あるいはサーバーなし |
| 整形 | 同じマシンで llama.cpp により Qwen3.5-4B 8bit | 整形を使うか、どのモデルにするか |
| 話し方 | 中国語と英語が混在、固有名詞が多くホットワード表で補う | あなたの言語、あなたの語彙 |
| 画面の言語 | 中国語のみ | — |

## 参考になるところ

| 機能 | コード | 見どころ |
|---|---|---|
| 録音カプセル | [`Capsule.swift`](client-mac/Sources/Capsule.swift) | システムの `NSGlassEffectView`（clear ガラス＋文字の下に反転色の薄い下地）。点からカプセルに育ち、状態の間をひと続きに変形。波形は音量に追従し、話している間は上に広がって文字をリアルタイム表示 |
| グローバルホットキー | [`Hotkey.swift`](client-mac/Sources/Hotkey.swift) | CGEventTap でキーボードとマウスを監視。修飾キー単押し、F キー、マウスのサイドボタンもホットキーにでき、二つまで設定可能。システムにタップを止められた後は実際のキー状態に合わせ直す |
| ストリーミングプレビュー | [`AppController.swift`](client-mac/Sources/AppController.swift) | 同じ音声を二本の WebSocket に流す。一本は 2 秒ごとのプレビュー、もう一本は離した後の完全な結果で、入力するのは後者 |
| 読みによるホットワード補正 | [`Hotfix.swift`](client-mac/Sources/Hotfix.swift) | モデルが「万三」と書いても、読みがホットワード「Wan3」と同じなら書き換える。中国語は声調まで一致が条件、数字や量詞に接する部分は触らない |
| 認識後の整形 | [`Polish.swift`](client-mac/Sources/Polish.swift) | 「言い間違いを除く」「書式を整える」がそれぞれ オフ / 中 / 強。小さなモデルの出力は信用せず、「削るだけで足さない、ホットワードは全部残る」チェックを通らなければ元の文を入力 |
| メニューバー、設定、初回案内 | [`MenuBar.swift`](client-mac/Sources/MenuBar.swift) · [`SettingsWindow.swift`](client-mac/Sources/SettingsWindow.swift) · [`Onboarding.swift`](client-mac/Sources/Onboarding.swift) | メニューバーのアイコン自体が状態表示：録音中は赤、認識中は順に点灯、未接続はグレー。設定はすべて画面から変更できる |

## 実測した結論と、ハマったところ

コードでは一、二行でも、どれも実測か失敗から出てきたものです。詳細は [`docs/`](docs/) とコミット履歴にあります。

- **サーバーの音声バッファはタスク単位ではなく接続単位。** プレビューと完全認識は別々の WebSocket が必要で、一本にまとめると音声が混ざり、完全な結果が空になる。
- **声が小さすぎるか無音だと、認識モデルがプロンプト内のホットワード表をそのまま読み上げる。** 検出したら、ホットワードを逆順にして認識し直して確かめる。プレビューでも起きるが、プレビューにホットワードを付けないと固有名詞を間違えるので、両方の対処が要る。
- **プレビューの区切りは 2 秒が釣り合う点：** 発話から 1〜1.5 秒遅れ。3 秒のほうが正確だが更新が遅すぎる。
- **`NSEvent` のグローバル監視では修飾キーの単押しを拾えない**ので CGEventTap を使う。AI が模擬したキー入力はシステムに捨てられるので、ホットキーは人の手で押してログで判定するしかない。
- **再ビルドすると「アクセシビリティ」の許可が外れる。** キーチェーンの同じ開発用証明書で署名すれば外れない。bundle id を変えても外れる。
- **clear ガラスに下地がないと、ライトモードで暗い背景の上の文字が読めない。** `tintColor` はほとんど効かず、反転色の薄い下地を自前で敷いた。
- **整形用の小さなモデルは、ときどき文字を足したり変えたりする。** プロンプトで粘るより、出力を機械的にチェックする。文字が増えた、ホットワードが消えた、削りすぎ、タイムアウトなら、すべて元の文に戻す。
- **Windows の llama.cpp で `--no-mmap` を付けないと**、4B モデルでメモリを 5.7GB 使う。付ければ 834MB。

## 見た目

<p align="center">
  <img src="design/readme/capsule-states.png" width="760" alt="カプセルの 8 つの状態：聞き取り中、話しながら文字表示、長いときは最後の 3 行だけ、認識中、入力済み、声が聞こえない、聞き取れない、未接続">
</p>

<p align="center">
  <img src="design/readme/settings-hotkey.png" width="560" alt="設定のホットキー画面：ホットキーを二つ設定でき、マウスのサイドボタンにも対応">
</p>

<p align="center">
  <img src="design/polish/settings-before-after.png" width="760" alt="設定の変更前後：新しい「整形」タブ。言い間違いと書式がそれぞれ オフ / 中 / 強">
</p>

## 自分で動かしてみる

<details>
<summary>認識サーバー用の GPU マシン、macOS 26、ソースからのビルドが必要です。開くと手順が出ます。</summary>

<br>

1. **サーバー**：GPU のあるマシンに CapsWriter-Offline と Qwen3-ASR モデルを入れます。手順は [`server/README.md`](server/README.md)（私たちのは Windows、説明は中国語）。整形を使うなら Qwen3.5-4B も動かします（同じ説明にあり）。使わない場合は「設定 › 润色（整形）」で両方をオフに。
2. **クライアント**：macOS 26 と Xcode コマンドラインツールが必要です。
   ```bash
   cd client-mac && ./build.sh
   ```
   `~/Applications/NB 输入法.app` に入れて起動します。再ビルドのたびにアクセシビリティを許可し直したくなければ、`client-mac/sign-identity.local` にキーチェーンの開発用証明書の名前を一行書いてください。なければアドホック署名になります。
3. 初回起動時にマイクとアクセシビリティの許可を案内します。その後「設定 › 识别服务（認識サービス）」で ssh ホストかサーバーのアドレスを入れます。初期値は私たちのマシンに合わせてあります。

これは私の個人用ツールです。機能要望は受け付けず、メンテナンスも約束しません。issue にも返事できないことがあります。fork するか、できれば AI に自分用を書かせてください。

</details>

<details>
<summary>ディレクトリ構成、ローカルデータ、デバッグ用コマンド</summary>

<br>

| ディレクトリ | 中身 |
|---|---|
| `client-mac/` | メニューバーのクライアント（Swift / AppKit、`Sources/` に機能ごとのファイル）。`./build.sh` でビルド・インストール・起動、`--no-run` はインストールのみ、`--icon` はアイコンを描き直す |
| `server/` | サーバー（CapsWriter-Offline と整形モデル）のデプロイ手順と Windows の自動起動スクリプト |
| `tools/` | デバッグ用スクリプト。ストリーミングプレビューを測る `stream_test.py`、ホットワードの渡し方を比べる `hotword_echo_test.py` など |
| `design/` | モックアップ `mockup.html`、各回の実画面の比較スクリーンショット、整形の比較ページ `polish/samples.html` |
| `docs/` | 各イテレーションの作業指示と記録 |

ローカルデータは `~/Library/Application Support/NBIME/` にあります：設定 `config.json`、ホットワード `hotwords.txt`、履歴 `history.json`（直近 200 件）。どれも設定画面から変更できます。ログは `~/Library/Logs/NBIME.log`。

デバッグ：

- `NBIME --test-file <音声>`：マイクを使わず、実時間のペースで同じ送信経路（プレビュー含む）を通し、`PREVIEW` / `RESULT` を出力。
- `NBIME --demo <画面>`：スクリーンショット用。`listen` `quiet` `preview` `long` `think` `done` `miss` `offline` `morph`（変形の一連の流れ）`menu` `onboarding` `settings:0`…`settings:6`。
- `NBIME --polish-test <ファイル>`：一行一文。各文を整形の 8 通りの組み合わせで実行し、一回ごとに JSON を一行出力（`--levels 中中,强强` で指定した組み合わせだけ）。プロンプトを変える前後で比べるのに使う。
- これらのモードは、すでに張られているトンネルを借りるだけで触りません。

</details>

## 使っているオープンソース

| プロジェクト | 用途 | ライセンス |
|---|---|---|
| [CapsWriter-Offline](https://github.com/HaujetZhao/CapsWriter-Offline) | 認識サーバー。クライアントはその WebSocket プロトコルで通信 | MIT |
| [Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR) | 音声認識モデル（1.7B、q5_k 量子化版が CapsWriter のモデルパックに同梱） | Apache-2.0 |
| [Qwen3.5-4B](https://huggingface.co/Qwen/Qwen3.5-4B) | 認識後の整形に使う小さなモデル（[unsloth](https://huggingface.co/unsloth/Qwen3.5-4B-GGUF) の Q8_0 量子化） | Apache-2.0 |
| [llama.cpp](https://github.com/ggml-org/llama.cpp) | 整形モデルを動かす `llama-server`（CapsWriter 同梱の Vulkan 版） | MIT |
| [websockets](https://github.com/python-websockets/websockets)、[NumPy](https://github.com/numpy/numpy) | `tools/` のデバッグ用スクリプト | BSD-3-Clause |

どれもこのリポジトリには含まれていません。使う場合はそれぞれのライセンスに従って元のプロジェクトから入手してください。デザインは Apple の Liquid Glass と WeChat 入力法のメニューを参考にしています。

## ライセンス

[MIT](LICENSE)。コード、ドキュメント、スクリーンショットは自由に使って変えてください。断りは要りません。
