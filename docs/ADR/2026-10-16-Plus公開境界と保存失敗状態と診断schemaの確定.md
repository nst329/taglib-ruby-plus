# Plus公開境界・保存失敗状態・診断schemaの確定

日付: 2026-10-16
状態: 採用

## 背景

新しい編集セッションAPIが追加された一方、旧fork追加操作も通常のFile/Tagに公開され、利用入口が二重になっていた。
保存成功後のbaseline更新は原本を再読込しており、公開前の検証結果をそのまま利用する設計と一致していなかった。
診断結果とchapter sampleには旧オブジェクトや異なる外側のHash形式が残っていた。

## 決定と理由

- 旧fork追加メソッドを通常のFile/Tagではprivateにする。既存writerは`TagLib::MP4::Internal::File`で再利用し、構造テストも内部入口を明示する。削除してwriterを複製するより小さく、公開入口の二重化を防げる。
- 内部Fileだけが返すTagに旧操作を許可する。元から存在する低水準のsave/tag/title等は維持する。内部namespace・値・native変換に互換性は保証しない。
- native変換メソッドを非公開にし、型付きMetadataSnapshotをnativeなしで構築できるようにする。Artwork/ContentRatingもPlus namespaceから参照可能にする。
- 原本公開後は検証済みsnapshotとdigestを採用し、native再読込を行わない。公開前に確認した値との契約を揃え、公開後の失敗点を減らすためである。
- 公開前の失敗は候補を保持して再試行可能、公開後のすべての失敗はcommitted=trueかつclose以外を拒否する。別出力でも公開済み結果を再保存と誤認しないため同じ規則にする。
- cleanupの失敗でも公開状態を保持する。削除失敗のmessageと一時pathを記録し、先行エラーをcauseに残す。削除エラーが本来の失敗を隠さないようにする。
- 診断は全領域でstatus/data/issuesを返し、issueはcode/message/location/detailsに統一する。構造拒否だけを診断へ変換し、I/O障害やプログラミングエラーを空の成功結果へ変換しない。既存readerの広いrescueも構造拒否に限定し、metadata parserは専用ParseErrorで区別する。
- metadataを遅延読取し、完全snapshotを取得できないファイルでも診断を利用可能にする。保存時に必要な保持検査は省略しない。
- chapter_samplesは固定キーの所有済み不変Hashにする。旧snapshot型を公開契約に持ち込まず、ticks・署名・参照情報を保持する。

## 検証方針

Plus受入テストで公開前のwrite/verify/publish失敗、公開後の結果生成失敗、cleanupの単独・二重障害、出力競合を注入する。
原本bytes、出力、候補保持、再試行、公開後の全操作拒否、cause連鎖を確認する。新API経由でも参照解除・時間修復・非対象track構造の改変拒否を確認する。
診断の全領域schema・既知構造拒否・プログラミングエラー、chapter sampleの所有と編集時拒否を確認する。
既存の構造テストは内部Fileへ移行し、実ファイル原本には書き込まない。

## 制限

未index mdtaの限定保存は内部機能であり、新APIにunsafeな迂回操作を追加しない。
元taglib-rubyの低水準APIを通じた操作はPlusセッションの安全契約の対象外。
外部writerとの完全排他・電源断耐性・ACL完全保持・実映像全体のデコードは今回の保証に含めない。
