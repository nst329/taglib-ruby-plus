# colr診断とpurlのcontext生成拒否

日付: 2026-10-13
状態: 採用

## 背景

colrの1 byte overreadだけでは警告track、sample entry、rangeの正しい値が特定できない。
またpurlのindex警告が参照修復とタグ保存のどちらで発生したか不明だった。
基準実装は2.3.2.15で、選択参照解除APIは既に存在する。

## 決定と理由

- File#color_metadata_diagnosticsを追加する。既存chapter診断と命名を揃え、
  nativeの映像属性推定ではなく原本stsd/entry/colrを診断するため。
- 既存atom parserに任意の共有読込予算を追加する。32/64bit境界・深さ・件数検証を
  複製せず、headerを含む総読込量も制限するため。既存利用者には予算を強制しない。
- 対応済みvisual sample entryの固定layoutだけを走査する。未知layoutを固定offsetで
  推測しないため。未対応entryは明示的に返す。
- nclx/nclcの生値を部分的に診断し、欠落値はnilとする。ffprobeの観測値で復元せず、
  短いnclxから隣接atomの1 byteを読まないため。自動colr修復は追加しない。
- File#metadata_context_diagnosticsを既存readerの詳細モードとして追加する。
  位置・raw識別子・digestを公開しながら、既存snapshotの構造比較を変えないため。
- 新規purlをmdta ilstへ保存する場合はprepareで拒否する。実native writerとffprobeで
  新しい警告の生成を確認し、拒否なら削除・再採番・データ解釈変更をせず原本を保護できるため。
- 既存purlの許容判断は変更しない。既存警告の扱いはMListNewの責務であり、
  この変更を一律の警告拒否や安全判定緩和にしないため。
- 未編集purlは通常saveとraw保持saveの保存後raw digestも検証する。
  合成fixtureでdata_type 1がnative writerにより0へ変わることを確認し、
  nativeの論理値比較だけでは対象外データの変更を検出できなかったため。
  変更を検出した場合はverifyで原本置換を拒否し、自動再符号化を加えない。
- 新規mdir context生成は実装しない。複数contextのnative読取・writer・snapshot契約を
  広げる複雑な変更になり、原因に対する最小修正を越えるため。
- 参照解除本体は変更しない。非ゼロ欠落の選択・対象外保持が既存APIで成立したため。
- 配布ファイル一覧にAPI・テスト・文書を追加する。将来buildしたgemに必要なRuby fileを
  同梱するため。調査時点ではversion更新・gem公開を行わず、後続の明示指示で
  2.3.2.16のタグ・バイナリgem・source gem公開を既存workflowで行う。

## 根拠と影響

公開準備で既存2.3.2.15のLinux CIログを確認し、SWIG再生成後のsetterが
未修飾MP4::AtomDataTypeを使用してコンパイルに失敗していた。
定義元をTagLib::MP4::AtomDataTypeへ揃える。配布済み生成コードは既に完全修飾されており、
その動作・native ABIを変更せず、再生成との不一致だけを解消する。

合成mdta MP4は保存前にpurl警告がなく、nativeタグ保存後に1886745196の警告を出した。
独立parserではhandlerとkeysが不変で、同じilstにpurlが追加されていた。
参照解除前後ではmetaのraw構造が不変だった。
FFmpegの[公式mov.c](https://github.com/FFmpeg/FFmpeg/blob/master/libavformat/mov.c)にも、
mdta keysがあり既知の通常タグとして解決されないdata itemを数値indexで解釈する処理がある。
実行版n9.0.2での再現結果を直接の検証根拠とし、masterのソースだけで版一致を断定しない。

新規podcastURLをmdta contextへ書く操作はこれまで成功を返していたが、今後は明示的に失敗する。
mdirでの通常保存、既存purlの保持、数値mdtaの保存、chapter参照解除の契約は維持する。
実ファイルの警告trackと構造は未確認であり、合成結果から実ファイルの発生段階を断定しない。
