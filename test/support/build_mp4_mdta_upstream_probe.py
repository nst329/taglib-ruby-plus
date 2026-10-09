#!/usr/bin/env python3
"""Build the standalone mdta proposal in an isolated copy, without applying it to the base tree."""
import argparse
import hashlib
import io
from pathlib import Path
import subprocess
import tarfile

REPO = Path(__file__).resolve().parents[2]


def run(*args):
    subprocess.run(args, check=True)


def main():
    """Prepare and optionally build the reviewable proposal; installation stays under workdir."""
    parser = argparse.ArgumentParser()
    parser.add_argument('--base-source', required=True, type=Path)
    parser.add_argument('--workdir', required=True, type=Path)
    parser.add_argument('--prepare-only', action='store_true')
    parser.add_argument('--ruby-state-transfer', action='store_true')
    parser.add_argument('--metadata-snapshot', action='store_true')
    args = parser.parse_args()
    work, base = args.workdir.resolve(), args.base_source.resolve()
    if work == REPO or REPO in work.parents or work == base or base in work.parents:
        raise RuntimeError('workdir must be isolated from the repository and base source')
    source = work / 'source'
    if source.exists():
        raise RuntimeError('use a fresh workdir; existing source is never overwritten')
    archive = subprocess.check_output(['git', '-C', str(base), 'archive', 'HEAD'])
    source.mkdir(parents=True)
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        tar.extractall(source, filter='data')
    original = (source / 'taglib/mp4/mp4tag.cpp').read_bytes()
    if hashlib.sha256(original).hexdigest() != '29c099a2bda2310c41178c46b6ee28f3ff1d5fd4fc4d896585e3f0a9377fff67':
        raise RuntimeError('base source must match the inspected TagLib 2.3.2 source')
    patch = REPO / 'patches/taglib/proposals/0001-mp4-mdta-api.patch'
    run('git', '-C', str(source), 'apply', '--check', str(patch))
    run('git', '-C', str(source), 'apply', str(patch))
    if args.ruby_state_transfer or args.metadata_snapshot:
        binding_patch = REPO / 'patches/taglib/proposals/0002-ruby-mdta-state-transfer.patch'
        run('git', '-C', str(source), 'apply', '--check', str(binding_patch))
        run('git', '-C', str(source), 'apply', str(binding_patch))
    if args.metadata_snapshot:
        run('git', '-C', str(source), 'apply', str(REPO / 'patches/taglib/proposals/0003-ruby-metadata-snapshot.patch'))
        run('git', '-C', str(source), 'apply', str(REPO / 'patches/taglib/0003-mp4-property-atoms.patch'))
    run('git', '-C', str(source), 'apply', str(REPO / 'patches/taglib/0004-mp4-chapter-movie-duration.patch'))
    if (source / 'taglib/mp4/mp4mdtalimits.h').read_bytes() != (REPO / 'test/support/mp4_mdta_upstream_limits.h').read_bytes():
        raise RuntimeError('native and test length validators must match exactly')
    if args.prepare_only:
        print(source)
        return
    run('cmake', '-S', str(source), '-B', str(work / 'build'),
        '-DCMAKE_BUILD_TYPE=Debug', '-DBUILD_SHARED_LIBS=ON', '-DBUILD_TESTING=OFF',
        '-DBUILD_EXAMPLES=OFF', '-DCMAKE_INSTALL_PREFIX=' + str(work / 'install'))
    run('cmake', '--build', str(work / 'build'), '-j', '6')
    run('cmake', '--install', str(work / 'build'))
    print(work / 'install')


if __name__ == '__main__':
    main()
