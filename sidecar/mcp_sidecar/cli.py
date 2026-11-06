"""Agent Lab CLI: JSON stdin/stdout; Godot owns world state, disk owns documents."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import socket
import sys

from .fs_tools import ScopedFs, FsError


def rpc(tool, args=None):
    with socket.create_connection(('127.0.0.1', int(os.getenv('AGENT_LAB_PORT', '7331'))), timeout=15) as sock:
        sock.sendall((json.dumps({'tool': tool, 'args': args or {}}) + '\n').encode())
        return json.loads(sock.makefile('rb').readline())


def documents(fs):
    result = []
    for p in sorted(fs.root.rglob('*')):
        if not p.is_file():
            continue
        rel = p.relative_to(fs.root).as_posix()
        try:
            full = fs.resolve_safe(rel)
            content = full.read_bytes()
            result.append({'path': rel, 'bytes': len(content), 'version': hashlib.sha256(content).hexdigest(),
                           'text': _is_text(content)})
        except (FsError, OSError):
            continue
    return result


def _is_text(content):
    try:
        content.decode('utf-8')
        return b'\x00' not in content
    except UnicodeDecodeError:
        return False


def file_action(fs, command, args):
    path = args.get('path', '.')
    if command == 'list':
        return fs.list(path)
    if command == 'read':
        result = fs.read(path)
        result['version'] = hashlib.sha256(fs.resolve_safe(path).read_bytes()).hexdigest()
        return result
    full = fs.resolve_safe(path)
    expected = args.get('version')
    actual = hashlib.sha256(full.read_bytes()).hexdigest() if full.is_file() else None
    if 'version' in args and expected != actual:
        return {'ok': False, 'error': {'code': 'conflict', 'message': '文件已改变，草稿未覆盖磁盘'}, 'version': actual}
    if command == 'write':
        return fs.write(path, args['content'])
    if not full.is_file():
        raise FsError('not_found', '文件不存在')
    if command == 'rename':
        target = fs.resolve_safe(args['target'])
        if target.exists():
            raise FsError('exists', '目标文件已存在')
        target.parent.mkdir(parents=True, exist_ok=True)
        full.rename(target)
        return {'ok': True, 'path': path, 'target': args['target']}
    if command == 'delete':
        full.unlink()
        return {'ok': True, 'path': path}
    raise FsError('unknown_tool', command)


def main():
    # The wire protocol is UTF-8 regardless of the user's Windows console code page.
    sys.stdin.reconfigure(encoding='utf-8')
    sys.stdout.reconfigure(encoding='utf-8')
    parser = argparse.ArgumentParser()
    parser.add_argument('domain', choices=['world', 'fs'])
    parser.add_argument('operation')
    opts = parser.parse_args()
    request = json.load(sys.stdin)
    tool = opts.domain + '.' + opts.operation
    manifest_path = Path(request['manifest'])
    manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
    if request.get('capability') != manifest.get('capability') or tool not in manifest['tools']:
        raise FsError('tool_not_connected', '本次运行未连接此工具')
    args = request.get('args', {})
    if opts.domain == 'world':
        result = rpc(tool, args)
    else:
        fs = ScopedFs(Path(manifest['workspace']))
        result = file_action(fs, opts.operation, args)
        sync = rpc('documents.sync', {'documents': documents(fs)})
        result['synchronized'] = sync.get('ok', False)
        record = rpc('external', {'tool': tool, 'args': args, 'result': result, 'runId': manifest['runId']})
        result['worldStep'] = record.get('step')
    print(json.dumps(result, ensure_ascii=True))


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print(json.dumps({'ok': False, 'error': {'code': getattr(exc, 'code', type(exc).__name__),
                                              'message': str(exc)}}, ensure_ascii=True))
        sys.exit(1)
