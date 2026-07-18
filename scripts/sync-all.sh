#!/usr/bin/env bash
# 编排脚本：
#   1. 发现所有包
#   2. nvchecker 批量预检，过滤出"可能有更新"的子集（force=true 时跳过预检）
#   3. 并发调用 update-package.sh 逐包检查/构建/推 AUR
#   4. 串行汇总本地 commit，统一 push 一次
#   5. 回写 nvchecker 缓存（只回写成功处理过的包，失败的包保留旧值以便下次重试）
#   6. 有失败就开/更新一个 GitHub issue 汇总
#
# 用法: sync-all.sh [指定单个包目录] [force: true/false]
#
# 环境变量 DRY_RUN=1：完整跑一遍检测/构建逻辑，但不产生任何外部副作用——
#   不推 AUR、不 push 到 origin/main、不开/更新 GitHub issue。
#   本地 commit 仍然会生成，方便你看 diff，但只停留在本地，不会被推走。
set -euo pipefail

FILTER_PKG="${1:-}"
FORCE="${2:-false}"
DRY_RUN="${DRY_RUN:-0}"

REPO_ROOT="$(pwd)"
STATE_DIR="${REPO_ROOT}/.ci/state"
STATUS_DIR="$(mktemp -d)"
FAILED_FILE="${STATUS_DIR}/failed.txt"
: > "${FAILED_FILE}"
mkdir -p "${STATE_DIR}"

git config --global --add safe.directory "${REPO_ROOT}"
git config --global user.name "aur-bot"
git config --global user.email "aur-bot@users.noreply.github.com"

# ---------- 1. 发现包 ----------
mapfile -t all_packages < <(
  find . -maxdepth 2 -name PKGBUILD -not -path './.git/*' \
    -exec dirname {} \; | sed 's|^\./||' | sort -u
)

if [[ -n "${FILTER_PKG}" ]]; then
  all_packages=("${FILTER_PKG}")
fi

if [[ ${#all_packages[@]} -eq 0 ]]; then
  echo "没有发现任何包，退出。"
  exit 0
fi

echo "共发现 ${#all_packages[@]} 个包: ${all_packages[*]}"

# ---------- 2. nvchecker 批量预检 ----------
to_process=("${all_packages[@]}")
if [[ "${FORCE}" != "true" ]]; then
  if filtered=$(printf '%s\n' "${all_packages[@]}" | "${REPO_ROOT}/scripts/precheck.sh" "${STATE_DIR}"); then
    mapfile -t to_process <<< "${filtered}"
    to_process=("${to_process[@]/#/}")           # 去掉可能的空行残留
    to_process=("${to_process[@]}")
  else
    echo "::warning::预检脚本异常退出，回退为处理全部包"
  fi
fi

if [[ ${#to_process[@]} -eq 0 || ( ${#to_process[@]} -eq 1 && -z "${to_process[0]}" ) ]]; then
  echo "预检认为所有包都没有变化，退出。"
  exit 0
fi

echo "预检后需要完整检查 ${#to_process[@]} 个包: ${to_process[*]}"

# 构建用户提前建好，避免每个并发子进程重复 useradd 冲突
if ! id build &>/dev/null; then
  useradd -m build
fi

# ---------- 3. 并发处理 ----------
export STATUS_DIR FORCE FAILED_FILE REPO_ROOT DRY_RUN
printf '%s\n' "${to_process[@]}" | xargs -P 4 -I{} bash -c '
  pkg="{}"
  if ! "${REPO_ROOT}/scripts/update-package.sh" "$pkg" "$STATUS_DIR" "$FORCE"; then
    echo "$pkg" >> "$FAILED_FILE"
    echo "::error::[$pkg] 更新失败"
  fi
'

mapfile -t failed_packages < "${FAILED_FILE}"

# ---------- 4. 汇总本地 commit（串行，避免并发写 .git） ----------
# 确保 CWD 是仓库根目录（xargs 子进程不会改变父进程 CWD，但以防万一）
cd "${REPO_ROOT}"

commit_lines=""
has_pkg_changes=false

while IFS= read -r -d '' result; do
  pkg=$(basename "${result}" .json)
  updated=$(jq -r '.updated' "${result}")
  if [[ "${updated}" == "true" ]]; then
    pkgver=$(jq -r '.pkgver' "${result}")
    git -C "${REPO_ROOT}" add "${pkg}/PKGBUILD" "${pkg}/.SRCINFO" ".ci/state/${pkg}.json"
    if ! git -C "${REPO_ROOT}" diff --cached --quiet; then
      git -C "${REPO_ROOT}" commit -m "chore(${pkg}): update to ${pkgver}" --quiet
      commit_lines="${commit_lines}chore(${pkg}): update to ${pkgver}"$'\n'
      has_pkg_changes=true
    fi
  fi
done < <(find "${STATUS_DIR}" -maxdepth 1 -name '*.json' -print0)

# ---------- 5. 回写 nvchecker 缓存 ----------
# 只回写「本次实际跑过 update-package.sh 且没有失败」的包，
# 失败的包保留旧缓存值，这样下次预检还会把它识别为"有变化"，从而重试。
NEW_JSON="${STATE_DIR}/nvchecker-new.json"
OLD_JSON="${STATE_DIR}/nvchecker-old.json"
has_cache_changes=false

if [[ -f "${NEW_JSON}" && -f "${OLD_JSON}" ]]; then
  updated_old="${OLD_JSON}"
  for pkg in "${to_process[@]}"; do
    if printf '%s\n' "${failed_packages[@]:-}" | grep -qxF "${pkg}"; then
      continue
    fi
    if jq -e --arg p "${pkg}" '.data | has($p)' "${NEW_JSON}" >/dev/null 2>&1; then
      new_val=$(jq -c --arg p "${pkg}" '.data[$p]' "${NEW_JSON}")
      jq --arg p "${pkg}" --argjson v "${new_val}" '.version = 2 | .data[$p] = $v' "${updated_old}" > "${updated_old}.tmp"
      mv "${updated_old}.tmp" "${updated_old}"
    fi
  done
  git -C "${REPO_ROOT}" add "${OLD_JSON}"
  if ! git -C "${REPO_ROOT}" diff --cached --quiet -- "${OLD_JSON}"; then
    has_cache_changes=true
  fi
fi

# ---------- 6. 统一 commit + push ----------
if ${has_pkg_changes} || ${has_cache_changes}; then
  if ${has_pkg_changes}; then
    echo "本次更新："
    echo -n "${commit_lines}"
  fi
  if ${has_cache_changes}; then
    git -C "${REPO_ROOT}" commit -m "chore: refresh nvchecker cache" --quiet
  fi

  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "DRY_RUN=1，commit 已在本地生成，跳过 push 到 origin/main"
  else
    git -C "${REPO_ROOT}" fetch origin main
    if ! git -C "${REPO_ROOT}" rebase origin/main; then
      echo "::error::rebase 到 origin/main 失败，需要人工介入（可能有冲突）"
      exit 1
    fi
    git -C "${REPO_ROOT}" push origin main
  fi
else
  echo "没有包需要更新，也没有缓存需要刷新。"
fi

# ---------- 7. 失败汇总通知 ----------
if [[ -s "${FAILED_FILE}" ]]; then
  failed_list="$(tr '\n' ' ' < "${FAILED_FILE}")"
  echo "::warning::以下包更新失败: ${failed_list}"

  if command -v gh &>/dev/null && [[ -n "${GH_TOKEN:-}" ]]; then
    run_url="${GITHUB_SERVER_URL:-}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}"
    body=$(printf '以下包在自动更新时失败，请人工检查：\n\n%s\n\n工作流运行: %s' \
      "$(sed 's/^/- /' "${FAILED_FILE}")" "${run_url}")

    existing="$(gh issue list --search 'AUR 自动更新失败 in:title' --state open --json number -q '.[0].number' || true)"
    if [[ -n "${existing}" ]]; then
      gh issue comment "${existing}" --body "${body}"
    else
      gh issue create --title "AUR 自动更新失败" --body "${body}"
    fi
  fi
  exit 1
fi
