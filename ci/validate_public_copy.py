"""Check tracked Markdown for private conversational address and execution narration."""
import argparse
import re
import subprocess
import sys
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--root', type=Path, required=True)
args = parser.parse_args()
try:
    root = args.root.resolve(strict=True)
    result = subprocess.run(['git', '-C', str(root), 'rev-parse', '--show-toplevel'], capture_output=True, check=True)
    if Path(result.stdout.decode('utf-8').strip()).resolve() != root:
        raise ValueError('root must be the Git repository root')
    files = subprocess.run(['git', '-C', str(root), 'ls-files', '-z', '--', '*.md', '*.MD'], capture_output=True, check=True).stdout.split(b'\0')
    violations = []
    for item in files:
        if not item:
            continue
        name = item.decode('utf-8')
        path = root / name
        if '.claude' in Path(name).parts:
            continue
        if not path.resolve(strict=True).is_relative_to(root):
            raise ValueError('tracked path escapes repository')
        text = path.read_text(encoding='utf-8-sig')
        fence = None
        for number, line in enumerate(text.splitlines(), 1):
            marker = re.match(r'^ {0,3}(`{3,}|~{3,})(.*)$', line)
            if fence:
                if marker and marker.group(1)[0] == fence[0] and len(marker.group(1)) >= fence[1] and not marker.group(2).strip():
                    fence = None
                continue
            if marker and (marker.group(1)[0] != '`' or '`' not in marker.group(2)):
                fence = (marker.group(1)[0], len(marker.group(1)))
                continue
            content = re.sub(r'^\s*(?:(?:#{1,6}\s+|>\s*|[-+*]\s+|\d+[.)]\s+))*', '', line)
            address_text = re.sub(r'\]\([^)]*\)', ']()', content)
            address_text = re.sub(r'https?://\S+', '', address_text, flags=re.IGNORECASE)
            if re.match(r'(?i:rin)\s*[,，、：:]', content) or re.search(r'(?<![\w/])/(?i:rin),', address_text):
                violations.append((name, number, 'private-address'))
            if re.search(r'主会话|主代理|子代理|我给该子任务', content):
                violations.append((name, number, 'assistant-narration'))
    for name, number, rule in violations:
        print(f'{name}:{number}: {rule}')
    sys.exit(bool(violations))
except (OSError, UnicodeError, ValueError, subprocess.CalledProcessError) as exc:
    print(f'public-copy check error: {type(exc).__name__}', file=sys.stderr)
    sys.exit(2)
