# MP4 mdta 複数値の一括復元

## 原因と検証結果

`set_mdta_item` / native `setMdtaItem` は指定キーの全値を単一値へ置換する。値ごとの呼び出しでは最後の値だけが残る。`mdtaItems()` は const 参照であり、既存APIに複数値の書き込み手段はない。

既存パッチの `MdtaState::replace` は有効な既存mdta構造への新規キー追加に対応している。新規キーを作れない場合には、リンク先のパッチの差異やmdirのみの出力が考えられるため、MListNewの対象ファイルと実行環境で確認が必要。今回、新規キーへの複数値出力で最初の値だけを描画する処理も修正した。

native試作では合成動画に新規キーと5値を書き、3回の直接保存・再読込で型、locale、バイナリ、重複、順序を検証した。Ruby保存は既存の一時コピー・再読込検証・renameを利用する。

## APIと動作

```ruby
tag.replace_mdta_items('com.example.key', [
  { data_type: 1, locale: 0, data: 'first'.b },
  { data_type: 1, locale: 1041, data: 'second'.b },
  { data_type: 33, locale: 0, data: "\0\xff".b },
  { data_type: 1, locale: 0, data: ''.b }
])
```

戻り値はtag自身。値配列は空でないArray、各値は厳密に `data_type`, `locale`, `data` のSymbolキーを持つHash。整数は符号なし32bit、dataはString。UTF-8の有効で非空、NULを含まないキーを要求する。値のStringのエンコーディングは問わず、バイト列として複製する。空バイナリは有効。

Rubyで入力全体を検証・複製し、nativeで構造を検証する。nativeは `MdtaState` の候補コピーに全値を設定し、成功後だけ状態を置換する。既存キーのkeys indexと最初の値の位置を維持し、新規キーはkeys末尾に追加する。値のkey/keyIndexはnative側で割り当てる。型、locale、バイト列、順序、重複をそのまま保存し、繰り返し呼んでも追記しない。

入力または構造が不正なら `TagLib::MP4::MdtaItemError`。保存は別操作。`file.save` 失敗は `MdtaSaveError`、rename前の失敗ではディスク原本は変わらず、メモリ上の編集値を保ち再試行できる。rename後の再open失敗は既存仕様どおり `committed: true` で通知する。nativeの直接save自体にファイル全体のトランザクションはない。

`set_mdta_item` の単一値置換の意味と挙動は変更しない。

## 対応範囲

| 構造 | 一括置換 |
| --- | --- |
| 単一 `moov/udta/meta`、mdta handler、有効なkeysとilst | 対応 |
| 上記ilst内のnumeric mdtaと通常iTunes atomの混在 | 対応、通常タグ・画像を保持 |
| 一つのnumeric item内の複数data、同じindexの複数item | 対応、値の順序を保持 |
| mdirのみ、mdtaなし、track内やmoov直下のmetaのみ | 拒否、新規mdta構造は生成しない |
| mdir/mdtaの別meta併存、複数mdta meta | 拒否、meta順序に依存しない |
| keys/ilst/hdlrの欠落または重複、壊れたkeys、重複キー、mdta以外のkey namespace | 拒否 |
| numeric indexの範囲外、壊れたnumeric itemのdata子atom | 拒否 |

今回の構造検証は既存の読み取りAPIを厳格な汎用MP4バリデータにするものではない。新APIが安全に編集可能な構造を限定する。字幕・音声・動画サンプルは既存保存処理で保護し、対象テストではサンプル署名とmdatを比較する。

## MListNewへの導入

必要バージョンは **taglib-ruby-plus 2.3.2.7** と、この改訂のパッチを適用した **TagLib 2.3.2**。gemとnativeライブラリを両方更新・再ビルドする。未公開の変更であり、配布済みバージョンではない。extconfは新APIのヘッダーとリンク先シンボルを検査する。

```ruby
# mux前の退避。key_indexは監査用に保持しても、復元時には渡さない。
saved = input.tag.mdta_items.group_by(&:key).transform_values do |items|
  items.map do |item|
    { data_type: item.data_type, locale: item.locale, data: item.data.dup }
  end
end

# mux後。outputは対応範囲のmdta構造を持つMP4であること。
saved.each { |key, values| output.tag.replace_mdta_items(key, values) }
output.save
```

全退避キーをまとめたトランザクションAPIではなく、指定キー単位で原子的に置換する。複数キーの入力を先に検査したい場合は呼出側で検査する。mux後がmdirのみの場合には例外が発生するため、muxでmdta構造を維持する必要がある。新規キーindexは出力ファイルのkeys末尾となり、入力動画のindexを強制するAPIではない。

## 検証方法

`test/mp4_mdta_replace_native.cpp` はnative直接保存の試作・回帰検証。`test/mp4_mdta_replace_test.rb` はFFmpegで生成した動画・音声・字幕入りfixtureを使う。既存キー・新規キー、各種値、通常タグ・画像・チャプター、反復保存、不正入力、非対応構造、保存失敗と再試行を確認する。原本動画には触れない。

実行結果と既存テストの失敗は[検証記録](Memos/2026-10-08-mdta一括置換の検証結果.md)に記載した。
