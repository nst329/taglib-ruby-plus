# ADR: SWIG借用wrapperのVALUEを直接GC登録する

日付: 2026-10-21
状態: 採用・実装済み

## 背景

タグpush後のLinux Ruby 4.0.7 CIで、`MP4ItemsTest`のGC compaction中に
`ItemMap#item_map`が`SWIG_RubyAddTracking`経由でSIGSEGVになった。既存実装は
借用wrapperを`WeakRef`へ包み、その`VALUE`だけを`rb_gc_register_address`へ登録していたが、
compaction後の`WeakRef#__getobj__`呼出し境界で安全性を確認できなかった。

## 決定

- 借用wrapperのRuby `VALUE`をtracking entryへ直接保存し、entry内のVALUEアドレスを
  `rb_gc_register_address`で登録する。
- `SWIG_RubyInstanceFor`とiterate処理はRubyメソッド呼出しを挟まず、登録済みVALUEを返す。
- `SWIG_RubyRemoveTracking`はst tableからentryを削除してから`rb_gc_unregister_address`し、entryを解放する。
- Ruby所有wrapperは従来どおりtracking対象外とする。借用wrapperはnative所有者のclose・置換まで
  GC rootとなるが、tracking解除後は通常のGC対象へ戻る。
- 11個のSWIG bundleへ同じruntimeを適用し、生成後patchでもこの方式を維持する。

## 理由

`rb_gc_register_address`は登録したC領域のVALUEをGC compaction時に更新するため、
tracking tableへ生VALUEを置く既存の問題を解消できる。借用wrapperを一時的に強参照するコストは
native所有者の寿命内に限定され、既存のclose・置換時unlinkとtracking数契約を維持できる。
WeakRefの生成、例外処理、`__getobj__`呼出しを削除するため、compaction中のRubyメソッド境界と
追加のwrapper解決を避ける。

## 検証

- macOS arm64 / Ruby 4.0.7で`test/mp4_items_test.rb`: 30 tests / 107 assertions、失敗0。
- 同環境で全体`rake test`: 622 tests / 113,749 assertions、失敗0、13 omissions。
- GC compaction後に`item_map`取得と一時Item挿入を100回繰り返す既存子プロセステストが成功。
- Linux CIの失敗ログでは、旧実装が`SWIG_RubyAddTracking`からRuby method table lookupへ進んでSIGSEGVしていた。
  Linux runnerでの修正後再実行は次版タグで確認する。

## 影響

- 借用wrapperは親native objectが生きている間だけ強参照されるため、長寿命Fileでは保持量が増える。
- `File#close`、Item置換・削除、tracking countの公開契約は変更しない。
- Ruby所有のfactory Itemは従来どおりtrackingせず、native destructorで解放する。
