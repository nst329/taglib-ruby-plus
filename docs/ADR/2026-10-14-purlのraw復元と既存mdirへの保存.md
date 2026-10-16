# purlのraw復元と既存contextへの保存

## 状態

採用。2.3.2.18向け。未公開。

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
- 単一mdtaにpurlが存在しない場合は、既存contextの`keys`末尾へ追加し、同じindexの数値itemを
  `ilst`へ追加する。mdtaとmdirの新設は行わず、通常itemの4文字コード解釈を避けるため。
- 対応表に収まる通常itemだけの復元はnative writerを通さず、検証済み`MP4AtomEditor`でmetadata全体を一度に拡張する。
  既存keys、ilst item順、対象外atom、media payloadをそのまま保持するため。
- 複合snapshotでは既存native復元を利用した後、作業コピー上のApple系通常itemを対応する数値keyへ置換する。
  対応外itemを捨てず、`purl`のraw data子atomと文字列itemのUTF-8表現を分けて扱うため。
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

単一mdtaへの新規purl復元を対応した。保存後はpurlが`keys`の数値indexで解決される。
`stco/co64`がmdat外を指す、atom境界が不正、再配置計画が作れない場合は
`purl_atom_extension_unsupported`で復元前に拒否する。
既存mdta内に誤ったfourcc `purl`がある場合は、二重化を避けるため`purl_fourcc_context`で拒否する。
字幕mux後の既存単一mdtaへの対応key追加を許可する。新規context生成や対応表外itemの推測変換は行わない。
複合復元はFile#metadata_snapshot、File#restore_metadata_snapshot、File#saveを使用する。
Tag API、通常のproperty setter、chapter保存の複数context対応は拡張しない。
既存のindex 0専用保存経路は従来の拒否・保持契約を維持する。
