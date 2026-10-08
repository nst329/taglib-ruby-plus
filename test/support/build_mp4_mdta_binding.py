#!/usr/bin/env python3
"""Compile Ruby bindings in an isolated workspace against a selected native prefix."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess

REPO = Path(__file__).resolve().parents[2]


def main():
    """Copy build inputs only, keeping installed bindings and the repository's binaries untouched."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--native-prefix', required=True, type=Path)
    parser.add_argument('--workdir', required=True, type=Path)
    parser.add_argument('--ruby', default='/opt/homebrew/opt/ruby/bin/ruby')
    args = parser.parse_args()
    work, prefix = args.workdir.resolve(), args.native_prefix.resolve()
    if work.exists() or work == REPO or REPO in work.parents or prefix in work.parents:
        raise RuntimeError('use a fresh isolated workdir outside repository and native prefix')
    work.mkdir(parents=True)
    ignored = shutil.ignore_patterns('*.bundle', '*.so', '*.o', '*.pyc', '__pycache__', 'Makefile', 'mkmf.log')
    for directory in ['lib', 'ext', 'test']:
        shutil.copytree(REPO / directory, work / directory, ignore=ignored)
    env = dict(os.environ, TAGLIB_DIR=str(prefix),
               TAGLIB_RUBY_LDFLAGS='-Wl,-rpath,' + str(prefix / 'lib'))
    for extconf in sorted((work / 'ext').glob('*/extconf.rb')):
        subprocess.run([args.ruby, 'extconf.rb'], cwd=extconf.parent, env=env, check=True)
        subprocess.run(['make', '-j', '4'], cwd=extconf.parent, env=env, check=True)
        binaries = list(extconf.parent.glob('*.bundle')) + list(extconf.parent.glob('*.so'))
        if not binaries:
            raise RuntimeError(f'extension binary missing: {extconf.parent}')
        for binary in binaries:
            shutil.copy2(binary, work / 'lib' / binary.name)
    print(work)


if __name__ == '__main__':
    main()
