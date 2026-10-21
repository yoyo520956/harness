#!/usr/bin/env python3
"""通过 Git Data API 推送任意文件到 main（iSH 直连 github.com:443 不可靠时的固定通道）。

用法: python3 scripts/api-push.py "commit message" path1 path2 ...
支持新建嵌套目录；未变更的条目原样保留 sha。
"""
import base64, json, os, sys, urllib.request, urllib.error

REPO = 'yoyo520956/harness'

def api(method, path, body=None):
    url = 'https://api.github.com/repos/' + REPO + path
    data = None
    headers = {'Authorization': 'Bearer ' + os.environ['GITHUB_TOKEN'],
               'Accept': 'application/vnd.github+json'}
    if body is not None:
        data = json.dumps(body).encode()
        headers['Content-Type'] = 'application/json'
    req = urllib.request.Request(url, method=method, data=data, headers=headers)
    try:
        return json.load(urllib.request.urlopen(req, timeout=300))
    except urllib.error.HTTPError as e:
        print('HTTP', e.code, path, '->', e.read()[:300])
        raise

def main():
    msg = sys.argv[1]
    paths = sys.argv[2:]
    ref = api('GET', '/git/refs/heads/main')['object']['sha']
    root = api('GET', '/git/trees/' + ref)['tree']

    changes = {}   # 完整相对路径 -> blob sha
    for p in paths:
        content = open(p, 'rb').read()
        b64 = base64.b64encode(content).decode()
        nb = api('POST', '/git/blobs', {'content': b64, 'encoding': 'base64'})
        changes[p] = nb['sha']
        print('blob', p, nb['sha'][:10], len(content), 'bytes')

    def rebuild(entries, seg):
        """重建 seg/ 这一层树；entries 可为空（新建目录）。"""
        sub = {k[len(seg) + 1:]: v for k, v in changes.items() if k.startswith(seg + '/')}
        out = []
        for e in (entries or []):
            d = {'path': e['path'], 'mode': e['mode'], 'type': e['type'], 'sha': e['sha']}
            if e['path'] in sub:
                d['sha'] = sub.pop(e['path'])
            elif e['type'] == 'tree' and any(k == e['path'] or k.startswith(e['path'] + '/') for k in sub):
                child = api('GET', '/git/trees/' + e['sha'])['tree']
                d['sha'] = rebuild(child, seg + '/' + e['path'])
            out.append(d)
        new_files = {k: v for k, v in sub.items() if '/' not in k}
        new_dirs = {}
        for k, v in sub.items():
            if '/' in k:
                top, rest = k.split('/', 1)
                new_dirs.setdefault(top, {})[rest] = v
        for rel, sha in new_files.items():
            out.append({'path': rel, 'mode': '100644', 'type': 'blob', 'sha': sha})
        for top, rest_map in new_dirs.items():
            seg2 = seg + '/' + top
            base = []
            for e in (entries or []):
                if e['path'] == top and e['type'] == 'tree':
                    base = api('GET', '/git/trees/' + e['sha'])['tree']
            for rest, sha in rest_map.items():
                changes[seg2 + '/' + rest] = sha
            out.append({'path': top, 'mode': '040000', 'type': 'tree',
                        'sha': rebuild(base, seg2)})
        return api('POST', '/git/trees', {'tree': out})['sha']

    touched_tops = sorted({p.split('/')[0] for p in paths if '/' in p})
    new_root = []
    root_files = {p: sha for p, sha in changes.items() if '/' not in p}
    for e in root:
        d = {'path': e['path'], 'mode': e['mode'], 'type': e['type'], 'sha': e['sha']}
        if e['path'] in changes:
            d['sha'] = changes[e['path']]
        elif e['type'] == 'tree' and e['path'] in touched_tops:
            child = api('GET', '/git/trees/' + e['sha'])['tree']
            d['sha'] = rebuild(child, e['path'])
        new_root.append(d)
    for rel, sha in root_files.items():
        new_root.append({'path': rel, 'mode': '100644', 'type': 'blob', 'sha': sha})
    new_root_sha = api('POST', '/git/trees', {'tree': new_root})['sha']

    cm = api('POST', '/git/commits', {'message': msg, 'tree': new_root_sha, 'parent': [ref]})
    sha = cm['sha']
    assert len(sha) == 40
    api('PUT', '/git/refs/heads/main', {'sha': sha, 'force': True})
    print('>> pushed', sha[:12])

if __name__ == '__main__':
    main()
