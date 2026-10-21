# ADR: SWIG trackingをRuby GC追随型の借用ラッパー管理へ変更する

> 2026-10-21追補: WeakRef経由の方式はLinux Ruby 4.0.7のcompaction後にSIGSEGVを再現したため、
> 現行実装では[直接GC登録のADR](2026-10-21-SWIG%20tracking%E3%82%92%E7%9B%B4%E6%8E%A5GC%E7%99%BB%E9%8C%B2%E3%81%B8%E5%A4%89%E6%9B%B4%E3%81%99%E3%82%8B.md)へ置き換えた。

## 背景

各SWIG bundleは、nativeポインタからRubyラッパーを引くために、`st_table`へ生のRuby `VALUE`を保存している。この表はRuby GCの管理対象ではないため、Rubyのcompaction後に移動前の`VALUE`を返す。`SWIG_Ruby_MangleStr`、`SWIG_Ruby_NewPointerObj`、および`SWIG_RubyUnlinkObjects`がその値をRubyオブジェクトとして扱うと、SIGSEGVになる。

このtrackingは単なる同一性キャッシュではない。Fileが所有するTag、ItemMap、Frameなどをnative側で破棄したとき、対応するRubyラッパーのポインタをnullにして`ObjectPreviouslyDeleted`にするためにも使われる。したがって、trackingを無効化するだけでは既存の安全性契約を壊す。

## 決定

- `void * -> VALUE` のtracking表を、`void * -> TrackingEntry *` に変更する。
- `TrackingEntry`はRuby `WeakRef`の`VALUE weakref`を保持し、そのアドレスを`rb_gc_register_address`でGCへ登録する。追跡表がラッパー本体を強参照しないため、ラッパーは通常どおり回収でき、`WeakRef`内部の参照はcompaction後のオブジェクト位置へ追随する。
- 追跡対象はnative側が所有する**借用ラッパーだけ**とする。Rubyがnativeオブジェクトを所有するラッパーはtracking表へ登録しない。
- `SWIG_RubyRemoveTracking`では、entryを表から削除してから`rb_gc_unregister_address`し、entryを解放する。
- `SWIG_RubyInstanceFor`、`SWIG_RubyUnlinkObjects`、および`SWIG_RubyIterateTrackings`はentry経由で現在の`VALUE`を使う。
- `SWIG_NewPointerObj`は`SWIG_POINTER_OWN`のときtrackingの検索・登録を行わない。コンストラクタが直接呼ぶ`SWIG_RubyAddTracking`は、ラッパーの`dfree`が`SWIG_RubyRemoveTracking`の場合だけ登録する。これにより、native destructorを持つRuby所有ラッパーを登録しない。
- 同じnativeポインタと同じRubyオブジェクトの再登録は何もしない。SWIGの既存仕様どおり、型違いのラッパーが同じnativeポインタを得た場合は既存entryを解放して新しいentryへ置き換える。
- 明示的な`File#close`と`FileRef#close`は、変換済みnativeポインタをローカル変数へ保存し、レシーバー自身のnativeポインタをnullにしてからnativeを解放する。これにより、途中で失敗しても二重closeとGC finalizerでの二重deleteを防ぐ。
- `TagLib::MP4::Item.from_bool`、`from_char`、`from_uchar`、`from_uint`、`from_int`、`from_long_long`、`from_string_list`、`from_cover_art_list`、`from_byte_vector_list`など、`new`で生成したオブジェクトを返すAPIには`%newobject`を指定して`SWIG_POINTER_OWN`を付与する。これは既存のメモリリークを直し、借用trackingとの混同を防ぐ。

## 理由

`rb_gc_register_address`は、C領域にある`VALUE`への参照をRuby GCへ明示的に知らせるAPIである。ここで登録するのはラッパー本体ではなく`WeakRef`オブジェクトなので、compaction時の`WeakRef`の移動は安全に追随しつつ、追跡表がラッパーを強参照してnativeリソースを保持し続けることを防げる。

tracking表がラッパー本体を強く保持すると、Ruby所有のFileやItemもGCされず、nativeリソースが解放されない。このため、弱参照を使い、Ruby所有ラッパーはtracking対象から外す。借用ラッパーは、親nativeオブジェクトの破棄またはコンテナ要素の置換時に既存のunlink処理で表から除去される。`SWIG_RubyUnlinkObjects`はラッパーをnull化した後にentryも削除する。

`ObjectSpace::WeakMap`はRubyレベルでは移動GCに追随するが、既存のnative finalizerからRubyメソッドを呼んでWeakMapを検索する設計は複雑になるため採用しない。標準ライブラリの`WeakRef`をentry内に保持し、`rb_gc_register_address`でその`VALUE`だけを保護する。

## 実装境界

修正対象はMP4 bundleだけではない。`%trackobjects`を使う11個の生成bundleが同じruntimeを持つため、`tasks/swig_ruby_runtime_patch.rb`へruntime変換を集約し、`tasks/swig.rake`で全wrapperの生成直後に適用する。生成済みwrapperにも同じ変換結果を反映し、通常の再生成で修正が失われないようにする。

Ruby 3.2を最低対応版とし、Ruby 3.2以上とRuby 4を同じruntime実装でサポートする。`rb_gc_register_address`と`rb_gc_unregister_address`は両世代で利用できるため、Ruby世代ごとの分岐は設けない。gemspecには`required_ruby_version >= 3.2`を指定する。同じgem releaseで全bundleを再生成・配布し、旧runtime bundleとの同一プロセス混在だけはサポートしない。既存の`@__safetrackings__`を新しいentry表へ置き換える。

WeakRefをentryで保持するため、実装時に全形式について「借用ラッパー型、native所有者、破棄または置換契機、unlink箇所」を棚卸しする。所有者のcloseとGC finalizerの両方でtracking数が開始値へ戻らない形式がある場合、その形式を残したまま修正を完了扱いにしない。

SWIG本体を4.5へ更新する作業はこの修正と分離する。4.5のtemplateにも生`VALUE`のtracking構造が残るため、更新だけでは根本修正にならない。

## 影響

- tracking表は借用ラッパーを`WeakRef`で参照する。親nativeオブジェクトが生存している間は同一wrapperの再利用とunlinkが可能で、ラッパー自体は不要になればGCで回収される。
- File close、Frame削除、Item置換・削除は従来どおり借用ラッパーを`ObjectPreviouslyDeleted`にする。
- Ruby所有のFile、ItemMap、Itemなどは通常どおりGC finalizerでnativeリソースを解放する。
- `Item.from_*`で返すItemはRuby所有になる。これは公開APIの所有権を正しくする変更であり、Rubyコード上の操作方法は変えない。

## 検証

1. `GC.start; GC.compact`とRubyオブジェクトの割当後に、同じTagからItemMapを再取得し、`insert`まで正常終了する子プロセステストを追加する。
2. 上記をYJIT有効・無効で実行し、どちらもSIGSEGVしないことを確認する。
3. File close後、Tag、ItemMap、Item、CoverArt、Frameが`ObjectPreviouslyDeleted`になる既存テストを維持する。
4. File close後の`SWIG_TRACKINGS_COUNT`が開始時の値へ戻ることをMP4で確認し、他形式にも同じ確認を拡張する。
5. `Item.from_*`を多数生成してGCし、Ruby所有Itemがtracking表に残らないことをテストする。
6. Ruby 3.2、Ruby 4.0.6、およびRuby 4.0のcompaction修正版で同じ子プロセステストを実行する。
7. ASan/UBSan buildでcompactionなしのFile open/edit/close反復も実行し、別のnative heap破壊がないことを確認する。
8. 明示closeを2回呼ぶ場合、close後にGCする場合、closeせず所有FileをGCする場合を反復し、二重deleteがなく借用ラッパーが`ObjectPreviouslyDeleted`になることを確認する。
9. 同一nativeポインタの再利用テストを追加し、同一Rubyオブジェクトはno-op、型違いのwrapperは既存SWIG仕様どおり置換されることを確認する。

## 未決事項

- 元の実運用プロセスでcompactionが実行されたかは、過去ログからは確認できない。この設計は確認済みのbinding不具合を修正するが、実運用クラッシュを単独で説明できるかは修正前後とRuby版比較で確認する。
- `WeakRef`の生成・解決コストと、実運用の長時間処理におけるtracking表の増減を計測する。
