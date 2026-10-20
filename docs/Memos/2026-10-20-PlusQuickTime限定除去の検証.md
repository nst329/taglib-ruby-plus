# Plus QuickTime限定除去の検証

日付: 2026-10-20

## 合成fixture

FFmpegで映像・音声を含むMP4を作り、native writerでNeroとQuickTimeを設定した。参照の追加、欠落ID、非音声共有参照、未知track構造、Nero chpl破損、時間atom不整合は独立fixture parserで一時コピーへ注入した。実ユーザーMP4と実DBは変更していない。

## 成功条件

基本fixtureでは複数の音声chap参照を同一専用text trackへ向け、QuickTime readerが完全読取できない状態を作った。`read_chapters(style: :nero)`が開始時刻・名称・順序を返し、計画が`:removable`となり、保存後に次を確認した。

- Neroの開始時刻・名称・順序が一致する。
- Nero `chpl` payload SHA-256が一致する。
- QuickTimeが不在になる。
- 対象参照と専用text trackが不在になる。
- 通常字幕相当の非対象track、映像・音声track、metadata、mdat payload hashが一致する。
- 別出力保存後も原本が不変で、出力を独立openできる。

## 拒否条件

正常QuickTimeは`:complete`で削除計画にならず、QuickTime不在は`:absent`になる。欠落参照、非音声からの共有参照、未知atom、Nero異常は`:blocked`とreason codeを返す。入力変更と改変計画は保存前に拒否する。verify失敗は原本と計画を保持し、修正後の再試行を許す。

## 実行結果

専用suiteは7 tests / 92 assertions、失敗0、エラー0で成功した。既存の参照解析suiteは32 tests / 546 assertions、既存のsample snapshot suiteは14 tests / 220 assertions、既存のsnapshot access suiteは19 tests / 254 assertionsで成功した。構文チェックと`git diff --check`も成功した。

Plus既存受入suiteは、作業環境に`shoulda-context`、`rake-compiler`、`yard`が未導入のため起動前に実行できなかった。専用suiteは`test-unit`だけで公開Plus APIを実際に呼び出して検証している。依存を追加インストールしていないため、全体`rake test`の完走は未確認である。

## 限界

今回の合成fixtureでは非対象media payloadをmdat単位のSHA-256とtrack atomで比較した。4GiB超offset、fragmented MP4、未知の複雑な用途参照、実ユーザーMP4、実DB、配布gem、pushは検証対象外である。物理mdatから除去したtext sampleを回収する設計ではないため、ファイル縮小は成功条件に含めていない。
