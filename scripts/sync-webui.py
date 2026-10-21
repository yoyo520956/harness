#!/usr/bin/env python3
"""同步 webui-dist 分支抓取结果到 main 的 Resources/webui/（Git Data API 通道）。

用法: python3 scripts/sync-webui.py
依赖: GITHUB_TOKEN 环境变量；临时目录里 tarball 由本脚本自行拉取。
"""
import base64, io, json, os, sys, tarfile, urllib.request, urllib.error

REPO = 'yoyo520956/harness'
KEEP_PREFIX = 'webui-dist-files/'
SKIP = {'.cookies', 'failed.txt', 'dsh-web.log'}

def api(method, path, body=None, raw=False):
    url = 'https://api.github.com/repos/' + REPO + path
    data = None
    headers = {'Authorization': 'Bearer ' + os.environ['GITHUB_TOKEN'],
               'Accept': 'application/vnd.github+json'}
    if body is not None:
        data = json.dumps(body).encode()
        headers['Content-Type'] = 'application/json'
    req = urllib.request.Request(url, method=method, data=data, headers=headers)
    r = urllib.request.urlopen(req, timeout=300)
    return r.read() if raw else json.load(r)

# 1) 拉 webui-dist tarball
print('>> 下载 webui-dist tarball ...')
raw = api('GET', '/tarball/webui-dist', raw=True)
print('>>', len(raw), 'bytes')
tf = tarfile.open(fileobj=io.BytesIO(raw))
files = {}   # relpath -> bytes
for m in tf.getmembers():
    if not m.isfile():
        continue
    p = m.path
    at = p.find(KEEP_PREFIX)
    if at < 0:
        continue
    rel = p[at + len(KEEP_PREFIX):]
    name = os.path.basename(rel)
    if name in SKIP or rel.endswith('/'):
        continue
    files[rel] = tf.extractfile(m).read()
print('>> 有效文件:', len(files))

# 2) 当前 main 树
ref = api('GET', '/git/refs/heads/main')['object']['sha']
root = api('GET', '/git/trees/' + ref)['tree']

def get_subtree(entries, name):
    for e in entries:
        if e['path'] == name and e['type'] == 'tree':
            return api('GET', '/git/trees/' + e['sha'])['tree'], e['sha']
    return None, None

res_tree, res_sha = get_subtree(root, 'Resources')
webui_tree, webui_sha = (None, None)
if res_tree:
    webui_tree, webui_sha = get_subtree(res_tree, 'webui')

# 3) 上传 blobs（跳过内容未变的）
old_blobs = {}
if webui_tree:
    for e in webui_tree:
        if e['type'] == 'blob':
            old_blobs[e['path']] = e['sha']

new_entries = []
uploaded = 0
for rel, content in sorted(files.items()):
    b64 = base64.b64encode(content).decode()
    sha = None
    # GitHub blob sha = git sha1；先算本地避免重复上传
    import hashlib
    git_sha = hashlib.sha1(b'blob ' + str(len(content)).encode() + b'\x00' + content).hexdigest()
    if old_blobs.get(rel) == git_sha:
        sha = git_sha
    else:
        nb = api('POST', '/git/blobs', {'content': b64, 'encoding': 'base64'})
        sha = nb['sha']
        uploaded += 1
    new_entries.append({'path': rel, 'mode': '100644', 'type': 'blob', 'sha': sha})
print('>> 新上传 blobs:', uploaded, '/', len(files))

new_webui_sha = api('POST', '/git/trees', {'tree': new_entries})['sha']
new_res = [dict(e, sha=new_webui_sha) if e['path'] == 'webui' else dict(e) for e in (res_tree or [])]
if not any(e['path'] == 'webui' for e in new_res):
    new_res.append({'path': 'webui', 'mode': '040000', 'type': 'tree', 'sha': new_webui_sha})
new_res_sha = api('POST', '/git/trees', {'tree': new_res})['sha']
new_root = [dict(e, sha=new_res_sha) if e['path'] == 'Resources' else dict(e) for e in root]
new_root_sha = api('POST', '/git/trees', {'tree': new_root})['sha']

cm = api('POST', '/git/commits', {
    'message': 'webui: sync captured DeepSeek Harness dist (%d files)' % len(files),
    'tree': new_root_sha, 'parent': [ref]})
api('PUT', '/git/refs/heads/main', {'sha': cm['sha'], 'force': True})
print('>> main 已更新:', cm['sha'][:12], 'files:', len(files))
