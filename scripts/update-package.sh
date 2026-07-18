#!/usr/bin/env bash
# 处理单个包：检测新版本 -> 生成 .SRCINFO -> 更新状态账本 -> 推送 AUR -> 写状态文件
#
# 用法: update-package.sh <包目录> <状态输出目录> <force: true/false>
# 状态账本: <包目录同级>/.ci/state/<pkg>.json，记录当前已发布的 pkgver/pkgrel
set -euo pipefail

PKG="$1"
STATUS_DIR="$2"
FORCE="${3:-false}"

REPO_ROOT="$(pwd)"
STATE_FILE="${REPO_ROOT}/.ci/state/${PKG}.json"
mkdir -p "$(dirname "${STATE_FILE}")"

old_pkgver=""
old_pkgrel=""
if [[ -f "${STATE_FILE}" ]]; then
  old_pkgver=$(jq -r '.pkgver // empty' "${STATE_FILE}")
  old_pkgrel=$(jq -r '.pkgrel // empty' "${STATE_FILE}")
fi

cd "${PKG}"

# pkgctl version upgrade 会就地更新 PKGBUILD 的 pkgver/pkgrel/sha256sums
# 退出码: 0=正常(已是最新或已升级), 非零=真正错误(网络/git/nvchecker 失败等)
if ! pkgctl version upgrade; then
  status=$?
  echo "::error::pkgctl version upgrade (${PKG}) 失败，退出码 ${status}"
  exit ${status}
fi

new_pkgver=$(grep -m1 '^pkgver=' PKGBUILD | cut -d= -f2)
new_pkgrel=$(grep -m1 '^pkgrel=' PKGBUILD | cut -d= -f2)

if [[ "${FORCE}" != "true" && "${new_pkgver}" == "${old_pkgver}" && "${new_pkgrel}" == "${old_pkgrel}" ]]; then
  echo "[${PKG}] 版本未变化 (${new_pkgver}-${new_pkgrel})，跳过"
  jq -n --arg pkg "${PKG}" '{package:$pkg, updated:false}' > "${STATUS_DIR}/${PKG}.json"
  exit 0
fi

echo "[${PKG}] 版本变化: ${old_pkgver:-无}-${old_pkgrel:-无} -> ${new_pkgver}-${new_pkgrel}"

# 生成 .SRCINFO（build 用户由 sync-all.sh 提前创建好）
chown -R build:build .
runuser -u build -- makepkg --printsrcinfo > .SRCINFO
chown -R root:root .

# 更新状态账本（先写文件，commit 交给 sync-all.sh 统一处理）
jq -n \
  --arg pkgver "${new_pkgver}" \
  --arg pkgrel "${new_pkgrel}" \
  --arg pushed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{pkgver:$pkgver, pkgrel:$pkgrel, pushed_at:$pushed_at}' > "${STATE_FILE}"

# 设置 DRY_RUN=1 时跳过实际推送，只验证到这里为止的构建逻辑（本地调试用）
if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo "[${PKG}] DRY_RUN=1，跳过推送 AUR"
  jq -n --arg pkg "${PKG}" --arg pkgver "${new_pkgver}" \
    '{package:$pkg, updated:true, pkgver:$pkgver}' > "${STATUS_DIR}/${PKG}.json"
  exit 0
fi

# 推送到 AUR：用独立的临时 git-dir 操作树对象，不触碰 monorepo 的 .git，
# 这样多个包并发跑这一步也不会互相冲突。
export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new"
TMP_GIT="$(mktemp -d)"
trap 'rm -rf "${TMP_GIT}"' EXIT
git --git-dir="${TMP_GIT}" init -q
git --git-dir="${TMP_GIT}" --work-tree=. add PKGBUILD .SRCINFO
TREE=$(git --git-dir="${TMP_GIT}" write-tree)

AUR_REMOTE="ssh://aur@aur.archlinux.org/${PKG}.git"

if git --git-dir="${TMP_GIT}" ls-remote --heads "${AUR_REMOTE}" master | grep -q master; then
  git --git-dir="${TMP_GIT}" fetch "${AUR_REMOTE}" master
  PARENT=$(git --git-dir="${TMP_GIT}" rev-parse FETCH_HEAD)
  PARENT_TREE=$(git --git-dir="${TMP_GIT}" rev-parse "FETCH_HEAD^{tree}")
  if [[ "${TREE}" == "${PARENT_TREE}" ]]; then
    echo "[${PKG}] AUR 树对象与本地一致，跳过推送"
  else
    COMMIT=$(printf 'update to %s-%s' "${new_pkgver}" "${new_pkgrel}" \
      | git --git-dir="${TMP_GIT}" commit-tree "${TREE}" -p "${PARENT}")
    git --git-dir="${TMP_GIT}" push "${AUR_REMOTE}" "${COMMIT}:refs/heads/master"
  fi
else
  COMMIT=$(printf 'update to %s-%s' "${new_pkgver}" "${new_pkgrel}" \
    | git --git-dir="${TMP_GIT}" commit-tree "${TREE}")
  git --git-dir="${TMP_GIT}" push "${AUR_REMOTE}" "${COMMIT}:refs/heads/master"
fi

jq -n --arg pkg "${PKG}" --arg pkgver "${new_pkgver}" \
  '{package:$pkg, updated:true, pkgver:$pkgver}' > "${STATUS_DIR}/${PKG}.json"
