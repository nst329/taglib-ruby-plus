# purlのraw復元と既存mdirへの保存

## 状態

採用。2.3.2.17向け。未公開。

## 背景

native writerは通常itemのpurlをTextImplicitとして扱い、data typeを0へ正規化する。
mdtaのilstへ新規fourcc purlを追加するとFFmpegがkeysの数値indexとして解釈する。
また既存のnative snapshot APIは複数metaを一律に拒否するため、既存mdirも利用できなかった。

## 決定と理由

- snapshotのsource_structureにpurlのraw atom、元item位置、native上の型を所有コピーする。
  値だけの復元ではdata header・payload・複数data順を維持できないため。
- native適用前にrawとsnapshotの型・payloadを照合する。不一致はpurl_raw_mismatchとして拒否する。
  型変更や古いrawを伴う候補を黙って保存しないため。
- 単一contextの既存purlはnative保存後、一時コピー内だけで元rawへ戻す。
  通常のproperty保存でも未編集purlの型と位置を維持するため。
- 単一mdtaにpurlが存在しない場合はcontextを生成せず、復元前に専用codeで拒否する。
  context生成、native複数context対応、他readerとの互換性を同時に拡張するよりも境界が明確なため。
- mdtaとmdir各1個、mdta側に通常itemがなく、構造検証を通る場合のみ複合復元を認める。
  通常itemの保存先が既存mdirに一意に決まり、mdta値を混同しないため。
- 複合contextは一時コピーで他方のmetaを同長freeへ隠し、既存native APIで個別検証・保存する。
  nativeの曖昧性判定を緩和せず、既存の型検証・serializerを再利用するため。
- 既存mdirをmdtaより先へ配置する。context内部のpurl/data順は保持する。
  FFmpegはfound_hdlr_mdta/meta_keysを後続metaへ持ち越すため、mdirが後では正しい保存先でも
  data index警告が発生することを実FFprobeで確認した。
  根拠: https://github.com/FFmpeg/FFmpeg/blob/master/libavformat/mov.c のmov_read_udta_string。
- 複合復元はFile APIで候補を保留し、save時に両contextを一度にrenameする。
  Tagのnative状態へ部分的に適用すると復元失敗時に原子性を保証できないため。
- 複合復元とchapter/native直接編集は同時保存しない。pending_changesで拒否する。
  複数の保存計画を暗黙合成せず、検証対象を一意にするため。
- moov編集は既存MP4AtomEditorを共用し、対象context集合を完全一致で検証する。
  offset補正・media保持の実装を重複させないため。
- 単一context保存にも原本SHAの再確認を追加し、複合保存もrename直前まで原本を変更しない。
  検証中の外部変更を上書きしないため。ファイルシステム上の排他ロックを保証するものではない。
- MdtaSaveErrorへ省略可能なcodeを追加する。phaseとcommittedの意味は維持する。
  既存呼出しと互換性を保ちつつ機械判定を可能にするため。

## 影響と制限

単一mdtaへの新規purl復元は引き続き未対応だが、保存前ではなく復元前に識別できる。
MListNewはpurl省略を削除して完全復元を要求できるが、この構造では処理を失敗として扱う必要がある。
字幕mux後のこの構造を必ず成功させるには、別途context生成の設計が必要。
複合復元はFile#metadata_snapshot、File#restore_metadata_snapshot、File#saveを使用する。
Tag API、通常のproperty setter、chapter保存の複数context対応は拡張しない。
既存のindex 0専用保存経路は従来の拒否・保持契約を維持する。
