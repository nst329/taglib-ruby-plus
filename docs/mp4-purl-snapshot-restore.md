# MP4 purl snapshot復元（2.3.2.18）

## 対応範囲

| destination | 動作 |
| --- | --- |
| 単一mdir | purlをそのmdirへ保存。snapshotにrawがあれば完全保持 |
| 単一mdta、既存purlあり | 同じcontextでraw bytes・data type・payload・data順・既存item位置を保持 |
| mdtaとmdirが各1個、mdta側は数値itemのみ | File APIで通常itemを既存mdirへ、mdta値をmdtaへ復元 |
| 単一mdta、purlなし | `keys`末尾へpurlを追加し、数値key indexのitemとして保存 |
| 複数mdta/mdir、mdta側にも通常itemがある複合構造、handler不一致、不正keys | 推測せず拒否 |

複合保存は既存mdirをmdtaより前へ移動する。context内部のpurl raw順は保持する。
FFmpegがmdtaの解析状態を後続metaへ持ち越すことによるdata index警告を防ぐため。
既にmdta内purl由来の警告がある入力では、その既存警告自体は除去しない。

## MListNewの移行例

```ruby
snapshot = TagLib::MP4::File.open(input, false) { |file| file.metadata_snapshot }

TagLib::MP4::File.open(muxed_output, false) do |file|
  # 診断は保存済み構造を対象とする。writable=falseの理由はcodeで判定できる。
  diagnosis = file.metadata_context_diagnostics[:purl]
  file.restore_metadata_snapshot(snapshot) # purlをwithout等で除外しない
  file.save
end

restored = TagLib::MP4::File.open(muxed_output, false) { |file| file.metadata_snapshot }
raise 'metadata values changed' unless snapshot.same_values?(restored)
raise 'purl raw bytes changed' unless snapshot.purl_raw_digests == restored.purl_raw_digests
```

`purl_raw_digests`はcontext固有の外側item typeを`purl`へ正規化したraw purl atomのSHA-256を順序付きで返す。
mdtaへ移した場合も、data子atomのtype・locale・payload・順序を比較できる。
raw bytesはFileを閉じた後もsnapshotが所有する。purl削除候補では空配列を返す。
rawを伴うsnapshotのpurl型やpayloadを変更するとpurl_raw_mismatchで拒否する。
通常のpurl値変更にはproperty APIを利用し、完全保持のsnapshot復元とは分ける。

mdtaのみ・purlなしの場合も、単一contextかつatom構造とchunk offsetが検証できれば自動追加する。
複数context、既存keys/ilst不整合、mdat外offsetなどは次の専用エラーで成果物を確定せず失敗として扱う。

```ruby
rescue TagLib::MP4::MetadataSnapshotError => error
  if error.code == :purl_atom_extension_unsupported
    # phase == :restore。native状態・原本を変更する前の拒否。
    raise
  end
  raise
```

`metadata_capabilities`は`purl_raw_snapshot_v1`、`purl_existing_mdir_restore_v1`をtrue、
`purl_context_creation`をfalseとして返す。mdtaの既存context拡張可否はdiagnosticsで確認する。
診断の`purl`は`writable`、`existing`、`key_index`、`context_handler`、`code`、`reason`を返す。

## 原子性とエラー

restoreはメモリ上の候補作成であり、原本への書込みはsave時のみ行う。
複合contextでは両候補のnative検証後にFileがsnapshotを保留する。
その後のFile#metadata_snapshotは保留候補を返す。Tag側のnative viewは更新しないため、
複合復元ではFile APIを使い、property直接編集やchapter保存計画を同時に追加しない。
候補の取消・Tag操作への切替は保存せずFileを閉じて開き直す。

saveは一時コピーの再読込、値・raw digest・chapter・media payload・原本SHAを検証してrenameする。
rename前の失敗では原本SHAを維持し、MdtaSaveErrorのcommittedはfalse。
rename後の再open失敗はphase=:reopen、committed=true。codeは省略可能な追加属性。
元の通常保存やchapter保存のphase/committed契約は変えない。

復元時の主なcodeはpurl_atom_extension_unsupported、purl_fourcc_context、ambiguous_purl_context、
purl_raw_mismatch、purl_data_type_change。
直接保存時のpurl型変更はMdtaSaveError(code: :purl_data_type_change, phase: :prepare)。
複合候補と他編集の混在はpending_changes、解析後の原本変更はsource_changedで拒否する。

moov/udta/meta以外、断片化MP4、既存atom editorが保証できないmedia構造は対象外。
FFprobeはgemの実行時依存にはせず、回帰テストで警告の新規発生を検証する。

`purl`以外のmacOS系UTF-8 mdta keyは、snapshotの`mdta`に存在すれば既存のsnapshot復元経路で同じく末尾追加できる。
通常itemからmdtaへ意味を移す互換変換は、4文字コードとの衝突を避けるためpurlに限定する。
