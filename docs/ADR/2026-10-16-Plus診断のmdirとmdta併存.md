# Plus診断でmdirとmdtaの併存を許可する

## 状態

採用

## 背景

公開snapshot保存は、通常itemを保持する`mdir` contextと、追加したmdtaを保持する`mdta` contextを同じ`moov/udta`へ生成する。この正当な保存結果を、metadata contextが複数という理由だけで診断が拒否していた。

## 決定

同じ`moov/udta/meta`位置に`mdir`と`mdta`が1つずつ存在し、`mdir`のkeysが空である構造を公開APIが生成する正当なcontext pairとして扱う。その他のhandler組み合わせ、重複context、handlerとkeysの不整合は引き続き診断で拒否する。

## 理由

Plusのsnapshot保存結果だけを正当に認識し、任意の複数meta contextを無条件に許可しないため。native statusがunsupportedでも、この検証済みpairについては公開診断のunsupported_native_structureを付与しない。

## 検証

- 通常itemを持つfixtureへmdtaを公開snapshotで追加保存し、再読込後の`diagnose(:metadata)`がcompleteになることを確認。
- 通常itemとmdtaの値、型、locale、bytes、順序を確認。
- metadata snapshot構造テストで不正構造の拒否を確認。
