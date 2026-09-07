# MP4チャプターAPI設計

## 1. 適用範囲

| 項目 | 内容 |
|---|---|
| TagLib | 2.3.2以上（`>= 2.3.2`） |
| taglib-ruby-plus | 2.3.2（TagLibの要求バージョンとは別のプロジェクト番号） |
| 初期対応OS | macOS、Linux |
| チャプター形式 | Nero、QuickTime |
| 保存 | 通常保存、チャプター専用保存 |

今回の対象外:

- `.chapters.txt`のインポート・エクスポート
- properties、STEM（チャプター完了後に対応）
- Matroska
- Windowsバイナリgem

## 2. データモデル

`TagLib::MP4::Chapter`をRuby管理下の値オブジェクトとして公開する。

```ruby
chapter = TagLib::MP4::Chapter.new(
  start_time: 0,
  title: "Opening"
)
```

| 属性 | Ruby型 | 制約 |
|---|---|---|
| `start_time` | `Integer` | ミリ秒単位、0以上 |
| `title` | `String` | UTF-8、NUL文字不可、空文字可 |

C++のChapterListは公開しない。C++とRubyの境界ではChapterを双方向にコピーする。

## 3. 公開API

### 3.1 共通API

```ruby
file.chapters
file.chapter_style
file.set_chapters(chapters, style: :preserve)
file.remove_chapters

file.set_chapters(chapters, style: :nero)
file.set_chapters(chapters, style: :quicktime)
file.set_chapters(chapters, style: :both)
```

`chapter_style`は`:none`、`:nero`、`:quicktime`、`:both`のいずれかを返す。

`style`は`:preserve`、`:nero`、`:quicktime`、`:both`を受け付ける。省略時は`:preserve`とする。不正値は`ArgumentError`にする。

### 3.2 形式別API

```ruby
file.nero_chapters
file.set_nero_chapters(chapters)
file.remove_nero_chapters

file.quicktime_chapters
file.set_quicktime_chapters(chapters)
file.remove_quicktime_chapters
```

形式別APIはC++ APIの直接公開ではなく、安全なRubyラッパーとする。対応関係は次のとおり。

| 形式別API | 同等の共通API |
|---|---|
| `nero_chapters` | `chapters(style: :nero)` |
| `quicktime_chapters` | `chapters(style: :quicktime)` |
| `set_nero_chapters(value)` | `set_chapters(value, style: :nero)` |
| `set_quicktime_chapters(value)` | `set_chapters(value, style: :quicktime)` |
| `remove_nero_chapters` | `remove_chapters(style: :nero)` |
| `remove_quicktime_chapters` | `remove_chapters(style: :quicktime)` |

### 3.3 保存API

```ruby
file.save          # タグと変更済みチャプターを保存
file.save_chapters # 変更済みチャプターだけを保存
```

setterとremoveメソッドはメモリ上の状態だけを変更する。ファイルへの書き込みは利用者が明示的に実行する。

## 4. 操作仕様

### 4.1 読み取り

形式指定時と形式別getterは、指定形式だけを読み取る。もう一方の形式は参照せず、競合判定もしない。読み取り結果が存在しない場合は空配列を返す。

形式未指定の`chapters`は次の順で判定する。

1. 両形式とも存在しない場合は空配列を返す。
2. 片方だけ存在する場合は、その一覧を返す。
3. 両方が同一の場合は、共通の一覧を返す。
4. 両方が異なる場合は`TagLib::MP4::ChapterConflictError`を送出する。

同一性の判定条件:

- 件数と順序が一致する。
- タイトルが完全一致する。
- 対応する開始時刻の差が1ミリ秒以内である。

### 4.2 設定

| 呼び出し | 変更対象 |
|---|---|
| `set_chapters(value)` | `style: :preserve`と同じ |
| `set_chapters(value, style: :preserve)` | 既存形式を維持。既存形式がなければ両形式を新規作成 |
| `set_chapters(value, style: :nero)` | Neroだけ |
| `set_chapters(value, style: :quicktime)` | QuickTimeだけ |
| `set_chapters(value, style: :both)` | NeroとQuickTimeの両方 |
| 形式別setter | 対応形式だけ |

`style: :nero`ではQuickTimeを変更せず、`style: :quicktime`ではNeroを変更しない。

`:preserve`は設定前の`chapter_style`に従う。

| 設定前の形式 | 更新対象 |
|---|---|
| `:none` | NeroとQuickTimeを新規作成 |
| `:nero` | Neroだけ |
| `:quicktime` | QuickTimeだけ |
| `:both` | NeroとQuickTimeの両方 |

`:preserve`で既存の両形式が競合していても、両方を同じ新しい一覧で置換して競合を解消する。

全件を検証してから対象形式を一括置換する。両形式の設定中に失敗した場合は例外を送出し、メモリ上の状態を変更前へ戻す。ロールバックできなければ、そのFileからの保存を拒否する。

### 4.3 削除

| 呼び出し | 削除対象 |
|---|---|
| `remove_chapters` | NeroとQuickTimeの両方 |
| `remove_chapters(style: ...)` | 指定形式だけ |
| 形式別remove | 対応形式だけ |

`set_chapters([])`も対象形式の全削除として扱う。

### 4.4 入力検証

C++へ渡す前に一覧全体を検証する。

- 要素が`TagLib::MP4::Chapter`であること。
- `start_time`が0以上の整数であること。
- 開始時刻が昇順で重複しないこと。
- 開始時刻が音声または動画の長さ以内であること。
- `title`が有効なUTF-8であり、NUL文字を含まないこと。

不正入力は`ArgumentError`にする。

開始時刻の上限検証には音声または動画の長さを使用する。`File`を
`readProperties: false`で開いた場合でも、チャプター設定時に内部で
プロパティを読み込み、検証を省略しない。長さを取得できない場合も
`ArgumentError`にする。

## 5. 保存仕様

### 5.1 `File#save`

既存のTagLib `MP4::File::save()`を呼び出す。

- MP4タグと変更済みチャプターを保存する。
- 成功時`true`、失敗時`false`を返す。
- `ilst`を認識済みItemから再構築する。
- 未知または解析不能なItemの保持は保証しない。

### 5.2 `File#save_chapters`

TagLibの通常保存を呼ばず、変更済みチャプターだけを保存する。

- `MP4::Tag::save()`を呼ばない。
- 変更されたNero／QuickTimeチャプターだけを書き込む。
- 既存の`ilst`とその子atomを変更しない。
- タグ、カバーアート、STEMの未保存変更を書き込まない。
- チャプター保存に必要な親atomサイズ、トラック参照、chunk offset、paddingは更新できる。
- 変更がなければ書き込まず`true`を返す。
- 読み取り専用または無効なFileでは`ChapterSaveError`を送出する。
- 成功した形式の変更済み状態を解除する。
- 保存処理に失敗した場合は`false`を返さず、`TagLib::MP4::ChapterSaveError`を送出する。
- 失敗時は変更済み状態を保持し、再試行できるようにする。

チャプターだけを変更する場合は`save_chapters`を使用する。タグ変更も保存する場合は`save`を使用する。

## 6. 安全性

### 6.1 所有権

- C++所有のChapterListや借用ポインターをRubyへ返さない。
- getterはRuby管理下へコピーしたChapter配列を返す。
- setterは検証済みRuby値からC++のChapterListを作成する。
- FileをcloseまたはGCした後も、取得済みChapterを参照できる。
- SWIGの既定所有権だけに依存しない。

### 6.2 既存データの保持

`save_chapters`では次を保証する。

- `ilst`以下の全atomの生バイトが保存前後で一致する。
- タグ、カバーアート、STEMのメモリ上の変更を保存しない。
- チャプター変更がなければファイル全体を変更しない。
- 通常の字幕streamを追加、削除、chapter trackへ変換しない。

## 7. 実装構造

```text
公開API
├── 共通API
├── Nero形式別API
├── QuickTime形式別API
├── save
└── save_chapters
          │
          ▼
チャプター操作層
├── Ruby ChapterとChapterListの相互コピー
├── 入力検証
├── 既存chapter形式の判定と`:preserve`の解決
├── 形式別の取得・設定・削除
├── 同一性・競合判定
├── 変更状態とロールバック管理
└── チャプター専用保存
          │
          ▼
TagLib 2.3.2
```

- 共通APIと形式別APIは同じ内部関数を利用する。
- TagLibの形式別メソッドは直接SWIG公開せず、`%ignore`した上で補助C++関数から呼び出す。
- 新しいC拡張は作らず、既存の`taglib_mp4`拡張へ追加する。
- `save_chapters`は`MP4::File::save()`を呼ばない。

TagLib 2.3.2にはチャプター専用保存の公開APIがないため、既存の公開`NeroChapterList`／`QtChapterList`を呼び出す補助C++層を`taglib_mp4`へ実装する。

- C++のChapterListはSWIGで公開せず、Rubyの値オブジェクトとの間でコピーする。

主な変更箇所:

- `ext/taglib_mp4/taglib_mp4.i`
- `ext/taglib_mp4/taglib_mp4_wrap.cxx`
- `lib/taglib/mp4.rb`
- `test/mp4_chapters_test.rb`
- `test/data/`のMP4チャプターfixture
- TagLibバージョン検査箇所
- `README.md`、`CHANGELOG.md`、`lib/taglib/version.rb`

## 8. テスト

### 8.1 読み取り

- チャプターなし、Neroだけ、QuickTimeだけを読み取る。
- 両形式が同一の場合に共通一覧を返す。
- 両形式が異なる場合に`ChapterConflictError`を送出する。
- 1ミリ秒差を同一、2ミリ秒差を競合と判定する。
- 形式別APIと対応する`type`指定APIの結果が一致する。

### 8.2 設定と削除

- `chapter_style`が`:none`、`:nero`、`:quicktime`、`:both`を正しく返す。
- `style: :preserve`が既存形式を維持する。
- 既存形式がない`:preserve`で両形式が新規作成される。
- `style: :nero`、`:quicktime`、`:both`が指定対象だけを変更する。
- 全削除と形式別削除を検証する。
- UTF-8、空タイトル、NUL文字、不正時刻、時刻境界を検証する。
- 保存後に開き直して内容を確認する。

### 8.3 保存と保持

- `save`がタグとチャプターを保存する。
- `save_chapters`がチャプターだけを保存する。
- `save_chapters`前後で`ilst`以下の生バイトが一致する。
- タグ、カバーアート、STEMの未保存変更が書き込まれない。
- 実ファイルを用いて既存タグ、複数artwork、通常の字幕streamが保存前後で保持される。
- 通常の字幕streamについて、stream数、track ID、codec、言語、データのハッシュが一致する。
- チャプター変更がない場合、ファイル全体が変更されない。
- 保存失敗時に`ChapterSaveError`が送出され、変更状態が残って再試行できる。

### 8.4 所有権と回帰

- FileのcloseとGC後もコピー済みChapterが有効である。
- 既存のMP4 Item、CoverArt、読み書きAPIに回帰がない。
- TagLib 2.3.2未満では`TagLib >= 2.3.2`が必要であることを示してビルドを中止する。

## 9. 完了条件

- macOS/LinuxのTagLib 2.3.2でビルドと全テストが成功する。
- 公開APIと使用例が`docs/taglib/mp4.rb`に記載される。
- READMEにTagLib 2.3.2以上が必要であることを記載する。
- CHANGELOGに追加API、互換性、Windowsが初期保証対象外であることを記載する。
- taglib-ruby-plusのバージョンは2.3.2とする。番号はTagLibの要求バージョンとは別管理だが、今回は同じ数値になる。

## 10. gem配布

taglib-ruby-plusはsource gemとして配布する。gemのインストール時にネイティブ
拡張をビルドし、利用者の環境にあるTagLib 2.3.2以上へリンクする。

- gemバージョンは`2.3.2`、TagLibの最低バージョンは`2.3.2`として別管理する。
- 生成済みSWIGラッパーをgemに含め、利用者側でSWIGを要求しない。
- インストール時にはTagLibのヘッダー、ライブラリ、C++17コンパイラを必要とする。
- 実行時にはリンク対象のTagLib共有ライブラリを必要とする。
- 初期対象OSはmacOSとLinuxとし、Windowsバイナリgemは後続対応とする。
