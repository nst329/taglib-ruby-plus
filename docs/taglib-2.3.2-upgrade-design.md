# TagLib 2.3.2 対応設計

## 目的

TagLib 2.3.2 の MP4 チャプター保存修正と入力検証強化を利用者へ適用し、追加された MP4 コーデック情報を Ruby API から取得できるようにする。

## 変更方針

- ネイティブ拡張の最低要求を TagLib 2.3.2 にする。
- gem のバージョンを 2.3.2.1 にする。TagLib 2.3.2向けの下流改訂番号として管理する。
- `TagLib::MP4::Properties` に TagLib 2.3.2 の追加コーデック定数と `codec_id` を公開する。
- チャプター処理は既存の補助 C++ 層を維持し、TagLib 2.3.2 の実装へリンクする。
- 生成済み SWIG ラッパーは gem に含める。利用者に SWIG は要求しない。

## 公開 API

`TagLib::MP4::Properties` の定数値は TagLib の enum と一致させる。

```ruby
TagLib::MP4::Properties::AC3   # 3
TagLib::MP4::Properties::EAC3  # 4
TagLib::MP4::Properties::FLAC  # 5
TagLib::MP4::Properties::DTS   # 6
TagLib::MP4::Properties::Opus  # 7
```

`codec_id` は MP4 の sample description atom にある識別子を UTF-8 の Ruby 文字列で返す。識別できない値は TagLib の戻り値をそのまま返す。

## 検証

- TagLib 2.3.2 のヘッダーと共有ライブラリでネイティブ拡張を再ビルドする。
- 既存の全テストと MP4 の `codec_id` 検証を実行する。
- TagLib 2.3.1 以下は extconf のバージョン検査で拒否する。
- CI の vendor、compile、gem smoke test を TagLib 2.3.2 に統一する。

## 互換性

TagLib 2.3.1 以下ではビルドできない。実行時も、ビルド時にリンクした TagLib 2.3.2 以上の共有ライブラリを必要とする。Ruby の最低バージョンは 3.2 のままとする。
