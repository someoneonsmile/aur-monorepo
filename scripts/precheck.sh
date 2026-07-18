#!/usr/bin/env bash
# nvchecker 批量预检：把所有包的 .nvchecker.toml 合并成一份配置，
# 一次网络请求判断哪些包"版本可能有变化"，避免逐包起构建环境。
#
# 设计原则：宁可漏过滤（多跑几个没必要的完整检查），也不能漏检测
#   - 没有 .nvchecker.toml 的包：直接放行，不参与过滤
#   - nvchecker 整体运行失败：直接放行全部包（不过滤）
#   - 单个包在新结果里读不到值：放行该包
#
# 用法: packages（每行一个，从 stdin 读入） | precheck.sh <缓存目录>
# 输出: 需要进入完整检查流程的包目录列表（每行一个，已去重排序）
set -euo pipefail

CACHE_DIR="${1:?用法: precheck.sh <缓存目录>}"
mkdir -p "${CACHE_DIR}"

OLD_JSON="${CACHE_DIR}/nvchecker-old.json"
NEW_JSON="${CACHE_DIR}/nvchecker-new.json"
COMBINED_TOML="${CACHE_DIR}/nvchecker-combined.toml"
[[ -f "${OLD_JSON}" ]] || echo '{}' > "${OLD_JSON}"

mapfile -t packages

{
  echo "[__config__]"
  echo "oldver = \"${OLD_JSON}\""
  echo "newver = \"${NEW_JSON}\""
} > "${COMBINED_TOML}"

no_config_packages=()
has_config_packages=()

for pkg in "${packages[@]}"; do
  if [[ -f "${pkg}/.nvchecker.toml" ]]; then
    # 假定各包的 section 名（一般等于 pkgbase）在仓库内唯一，直接拼接
    cat "${pkg}/.nvchecker.toml" >> "${COMBINED_TOML}"
    has_config_packages+=("${pkg}")
  else
    no_config_packages+=("${pkg}")
  fi
done

changed_packages=()

if [[ ${#has_config_packages[@]} -gt 0 ]]; then
  if nvchecker -c "${COMBINED_TOML}" --logging warning; then
    for pkg in "${has_config_packages[@]}"; do
      old_ver=$(jq -r --arg p "${pkg}" '.data[$p].version // empty' "${OLD_JSON}")
      new_ver=$(jq -r --arg p "${pkg}" '.data[$p].version // empty' "${NEW_JSON}" 2>/dev/null || echo "")
      if [[ -z "${new_ver}" || "${new_ver}" != "${old_ver}" ]]; then
        changed_packages+=("${pkg}")
      fi
    done
  else
    echo "::warning::nvchecker 批量预检运行失败，回退为不过滤（全部包进入完整检查）" >&2
    changed_packages=("${has_config_packages[@]}")
  fi
fi

printf '%s\n' "${changed_packages[@]:-}" "${no_config_packages[@]:-}" | sed '/^$/d' | sort -u
