#!/usr/bin/env bash
# push 同步编排：检测本次 push 改动的包 → 逐包智能同步 AUR → 汇总 commit → push 回 monorepo
#
# 与 sync-all.sh（schedule 上游检查）的区别：
#   - 只处理本次 push 实际改动的包（git diff 检测），不查 nvchecker
#   - 不跑 pkgctl version upgrade，由 update-package-push.sh 做智能 pkgrel
#
# 用法: sync-push.sh（由 push 事件触发）
# 依赖环境变量:
#   GITHUB_EVENT_BEFORE  push 前的 commit SHA（github.event.before）
#   GITHUB_SHA           push 后的 commit SHA（github.sha）
# 环境变量 DRY_RUN=1：完整跑检测/构建逻辑，但不推 AUR、不 push origin/main
set -euo pipefail

REPO_ROOT="$(pwd)"
STATUS_DIR="$(mktemp -d)"
FAILED_FILE="${STATUS_DIR}/failed.txt"
: > "${FAILED_FILE}"

git config --global --add safe.directory "${REPO_ROOT}"
git config --global user.name "aur-bot"
git config --global user.email "aur-bot@users.noreply.github.com"

# 0. 防循环：bot 自己 push 的 commit 不再处理
#    （GITHUB_TOKEN 的 push 本就不会触发 workflow，这里是双保险，防 PAT push 场景）
if [[ "${GITHUB_ACTOR:-}" == "github-actions[bot]" ]]; then
  echo "由 aur-bot 触发的 push，跳过以避免循环"
  exit 0
fi

# 1. 检测本次 push 改动的包
BEFORE="${GITHUB_EVENT_BEFORE:-}"
AFTER="${GITHUB_SHA:-HEAD}"

if [[ -z "${BEFORE}" || "${BEFORE}" == "0000000000000000000000000000000000000000" ]]; then
  BEFORE="HEAD~1"
fi

if ! mapfile -t changed_pkgs < <(
  git diff --name-only "${BEFORE}" "${AFTER}" -- '*/PKGBUILD' '*/.SRCINFO' '*/.nvchecker.toml' \
    | sed 's|/[^/]*$||' | sort -u
); then
  # BEFORE 不可解析（如 force push 后对象被 GC），回退到最近一次提交
  mapfile -t changed_pkgs < <(
    git diff --name-only "HEAD~1" "HEAD" -- '*/PKGBUILD' '*/.SRCINFO' '*/.nvchecker.toml' \
      | sed 's|/[^/]*$||' | sort -u
  )
fi

if [[ ${#changed_pkgs[@]} -eq 0 ]]; then
  echo "本次 push 未改动任何包的 PKGBUILD/.SRCINFO/.nvchecker.toml，退出"
  exit 0
fi

echo "本次 push 改动的包: ${changed_pkgs[*]}"

# 2. 创建 build 用户（makepkg 拒绝 root 运行）
if ! id build &>/dev/null; then
  useradd -m build
fi

# 3. 逐包同步（串行即可，手动 push 通常只涉及少数包）
export STATUS_DIR DRY_RUN
for pkg in "${changed_pkgs[@]}"; do
  if ! "${REPO_ROOT}/scripts/update-package-push.sh" "$pkg" "$STATUS_DIR"; then
    echo "$pkg" >> "${FAILED_FILE}"
    echo "::error::[${pkg}] push 同步失败"
  fi
done

# 4. 汇总 commit（串行，避免并发写 .git）
cd "${REPO_ROOT}"

has_changes=false
while IFS= read -r -d '' result; do
  pkg=$(basename "${result}" .json)
  updated=$(jq -r '.updated // false' "${result}")
  if [[ "${updated}" == "true" ]]; then
    pkgver=$(jq -r '.pkgver' "${result}")
    pkgrel=$(jq -r '.pkgrel' "${result}")
    git add "${pkg}/PKGBUILD" "${pkg}/.SRCINFO" ".ci/state/${pkg}.json"
    if ! git diff --cached --quiet; then
      git commit -m "chore(${pkg}): sync to ${pkgver}-${pkgrel}" --quiet
      has_changes=true
    fi
  fi
done < <(find "${STATUS_DIR}" -maxdepth 1 -name '*.json' -print0)

# 5. push 回 monorepo
if ${has_changes}; then
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "DRY_RUN=1，commit 已在本地生成，跳过 push 到 origin/main"
  else
    # 清理可能残留的脏文件（失败包 sed 改了一半的 PKGBUILD 等）
    git checkout -- . 2>/dev/null || true
    git fetch origin main
    if ! git rebase origin/main; then
      echo "::error::rebase 到 origin/main 失败，需要人工介入（可能有冲突）"
      exit 1
    fi
    git push origin main
  fi
else
  echo "没有包需要同步。"
fi

# 6. 失败汇总
if [[ -s "${FAILED_FILE}" ]]; then
  echo "::error::以下包 push 同步失败: $(tr '\n' ' ' < "${FAILED_FILE}")"
  exit 1
fi
