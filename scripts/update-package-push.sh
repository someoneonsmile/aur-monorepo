#!/usr/bin/env bash
# 处理单个被 push 改动的包：智能 pkgrel + checksum 更新 + 推送 AUR + 更新状态账本
#
# 与 update-package.sh（schedule 上游检查）的区别：
#   - 不做 pkgctl version upgrade / nvchecker 上游检查
#   - 以 AUR 已发布的 .SRCINFO 为基准，判断本次手动改动是否有实质变化
#   - 智能判断 pkgrel：pkgver 变→重置 1；pkgver 不变→必要时自动 +1
#   - source 变化时自动重算 checksum（updpkgsums，含分架构 sha256sums_<arch>）
#
# 用法: update-package-push.sh <包目录> <状态输出目录>
# 状态输出: <状态目录>/<包名>.json 写入 {package, updated, pkgver, pkgrel}
set -euo pipefail

PKG="$1"
STATUS_DIR="$2"

REPO_ROOT="$(pwd)"
STATE_FILE="${REPO_ROOT}/.ci/state/${PKG}.json"
mkdir -p "$(dirname "${STATE_FILE}")"

cd "${PKG}"

AUR_REMOTE="ssh://aur@aur.archlinux.org/${PKG}.git"
export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new"

# 用 updpkgsums 重新计算所有 checksum（含分架构 sha256sums_<arch>）并写回 PKGBUILD。
# 它会下载 source 到当前目录，结束后清理下载的文件，避免污染 git 工作区。
update_checksums() {
  local before
  before="$(mktemp)"
  ls -1 > "${before}"
  runuser -u build -- updpkgsums
  # 删除 updpkgsums 新增的 source 文件（ls -1 不含隐藏文件，故 .SRCINFO/.nvchecker.toml 不受影响）
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    grep -qxF "$f" "${before}" || rm -f -- "$f"
  done < <(ls -1)
  rm -f "${before}"
  rm -rf src pkg
}

# 一次 chown，后续 build 用户跑 makepkg 需要目录读写权限
chown -R build:build .

# 1. 本地生成 .SRCINFO（基于用户 push 后的 PKGBUILD）
local_srcinfo=$(runuser -u build -- makepkg --printsrcinfo 2>/dev/null)

# 2. 从 AUR 获取已发布版本
TMP_GIT="$(mktemp -d)"
trap 'rm -rf "${TMP_GIT}"; chown -R root:root .' EXIT
git --git-dir="${TMP_GIT}" init -q
git --git-dir="${TMP_GIT}" --work-tree=. add PKGBUILD .SRCINFO

HAS_REMOTE=false
aur_srcinfo=""
aur_pkgver=""
aur_pkgrel=""
# ls-remote 失败（网络/SSH 问题）必须报错退出，不能静默当作首次发布
if ! ls_remote_out=$(git --git-dir="${TMP_GIT}" ls-remote --heads "${AUR_REMOTE}" master 2>&1); then
  echo "::error::[${PKG}] 无法连接 AUR 远程 ${AUR_REMOTE}: ${ls_remote_out}"
  exit 1
fi
if printf '%s' "${ls_remote_out}" | grep -q master; then
  git --git-dir="${TMP_GIT}" fetch -q "${AUR_REMOTE}" master
  HAS_REMOTE=true
  aur_srcinfo=$(git --git-dir="${TMP_GIT}" show "FETCH_HEAD:.SRCINFO")
  aur_pkgver=$(printf '%s\n' "${aur_srcinfo}" | awk -F' = ' '/^[[:space:]]*pkgver = /{print $2; exit}')
  aur_pkgrel=$(printf '%s\n' "${aur_srcinfo}" | awk -F' = ' '/^[[:space:]]*pkgrel = /{print $2; exit}')
fi

# 3. 无实质变化判断（.SRCINFO 是规范化输出，注释/空白不影响它）
if [[ "${HAS_REMOTE}" == "true" && "${local_srcinfo}" == "${aur_srcinfo}" ]]; then
  echo "[${PKG}] .SRCINFO 与 AUR 已发布版本一致，无实质变化，跳过"
  jq -n --arg pkg "${PKG}" '{package:$pkg, updated:false}' > "${STATUS_DIR}/${PKG}.json"
  exit 0
fi

# 4. 智能 pkgrel
local_pkgver=$(grep -m1 '^pkgver=' PKGBUILD | cut -d= -f2)
local_pkgrel=$(grep -m1 '^pkgrel=' PKGBUILD | cut -d= -f2)

if [[ "${HAS_REMOTE}" == "true" ]]; then
  if [[ "${local_pkgver}" != "${aur_pkgver}" ]]; then
    # pkgver 变了 → pkgrel 重置为 1
    if [[ "${local_pkgrel}" != "1" ]]; then
      echo "::warning::[${PKG}] pkgver 从 ${aur_pkgver} 变为 ${local_pkgver}，pkgrel 重置为 1（原 ${local_pkgrel}）"
      sed -i 's/^pkgrel=.*/pkgrel=1/' PKGBUILD
      local_pkgrel=1
    fi
  elif (( local_pkgrel <= aur_pkgrel )); then
    # pkgver 没变，内容有实质变化，但 pkgrel 未 bump → 自动 +1
    new_pkgrel=$((aur_pkgrel + 1))
    echo "::warning::[${PKG}] 内容有实质变化但 pkgrel 未 bump（${local_pkgrel} <= ${aur_pkgrel}），自动 bump 到 ${new_pkgrel}"
    sed -i "s/^pkgrel=.*/pkgrel=${new_pkgrel}/" PKGBUILD
    local_pkgrel=${new_pkgrel}
  fi
fi

# 5. source 变化时更新 checksum（决策 1-A）
if [[ "${HAS_REMOTE}" == "true" ]]; then
  local_sources=$(printf '%s\n' "${local_srcinfo}" | grep -E '^[[:space:]]*source')
  aur_sources=$(printf '%s\n' "${aur_srcinfo}" | grep -E '^[[:space:]]*source')
  if [[ "${local_sources}" != "${aur_sources}" ]]; then
    echo "[${PKG}] source 变化，重新计算 checksum"
    update_checksums
  fi
fi

# 6. 重新生成最终 .SRCINFO（PKGBUILD 可能被 bump pkgrel / updpkgsums 改动）
runuser -u build -- makepkg --printsrcinfo > .SRCINFO

# 7. 推送到 AUR（DRY_RUN=1 时跳过）
git --git-dir="${TMP_GIT}" --work-tree=. add PKGBUILD .SRCINFO
TREE=$(git --git-dir="${TMP_GIT}" write-tree)

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo "[${PKG}] DRY_RUN=1，跳过推送 AUR"
else
  if [[ "${HAS_REMOTE}" == "true" ]]; then
    PARENT=$(git --git-dir="${TMP_GIT}" rev-parse FETCH_HEAD)
    PARENT_TREE=$(git --git-dir="${TMP_GIT}" rev-parse "FETCH_HEAD^{tree}")
    if [[ "${TREE}" == "${PARENT_TREE}" ]]; then
      echo "[${PKG}] AUR 树对象一致，跳过推送"
    else
      COMMIT=$(printf 'update to %s-%s' "${local_pkgver}" "${local_pkgrel}" \
        | git --git-dir="${TMP_GIT}" commit-tree "${TREE}" -p "${PARENT}")
      git --git-dir="${TMP_GIT}" push "${AUR_REMOTE}" "${COMMIT}:refs/heads/master"
    fi
  else
    COMMIT=$(printf 'update to %s-%s' "${local_pkgver}" "${local_pkgrel}" \
      | git --git-dir="${TMP_GIT}" commit-tree "${TREE}")
    git --git-dir="${TMP_GIT}" push "${AUR_REMOTE}" "${COMMIT}:refs/heads/master"
  fi
fi

# 8. 更新状态账本（先写文件，commit 交给 sync-push.sh 统一处理）
jq -n \
  --arg pkgver "${local_pkgver}" \
  --arg pkgrel "${local_pkgrel}" \
  --arg pushed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{pkgver:$pkgver, pkgrel:$pkgrel, pushed_at:$pushed_at}' > "${STATE_FILE}"

jq -n --arg pkg "${PKG}" --arg pkgver "${local_pkgver}" --arg pkgrel "${local_pkgrel}" \
  '{package:$pkg, updated:true, pkgver:$pkgver, pkgrel:$pkgrel}' > "${STATUS_DIR}/${PKG}.json"
