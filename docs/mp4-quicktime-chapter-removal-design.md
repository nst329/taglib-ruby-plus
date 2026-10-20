# Plus公開APIによるQuickTime chapter限定除去

状態: 実装済み。2026-10-20。対象versionは2.3.2.30。

## 前提と判断

`file.chapters`と既存setterはNeroとQuickTimeの全体完全読取を要求するため、片方が壊れたファイルの値取得には使わない。`read_chapters(style:)`は指定形式だけを完全読取し、別形式の異常を前提条件にしない。

```ruby
TagLib::Plus::MP4.open(stage_path) do |file|
  nero = file.read_chapters(style: :nero)
  # 正常Neroなら固定されたTagLib::Plus::MP4::Chapter配列、不在ならnil。
  plan = file.plan_quicktime_chapter_removal
  if plan.status == :removable
    file.remove_quicktime_chapters(plan: plan)
    file.save!
  end
end
```

`plan.status`は`:removable`、`:blocked`、`:complete`、`:absent`のいずれかである。`:complete`は正常QuickTimeを意味し、削除しない。`:absent`はQuickTimeがないことを意味する。`:blocked`は`reason`と`reason_code`を持ち、削除を拒否する。Neroの異常も`:blocked`であり、空のNero値や空の削除配列には変換しない。

`read_chapters(style:)`は指定形式が存在すれば凍結した配列、存在しなければ`nil`を返す。指定形式の構造異常は`TagLib::Plus::MP4::Error`で返し、`code`と`issues[].code`で公開reason codeを判別できる。`Error`のstyle属性、英文例外文、causeの型や文言には依存しない。

## 除去判定

除去計画を作る前に、同じ原本世代から次を確認する。

- Neroは完全読取または不在である。
- QuickTimeは完全読取できない、または完全読取できても既知のchapter時間診断に不整合がある。
- `chap`参照が音声trackから出ている。
- 全参照が実在する同一の専用`text` trackを指している。
- 対象trackを指す他種`tref`、非音声からのchap参照、通常字幕として使われる共有関係がない。
- atom構造、data reference、offset、件数、境界が既存の限定編集範囲に収まる。

欠落参照は実在trackを推測しないため`:missing_reference`で拒否する。複数target、非音声source、共有参照、未知構造、外部data reference、上限超過、読取失敗、Nero異常も拒否する。unsupportedを理由に一律削除する判定はない。

編集では対象音声の`chap`参照と専用text `trak` atomを同時に除去する。通常字幕、映像、音声、artwork、metadata、他種`tref`、残りのtrack atomは保持する。mdatは再配置せず逐次コピーするため、除去したtext trackのsample bytesも含むmedia payloadは保持される。これにより参照のないtext payloadを通常字幕へ再分類せず、既存trackのoffsetを壊すmedia再書込も避ける。

計画はsource pathと開いた世代のstat tokenに結び付く。計画後の入力変更、別Fileで作った計画、計画の改変は編集登録前に`:source_changed`または`:invalid_plan`として拒否する。metadata編集、chapter編集、時間修復、別のrepair slotとの同時保留も既存の`:pending_changes`契約で拒否する。

## 保存後検証

既存`save!`の一時出力、独立再読込、原子公開、`committed`／`temporary_path`／cleanup失敗契約を使う。検証では、Neroが正常なら開始時刻・名称・順序と`chpl` payload SHA-256を比較し、不在なら不在を比較する。QuickTimeは不在であり、対象trackと対象参照が消えていることを確認する。既存の保持signatureとmdatの独立size・SHA-256検証で、非対象mediaを比較する。

保存前の失敗は原本と計画を保持して再試行できる。公開後のreopen、結果生成、cleanup失敗は既存どおり`committed: true`を含む場合があり、Fileを再利用しない。別出力保存では原本を置換せず、保存後に出力を独立openして確認する。

## I/O特性

計画作成では同じFile世代のatom parserを使い、Neroの完全値とQuickTimeの構造・参照・時間診断を媒体全体のメモリ保持なしで確認する。保存時はmoovの置換計画を使い、原本から一時出力への逐次コピー、出力の独立走査、native再読込による値・構造検証を行う。mdat payloadはメモリへ蓄積せず、コピー中のhashで比較する。新しい全ファイルコピー、FFmpeg依存、アプリケーション固有backup／DB処理は追加しない。

既存の`save!`検証に必要なI/Oは省略していない。計画解析と保存検証で、同一世代の既取得reader・diagnostic値を再利用し、変更対象以外のmedia bytesを再シリアライズしない。効果を未計測の実測値として扱わず、詳細な回数・bytesは環境別のI/O probeで測定する。

## MListNewとの境界

MListNewはstage上で次の順序を選択できる。

ここでいう同じstageは同じstage pathを指す。Plusの一つの`File`へmetadata編集とrepairを同時に保留する契約ではないため、各段階を保存してcloseし、同じstage pathを独立openして次の段階へ渡す。

1. metadataを修復し、保存前後のmetadata・artwork・非対象mediaを独立比較する。
2. `read_chapters(style: :nero)`または`diagnose(:chapters)`でNeroの正常／不在を確認する。
3. `plan_quicktime_chapter_removal`のstatusとreason codeを記録し、`:removable`だけを`remove_quicktime_chapters(plan:)`へ渡す。
4. `save!`でstageを保存し、結果の`verification`、`committed`、`temporary_path`を既存契約どおり扱う。
5. 独立再openでNero、QuickTime不在、target track／参照不在、字幕・画像・非対象参照・media payloadを比較する。
6. 必要なら字幕muxを行い、MListNew側の責務としてNeroを復元してから、Neroの値と`chpl` payloadを再検証する。

正常Nero／QuickTime併存をNeroへ統一するかどうかは呼出し側が決める。gemは正常形式を暗黙に削除しない。metadata修復、時間修復、字幕muxを同じ`save!`へ混在させることは、既存の失敗契約と責務分離に従って拒否する。

## 残存リスク

外部writerとの完全排他、電源断時のfilesystem耐性、ACLの完全保持、fragmented MP4、未知atom、複雑なedit list、外部data reference、text trackを共有する未認識用途は対象外である。除去したtext sample bytesをmdatから物理回収しないため、ファイルの物理縮小やpayloadの再配置は保証しない。実ユーザーMP4と実DBへの書込み、gem配布、pushはこの変更では行わない。
