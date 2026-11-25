#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys


def main():
    args = sys.argv[1:]
    swift = os.environ['CPA_REAL_SWIFT']
    if not args or args[0] != 'build':
        os.execv(swift, [swift, *args])
    if args.count('--build-system') != 1 or args[args.index('--build-system') + 1] != 'swiftbuild' or args.count('--toolset') != 1:
        raise ValueError('unexpected xtool Swift build invocation')
    args[args.index('--build-system') + 1] = 'native'
    index = args.index('--toolset')
    if not args[index + 1].endswith('/toolset-swb.json'):
        raise ValueError('unexpected xtool toolset')
    del args[index:index + 2]
    if any(value in args for value in ('--swift-sdk', '-j', '--jobs', '-v', '--verbose')):
        raise ValueError('conflicting Swift options')
    args += ['--swift-sdk', os.environ['CPA_SWIFT_SDK'], '-j', '2', '-v', '-Xlinker', '-platform_version', '-Xlinker', 'ios', '-Xlinker', os.environ['CPA_MIN_IOS'], '-Xlinker', os.environ['CPA_SDK_VERSION']]
    root = Path(os.environ['CPA_DERIVED']).resolve(strict=True)
    if Path.cwd().resolve(strict=True) != root:
        raise ValueError('unexpected build directory')
    build = root / '.build'
    if build.exists() and any(path.name in ('CPAQuotaApp-App', 'CPAQuotaActivityExtension-Extension') for path in build.rglob('*')):
        raise ValueError('build product already exists')
    code = subprocess.call([swift, *args])
    if code:
        return code
    query = subprocess.run([swift, *args, '--show-bin-path'], check=True, stdout=subprocess.PIPE, text=True)
    lines = query.stdout.splitlines()
    if len(lines) != 1:
        raise ValueError('unexpected Swift bin path')
    binpath = Path(lines[0]).resolve(strict=True)
    buildroot = build.resolve(strict=True)
    if not binpath.is_dir() or buildroot not in binpath.parents:
        raise ValueError('Swift output is outside derived build tree')
    products = {}
    for name in ('CPAQuotaApp-App', 'CPAQuotaActivityExtension-Extension'):
        product = binpath / name
        if product.is_symlink() or not product.is_file():
            raise ValueError('missing build product: ' + name)
        products[name] = hashlib.sha256(product.read_bytes()).hexdigest()
    destination = buildroot / 'out' / 'Products' / 'Release-iphoneos'
    if destination.exists() or destination.is_symlink():
        raise ValueError('xtool output mapping already exists')
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.symlink_to(binpath, target_is_directory=True)
    with Path(os.environ['CPA_SHIM_RECEIPT']).open('x', encoding='utf-8') as stream:
        json.dump({'args': args, 'products': products}, stream)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print('swift shim: ' + str(error), file=sys.stderr)
        sys.exit(1)
