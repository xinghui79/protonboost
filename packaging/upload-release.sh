#!/usr/bin/env bash
# 一键发布：推送代码 → 打 tag → 创建 GitHub Release → 上传 dist/ 安装包
#
# 前置:
#   1. GitHub 上已建好空仓库
#   2. Personal Access Token（对仓库有 Contents 读写权限）：
#      Settings → Developer settings → Personal access tokens
#      · Fine-grained: 选中本仓库，Permissions → Contents → Read and write
#      · Classic: 勾选 repo
#
# 用法（在本机终端运行，token 不经手任何第三方）:
#   GITHUB_TOKEN=ghp_xxx packaging/upload-release.sh [owner/repo]
#
# 说明: 全局 gitconfig 里若有 gh-proxy 之类的 insteadOf 镜像重写会拦截
# 推送，脚本用临时干净配置绕过；token 只出现在内存与本次命令行，
# 不写入 remote 或磁盘。
set -euo pipefail
: "${GITHUB_TOKEN:?请设置 GITHUB_TOKEN 环境变量（GitHub → Settings → Developer settings → Tokens）}"
REPO="${1:-xinghui79/protonboost}"
cd "$(dirname "$0")/.."

VERSION="$(grep -m1 '^version' Cargo.toml | sed 's/.*"\(.*\)".*/\1/')"
TAG="v$VERSION"
API="https://api.github.com"
AUTH="Authorization: Bearer $GITHUB_TOKEN"
ACCEPT="Accept: application/vnd.github+json"

[[ -d dist ]] || { echo "没有 dist/ 产物，先跑 packaging/build-dist.sh" >&2; exit 1; }

CLEAN_CFG="$(mktemp)"
# 干净配置：绕过全局 gh-proxy insteadOf；HTTP/1.1 规避部分网络下
# GitHub HTTPS 的 "HTTP2 framing layer" 错误
cat > "$CLEAN_CFG" <<'EOF'
[http]
	version = HTTP/1.1
EOF
BODY="$(mktemp)"
RESP="$(mktemp)"
trap 'rm -f "$CLEAN_CFG" "$BODY" "$RESP"' EXIT
export GIT_CONFIG_GLOBAL="$CLEAN_CFG"   # 绕过 gh-proxy insteadOf 等全局重写

git remote add origin "https://github.com/$REPO.git" 2>/dev/null || true
git remote set-url origin "https://github.com/$REPO.git"

PUSH_URL="https://x-access-token:${GITHUB_TOKEN}@github.com/${REPO}.git"
BRANCH="$(git branch --show-current)"

echo "→ 推送分支 $BRANCH → main"
git push "$PUSH_URL" "$BRANCH:main"

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "→ 标签 $TAG 已存在"
else
    git tag "$TAG"
    echo "→ 打标签 $TAG"
fi
git push "$PUSH_URL" "refs/tags/$TAG"

echo "→ 创建 Release $TAG"
python3 - "$TAG" > "$BODY" <<'PYEOF'
import json, sys
tag = sys.argv[1]
print(json.dumps({
    "tag_name": tag,
    "name": tag,
    "body": (
        "在 Linux 上跑 Windows 程序的小工具（Rust + Qt 6）。\n\n"
        "## 安装\n\n"
        "- **Arch**: `sudo pacman -U protonboost-*-x86_64.pkg.tar.zst`\n"
        "- **Debian/Ubuntu**: `sudo apt install ./protonboost_*_amd64.deb`\n"
        "- **其它发行版**: 解压 tar.gz 后运行 `./install.sh`\n"
        "- **源码**: `git clone` 后 `./install.sh`\n\n"
        "## 首次使用\n\n"
        "打开管理器点「下载 GE-Proton」，然后把 exe 拖进窗口即可；\n"
        "前缀默认开启独立网络，Windows 加速器和游戏装进同一个前缀共享。\n"
        "详见 README。\n"
    ),
    "draft": False,
    "prerelease": False,
}))
PYEOF
HTTP=$(curl -s -o "$RESP" -w "%{http_code}" -X POST "$API/repos/$REPO/releases" \
    -H "$AUTH" -H "$ACCEPT" --data-binary @"$BODY")
if [[ "$HTTP" != "200" && "$HTTP" != "201" ]]; then
    echo "创建 Release 失败（HTTP $HTTP）:" >&2
    cat "$RESP" >&2
    exit 1
fi
UPLOAD_URL="$(python3 -c "import json; print(json.load(open('$RESP'))['upload_url'].split('{')[0])")"
RELEASE_URL="$(python3 -c "import json; print(json.load(open('$RESP'))['html_url'])")"

echo "→ 上传安装包"
for f in dist/*; do
    name="$(basename "$f")"
    HTTP=$(curl -s -o "$RESP" -w "%{http_code}" -X POST "$UPLOAD_URL?name=$name" \
        -H "$AUTH" -H "$ACCEPT" -H "Content-Type: application/octet-stream" \
        --data-binary @"$f")
    if [[ "$HTTP" != "201" ]]; then
        echo "上传 $name 失败（HTTP $HTTP）:" >&2
        cat "$RESP" >&2
        exit 1
    fi
    echo "   ✓ $name"
done

echo
echo "完成！Release 页面: $RELEASE_URL"
