# PLAN: rubyboy WASM audio support

komagata 用の軽量機能要件メモ。実装前の整理が目的。

## Goal

ブラウザで動かしたWASM版でゲームの音が出るようにする。

## Current State

ブラウザでは全く音は出ない。

## Browser Audio Constraints

1. **AudioContext は main thread 専用**。Web Worker から直接 Web Audio API を叩けないため、音を鳴らす部分は必ず main thread 経由になる。
2. **Autoplay policy**。ユーザー操作(クリック/タップ)なしには音を出せない。初回クリックで `AudioContext` を生成または `resume()` する必要がある。
3. **SharedArrayBuffer の有効化条件**。`Cross-Origin-Opener-Policy: same-origin` + `Cross-Origin-Embedder-Policy: require-corp` ヘッダが必要。`self.crossOriginIsolated === true` でのみ SAB が使える。
4. **GitHub Pages は COOP/COEP ヘッダを設定できない**。回避策として coi-serviceworker(クライアント側 Service Worker)を使う。
5. **AudioWorklet の quantum は固定 128 samples**。`process()` は 128 サンプル単位で呼ばれる、変更不可。
6. **AudioContext のサンプルレートはハードウェア依存**(44100 or 48000 が多い)。保証はなく、`AudioContext.sampleRate` で取得する必要がある。エミュレータ側の 48000Hz と一致しない場合は resample が必要。
7. **Web Audio のサンプル形式は float32 linear PCM**(ネイティブ版と同じ)。変換不要。
8. **iOS Safari の user gesture 判定が厳しい**。`AudioContext` 生成や `resume()` は user gesture ハンドラの同期実行中でないと効かない(await を挟むと無効になる)。
   - 対応: クリックハンドラの **最初に** AudioContext を生成する。ROM 読み込みなど非同期処理は後。これはブラウザゲーム一般の定石。
9. **バックグラウンドタブで AudioContext が suspend される**。タブ復帰時に ring buffer 消費が止まったままになる可能性がある。
   - 対応: `document.addEventListener('visibilitychange', ...)` で復帰時に `AudioContext.resume()` を呼ぶ。これもブラウザゲーム定石。

## Architecture

### 1. データフロー図

```
┌─────────────────────────────────────────────────────────────┐
│  Web Worker (worker.js + ruby.wasm + lib/)                  │
│                                                             │
│   Executor#exec(keys)                                       │
│     ↓                                                       │
│   EmulatorWasm#step ── CPU+PPU+APU+Timer advance            │
│     ↓                                                       │
│   1 frame 分の video + audio (float32 PCM) を取り出し       │
│     ↓                                                       │
│   File.binwrite('/video.data', ...)                         │
│   File.binwrite('/audio.data', ...)                         │
│     ↓                                                       │
│   worker.js が rootDir から2ファイルを読み出し              │
│     ↓                                                       │
│   postMessage({video, audio})                               │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│  Main Thread (index.js + new audio_bridge.js)               │
│                                                             │
│   onmessage:                                                │
│     video → canvas に描画（既存経路そのまま）               │
│     audio → SharedArrayBuffer ring に書き込み (Atomics)     │
│                                                             │
│   pacing loop: ring fill を監視、余裕あれば次フレーム要求   │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼ (SAB 共有)
┌─────────────────────────────────────────────────────────────┐
│  AudioWorklet thread (audio-worklet.js)                     │
│                                                             │
│   AudioRingProcessor#process(inputs, outputs)               │
│     ring buffer から 128 samples × 2ch 読み出し             │
│     outputs[0][0][i] / outputs[0][1][i] に書き込み          │
│     underrun 時は 0 で埋める                                │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
                    ┌────────────────┐
                    │ Web Audio API  │
                    │ → スピーカー    │
                    └────────────────┘
```

### 2. コンポーネント分担

| レイヤー | 担当 | 新規 / 既存 |
|---|---|---|
| Ruby (lib/rubyboy/*) | CPU/PPU/APU/Timer を 1 frame 進めて video + audio バイト列を生成 | 既存(最小追加) |
| Worker (docs/worker.js) | Ruby VM 実行、virtual FS から video/audio 取り出し、postMessage | 既存を拡張 |
| Main thread audio bridge (docs/audio_bridge.js) | AudioContext 生成、SAB ring への書き込み、pacing loop | 新規 |
| AudioWorkletProcessor (docs/audio-worklet.js) | ring buffer 読み出し → Web Audio へ出力 | 新規 |
| coi-serviceworker (docs/coi-serviceworker.js) | GitHub Pages に COOP/COEP を後付け | 新規(外部由来) |

### 3. 初期化シーケンス

```
1. ブラウザがページをロード
2. coi-serviceworker がインストール(初回のみリロード)
3. index.js がロードされ、UI 初期化
4. worker.js が起動、ruby.wasm をロード、Executor を new
   (この時点ではまだ AudioContext は存在しない)
5. ユーザーが ROM select または upload をクリック ← user gesture
6. audio_bridge.js が以下を一括実行:
   a. new AudioContext()
   b. audioContext.audioWorklet.addModule('audio-worklet.js')
   c. new SharedArrayBuffer(ring size)
   d. new AudioWorkletNode(context, 'audio-ring', {processorOptions: {sab}})
   e. node.connect(context.destination)
   f. worker.postMessage({type: 'attachAudio', sab})
7. worker がRuby 側に SAB 参照を渡せない(SAB は Ruby から直接触れない)ので、
   worker側で SAB を保持し、Ruby が出した audio を worker 側で SAB に書き込む
   (注意: Ruby は虚構 FS 経由で worker に PCM を渡すだけ。SAB 操作は JS 側)
8. Pacing loop 開始: ring fill を監視 → tick 送信 → emulation 進行
```

### 4. 失敗モード一覧

| 失敗 | 挙動 | 備考 |
|---|---|---|
| coi-serviceworker 登録失敗 | 無音で動作継続 | SAB 作成時に fallback |
| `new SharedArrayBuffer` 失敗 | 無音で動作継続 | crossOriginIsolated == false |
| `audioWorklet.addModule` 失敗 | 無音で動作継続 + console.error | 古いブラウザ |
| ring underrun | AudioWorklet が 0 を出力 | 短時間の無音、pacing で自動回復 |
| ring overflow | 書き込み側がスキップ(ドロップ) | v1.5.1 ネイティブの ClearQueuedAudio と同様の劣化、pacing が効いていれば起きない |
| Ruby VM クラッシュ | worker.onerror → UI にエラー表示 | 既存挙動のまま |

## Functional Requirements

実装時に忘れがちな/罠になりやすい要件だけを列挙。「音が鳴る」などの自明な要件は省略。

1. **映像と音声のズレが体感できないレベルに収まる**。Audio-driven pacing のズレによる視覚/聴覚のドリフトは禁止。
2. **バックグラウンドタブから復帰しても正常に再開する**。`visibilitychange` で AudioContext を resume() する。復帰時に止まったままはバグ扱い。
3. **SharedArrayBuffer が使えない環境では無音で動作継続**。エラー表示・クラッシュせず、映像だけ既存経路で動くこと(既存のビジュアル動作を壊さない regression guard も兼ねる)。
4. **ring buffer の underrun/overflow は無音で吸収**。エラー表示せず、音声パスが一時的に破綻しても画面は動き続ける。pacing loop で自動回復する。
5. **iOS Safari で鳴る**。user gesture 判定の罠を避ける実装順序(AudioContext 生成をクリックハンドラの最初に置く)。

## Implementation Phases

### Phase 0: ローカルビルド環境を整える

- wasm group の `bundle install` を通す(ruby_wasm 2.7.1 の linux 版取得)
- `bundle exec exe/rubyboy-wasm build` → `docs/ruby-js.wasm`
- `bundle exec exe/rubyboy-wasm pack` → `docs/rubyboy.wasm`
- `docs/` を簡易HTTPサーバ(`python3 -m http.server` など)で配信してブラウザで動作確認
- 完了条件: ローカルで Tobu Tobu Girl が映像だけで動く状態

### Phase 1: coi-serviceworker を導入

- `docs/coi-serviceworker.js` を上流リポジトリ(MIT)からコピー
- `docs/index.html` に `<script src="./coi-serviceworker.js"></script>` を追加
- 完了条件: ブラウザで `self.crossOriginIsolated === true` が確認でき、`new SharedArrayBuffer(16)` が例外を投げない

### Phase 2: 無音の Audio 骨格を構築

- `docs/audio-worklet.js` 新規作成(AudioRingProcessor、ring buffer から 128 samples 読み出し、underrun 時は無音出力)
- `docs/audio_bridge.js` 新規作成(AudioContext + AudioWorkletNode + SAB 生成、ring writer)
- `docs/index.js` から ROM 選択クリックで audio_bridge を初期化
- この時点では SAB は空なので AudioWorklet は無音を返し続ける
- 完了条件: ブラウザコンソールでエラーなく AudioContext が running、AudioWorklet が 128 samples 単位で `process()` を呼ばれている

### Phase 3: Ruby 側で APU を駆動

- `lib/rubyboy/emulator_wasm_audio.rb` 新規作成(`EmulatorWasm` を継承、`step` で APU も駆動して audio バッファを返す)
- `lib/executor_audio.rb` 新規作成(`exec` で video + audio を両方仮想FSに書き出す)
- 既存 `lib/rubyboy/emulator_wasm.rb` と `lib/executor.rb` は無変更
- 完了条件: worker.js 内で `vm.eval('$executor.exec(...)')` を呼んだ後、`/video.data` と `/audio.data` が両方揃う

### Phase 4: Audio データを speaker まで通す

- `docs/worker.js` を拡張: 仮想FSから `/audio.data` を読み、`postMessage({audio: bytes})` で main thread に送る
- `docs/audio_bridge.js` が受けて SAB ring に書き込み(Atomics で write pointer 更新)
- 完了条件: Tobu Tobu Girl のBGMが実際にスピーカーから鳴る(pacing はまだ setTimeout(0) ベース、音は鳴るが速度は安定しない可能性あり)

### Phase 5: Audio-driven pacing に切り替え

- `setTimeout(0)` 無制限ループを廃止
- Main thread が ring fill を監視し、fill < 75% なら worker に `{type: 'tick'}` を送信
- worker は tick を受けて1 frame 進め、audio + video を返す
- 完了条件: エミュレータがリアルタイム速度(60fps)で安定動作、映像と音声が同期

### Phase 6: 罠対策(visibilitychange / iOS)

- `document.addEventListener('visibilitychange', ...)` で復帰時に `AudioContext.resume()`
- ROM 選択クリックハンドラの最初に AudioContext を作り、ROM 非同期読み込みより前に初期化する
- SharedArrayBuffer 作成失敗時の try/catch fallback(無音で動作継続)

### Phase 7: テスト

- Tobu Tobu Girl (プリインストール)
- BGB Test(プリインストール、APU テストを含む可能性)
- **ポケモン赤**(アップロード、最終確認用。ClearQueuedAudio 問題の aiboy 側修正がこちらにも効いていること、長尺BGMで音切れしないことを確認)
- 主要ブラウザ: Chrome、Firefox、Safari
- モバイル: iOS Safari(時間があれば)

### Phase 8: PR 準備

- `lib/` 差分のレビュー(追加ファイルのみ、既存無変更を確認)
- `docs/` 差分のレビュー(demo JS の増加、coi-serviceworker の MIT 表記)
- sacckey 向けの PR 本文ドラフト(rubyboy 本体変更の最小性を強調)

## Open Questions

実装中に決める/判断材料が増えてから決める事項。

- **音量 UI を付けるか**: スライダ / ミュートボタン。最小構成では付けず、必要になったら追加。
- **AudioContext.sampleRate が 48000 でない環境の扱い**: そのまま流すとピッチがずれる。resample するか、サンプルレートを AudioContext に合わせてエミュレータ側を動的に変えるか。Phase 4 で実機確認して判断。
- **"Audio off" トグル**: 音を切って静かに遊びたいユーザー向け。必要なら Phase 6 以降で検討。
- **iOS Safari 対応の本気度**: best effort(動けばOK) か、明示的にテストして保証するか。Phase 7 のテスト結果次第。
- **Ring buffer の容量**: 初期値 4096 stereo samples(≈85ms)で着手、Phase 5 の実機 pacing 調整で再検討。
