"""独立プロセスごとに公開APIを実行し、Ruby/native論理I/Oの比較用JSONを出力する。"""

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    """fixtureと変更前後のlibを受け取り、同じ操作・計測条件で比較する。"""
    parser = argparse.ArgumentParser()
    parser.add_argument("--ruby", required=True)
    parser.add_argument("--meter", required=True)
    parser.add_argument("--before-lib")
    parser.add_argument("--after-lib", required=True)
    parser.add_argument("fixtures", nargs="+")
    parser.add_argument("--operations", nargs="+", default=["read", "property", "diagnose", "item", "mdta", "replace", "combined", "noop", "copy"])
    args = parser.parse_args()
    probe = Path(__file__).with_name("plus_mp4_io.rb").resolve()
    operations = args.operations
    versions = [("after", args.after_lib)]
    if args.before_lib:
        versions.insert(0, ("before", args.before_lib))
    for revision, library in versions:
        for fixture in args.fixtures:
            for operation in operations:
                measured = None
                for counters in [True, False]:
                    with tempfile.TemporaryDirectory(prefix="plus-io-") as work:
                        env = dict(os.environ, PLUS_IO_DIRECTORY=work, TMPDIR=work,
                                   PLUS_IO_METER=str(Path(args.meter).resolve()),
                                   DYLD_INSERT_LIBRARIES=str(Path(args.meter).resolve()),
                                   PLUS_BINDING_LIB=str(Path(library).resolve()))
                        env.pop("PLUS_IO_UNMETERED", None)
                        if not counters:
                            env["PLUS_IO_UNMETERED"] = "1"
                        result = subprocess.run([args.ruby, str(probe), str(Path(fixture).resolve()), operation],
                                                env=env, text=True, capture_output=True, check=True)
                        row = json.loads(result.stdout)
                        if counters:
                            measured = row
                        else:
                            measured["uninstrumented_seconds"] = row["elapsed_seconds"]
                measured["revision"] = revision
                print(json.dumps(measured, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
