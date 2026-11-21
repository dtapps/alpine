#!/bin/sh
# ===================================================================
# 构建记录 Issue（CNB 专用）：每个镜像一条 Issue，构建完成后更新正文，
# 版本号 / 软件包版本变化时追加一条评论；周一额外发周总结、每月 1 号额外发月总结。
#
# 为什么每个镜像一条、而不是每天一条：本仓库只有两个镜像（alpine / chromium），
# 两条常驻 Issue 就能装下全部历史（评论按时间倒序），Issue 列表不会每天多出
# 两条；版本没变的日子也不发「无变化」评论。
#
# 上一次状态记在评论开头的单行标记里（评论发出后删不掉，重跑也能读回来）：
#   <!-- build-announce-state:alpine_version=3.25.1;apk_versions=busybox=1.37.0-r19 ... -->
# 标记放在开头：评论后面要附完整的 annotation JSON，万一 CLI 列表输出截断长
# 字符串，开头的标记仍然读得到。
# 不落盘、不提交：构建仓库里没有可长期保存状态的地方，Issue 本身就是状态库。
# 每次读最近一条带标记的评论做 diff（list 按创建时间倒序，取第一条即可）。
#
# 周 / 月总结的基线同样是评论顶部的标记，按类型分别记录：
#   <!-- build-summary-state:weekly:2026-11-24:alpine_version=3.25.2;... -->
# 两次总结之间的版本变化就是「上一个星期 / 上一个月」；首次没有基线时只记录
# 当前版本、建立基线；同一天已经发过就跳过（重跑幂等）；周一与 1 号重合时
# 合并成一条，避免同一天发两遍。
#
# 用法（build-*.yml 的最后一个 stage 调用）：
#   sh .cnb/scripts/announce-build.sh <alpine|chromium>
#
# 依赖：cnbcool/cnb-cli 镜像里的 cnb 命令、CNB 注入的 CNB_TOKEN / CNB_REPO_SLUG，
#       以及构建阶段写出的 .cnb/annotation[-chromium].json（stage 共享工作区）。
#
# 失败只告警不退出：公告是附加动作，不能把已经成功的镜像构建标红。
# ===================================================================

set -eu

info() { printf '  %s\n' "$*"; }
warn() { printf '警告: %s\n' "$*" >&2; }
skip() {
  warn "$*"
  exit 0
}

# 评论里最多列出的软件包变化条数，超出部分只报总数（完整清单在 annotation 里）。
PKG_DISPLAY_LIMIT=12

variant="${1:-}"
case "$variant" in
  alpine)
    ANNOTATION_FILE=".cnb/annotation.json"
    TITLE="[镜像] alpine 构建记录"
    IMAGE_SUFFIX=""
    SCALAR_KEYS="alpine_version"
    PACKAGE_KEY="apk_versions"
    DIGEST_KEY="image_digest"
    DIGEST_SHORT_KEY="image_digest_short"
    SIZE_KEY="image_size"
    SIZE_ARM64_KEY="image_size_arm64"
    BUILT_AT_KEY="built_at"
    ;;
  chromium)
    ANNOTATION_FILE=".cnb/annotation-chromium.json"
    TITLE="[镜像] chromium 构建记录"
    IMAGE_SUFFIX="/chromium"
    SCALAR_KEYS="chromium_version chromium_image_version"
    PACKAGE_KEY="chromium_apk_versions"
    DIGEST_KEY="chromium_image_digest"
    DIGEST_SHORT_KEY="chromium_image_digest_short"
    SIZE_KEY="chromium_image_size"
    SIZE_ARM64_KEY="chromium_image_size_arm64"
    BUILT_AT_KEY="chromium_built_at"
    ;;
  *) skip "用法: sh .cnb/scripts/announce-build.sh <alpine|chromium>" ;;
esac

REPO="${CNB_REPO_SLUG:-${CNB_REPO_SLUG_LOWERCASE:-}}"
[ -n "$REPO" ] || skip "缺少 CNB_REPO_SLUG / CNB_REPO_SLUG_LOWERCASE，跳过构建公告"

[ -f "$ANNOTATION_FILE" ] || skip "找不到 ${ANNOTATION_FILE}（构建元数据未生成），跳过构建公告"

# annotation 由构建脚本按「一行一个 key」写出，值都是版本号 / 软件包列表 /
# 镜像名 / digest 这类不含转义引号的普通字符串，sed 足够。
json_string() {
  sed -n "s/^[[:space:]]*\"$1\":[[:space:]]*\"\(.*\)\"[,]*[[:space:]]*$/\1/p" \
    "$ANNOTATION_FILE" | head -n 1
}

# 版本值去掉可能的尾部空白（软件包列表以空格分隔，尾部空白会让状态永远判为变化）。
ann_value() {
  json_string "$1" | sed 's/[[:space:]]*$//'
}

label_for() {
  case "$1" in
    alpine_version) printf 'Alpine' ;;
    chromium_version) printf 'Chromium' ;;
    chromium_image_version) printf 'Alpine（基座）' ;;
    apk_versions) printf '已装软件包' ;;
    chromium_apk_versions) printf '关键软件包' ;;
    *) printf '%s' "$1" ;;
  esac
}

pkg_count() {
  printf '%s' "$1" | tr ' ' '\n' | awk 'NF { n++ } END { print n + 0 }'
}

tmp="$(mktemp -d 2>/dev/null || true)"
if [ -z "${tmp}" ]; then
  tmp="/tmp/build-announce-${variant}"
  mkdir -p "${tmp}"
fi
trap 'rm -rf "${tmp}"' EXIT

# ---------- 本次状态 ----------
IMAGE_REF="unknown"
if [ -n "${CNB_DOCKER_REGISTRY:-}" ] && [ -n "${CNB_REPO_SLUG_LOWERCASE:-}" ]; then
  IMAGE_REF="${CNB_DOCKER_REGISTRY}/${CNB_REPO_SLUG_LOWERCASE}${IMAGE_SUFFIX}"
fi
DIGEST="$(ann_value "$DIGEST_KEY")"
DIGEST_SHORT="$(ann_value "$DIGEST_SHORT_KEY")"
SIZE_AMD64="$(ann_value "$SIZE_KEY")"
SIZE_ARM64="$(ann_value "$SIZE_ARM64_KEY")"
BUILT_AT="$(ann_value "$BUILT_AT_KEY")"
[ -n "${BUILT_AT}" ] || BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
COMMIT_SHORT="$(printf '%s' "${CNB_COMMIT:-unknown}" | cut -c1-8)"

STATE=""
for key in $SCALAR_KEYS "$PACKAGE_KEY"; do
  value="$(ann_value "$key")"
  [ -n "$value" ] || continue
  if [ -n "${STATE}" ]; then
    STATE="${STATE};${key}=${value}"
  else
    STATE="${key}=${value}"
  fi
done
[ -n "${STATE}" ] || skip "${ANNOTATION_FILE} 里没有可公告的版本字段，跳过构建公告"

# 从状态串里取某个 key 的值；软件包列表里也可能出现等号，只有行首的 key= 会被剥掉。
state_get() {
  printf '%s' "$1" | tr ';' '\n' | sed -n "s/^$2=//p" | head -n 1
}

print_current_versions() {
  for key in $SCALAR_KEYS; do
    value="$(ann_value "$key")"
    [ -n "$value" ] || continue
    printf '%s\n' "- $(label_for "$key")：\`${value}\`"
  done
  pkg_list="$(ann_value "$PACKAGE_KEY")"
  if [ -n "$pkg_list" ]; then
    printf '%s\n' "- $(label_for "$PACKAGE_KEY")：$(pkg_count "$pkg_list") 个"
  fi
}

# 附上本次构建的完整元数据，方便对照版本明细 / 层版本 / digest 排查。
print_annotation() {
  printf '\n<details>\n<summary>构建元数据（%s）</summary>\n\n```json\n' "${ANNOTATION_FILE}"
  # awk 保证文件末尾有且只有一个换行，代码块不会和收尾的 ``` 粘在一起。
  awk '1' "${ANNOTATION_FILE}"
  printf '```\n\n</details>\n'
}

# 软件包列表 -> 每行 name|version，供 diff 使用。
to_pkg_lines() {
  printf '%s' "$1" | tr ' ' '\n' \
    | awk -F= 'NF > 1 { v = $0; sub(/^[^=]*=/, "", v); print $1 "|" v }'
}

# 比较两份软件包列表，把变化写进 DIFF_LINES / DIFF_COUNT。
pkg_diff() {
  old_list=$1
  new_list=$2
  old_file="${tmp}/pkg-old"
  new_file="${tmp}/pkg-new"
  changes_file="${tmp}/pkg-changes"
  to_pkg_lines "$old_list" >"${old_file}"
  to_pkg_lines "$new_list" >"${new_file}"
  : >"${changes_file}"

  while IFS='|' read -r name version; do
    [ -n "$name" ] || continue
    old_version="$(awk -F'|' -v n="$name" '$1 == n { print $2; exit }' "${old_file}")"
    if [ "$old_version" = "$version" ]; then
      continue
    fi
    if [ -z "$old_version" ]; then
      printf '%s\n' "- ${name}：新增 \`${version}\`" >>"${changes_file}"
    else
      printf '%s\n' "- ${name}：\`${old_version}\` → \`${version}\`" >>"${changes_file}"
    fi
  done <"${new_file}"

  while IFS='|' read -r name version; do
    [ -n "$name" ] || continue
    if ! awk -F'|' -v n="$name" '$1 == n { found = 1 } END { exit !found }' "${new_file}"; then
      printf '%s\n' "- ${name}：已移除（原 \`${version}\`）" >>"${changes_file}"
    fi
  done <"${old_file}"

  change_count="$(awk 'END { print NR + 0 }' "${changes_file}")"
  if [ "${change_count}" -eq 0 ]; then
    return 0
  fi
  DIFF_COUNT=$((DIFF_COUNT + change_count))
  DIFF_LINES="${DIFF_LINES}- $(label_for "${PACKAGE_KEY}")：${change_count} 项变化
"
  if [ "${change_count}" -gt "${PKG_DISPLAY_LIMIT}" ]; then
    DIFF_LINES="${DIFF_LINES}$(head -n "${PKG_DISPLAY_LIMIT}" "${changes_file}" | sed 's/^/  /')
  …（还有 $((change_count - PKG_DISPLAY_LIMIT)) 项，完整列表见下面的构建元数据）
"
  else
    DIFF_LINES="${DIFF_LINES}$(sed 's/^/  /' "${changes_file}")
"
  fi
}

# 计算 base 状态与当前 annotation 的差异；结果放在 DIFF_LINES / DIFF_COUNT。
diff_state() {
  base_state=$1
  DIFF_LINES=""
  DIFF_COUNT=0
  for key in $SCALAR_KEYS "$PACKAGE_KEY"; do
    new_value="$(ann_value "$key")"
    [ -n "$new_value" ] || continue
    old_value="$(state_get "${base_state}" "$key")"
    if [ "$key" = "$PACKAGE_KEY" ]; then
      pkg_diff "$old_value" "$new_value"
      continue
    fi
    if [ "$old_value" = "$new_value" ]; then
      continue
    fi
    DIFF_COUNT=$((DIFF_COUNT + 1))
    if [ -z "$old_value" ]; then
      DIFF_LINES="${DIFF_LINES}- $(label_for "$key")：\`${new_value}\`
"
    else
      DIFF_LINES="${DIFF_LINES}- $(label_for "$key")：\`${old_value}\` → \`${new_value}\`
"
    fi
  done
}

# ---------- 正文：当前版本（每次构建都刷新） ----------
BODY_FILE="${tmp}/body.md"
{
  printf '本 Issue 由 CNB 构建流水线自动维护：每次构建更新「当前版本」，版本号或软件包版本变化时追加评论。\n\n'
  printf '| 项目 | 当前值 |\n| --- | --- |\n'
  printf "| 镜像 | \`%s\` |\n" "${IMAGE_REF}"
  for key in $SCALAR_KEYS; do
    value="$(ann_value "$key")"
    printf "| %s | \`%s\` |\n" "$(label_for "$key")" "${value:-unknown}"
  done
  pkg_list="$(ann_value "$PACKAGE_KEY")"
  if [ -n "$pkg_list" ]; then
    printf '| %s | %s 个 |\n' "$(label_for "$PACKAGE_KEY")" "$(pkg_count "$pkg_list")"
  fi
  printf "| 摘要 | \`%s\` |\n" "${DIGEST_SHORT:-${DIGEST:-unknown}}"
  printf '| 体积 | amd64 %s / arm64 %s |\n' "${SIZE_AMD64:-unknown}" "${SIZE_ARM64:-unknown}"
  printf "\n最近构建：%s · 提交 \`%s\`\n" "${BUILT_AT}" "${COMMIT_SHORT}"
  if [ -n "$pkg_list" ]; then
    printf '\n<details>\n<summary>当前%s（%s 个）</summary>\n\n```text\n' \
      "$(label_for "$PACKAGE_KEY")" "$(pkg_count "$pkg_list")"
    printf '%s' "$pkg_list" | tr ' ' '\n'
    printf '\n```\n\n</details>\n'
  fi
} >"${BODY_FILE}"

# ---------- 找 Issue：每个镜像一条，标题固定 ----------
LABEL="构建记录"

# cnb CLI 的输出是 util.inspect 风格（对象属性逐行），按「上一个 number 行 +
# 当前 title 行」配对；number 与 title 都可能带引号，先剥掉再比较，避免
# v1.2.3 误匹配 v1.2.30。
find_number_in() {
  # cnb CLI 的字符串可能被单引号或双引号包着；q 用 sprintf 生成单引号，
  # 避免在 shell 单引号里再写单引号。
  awk -v t="${TITLE}" '
    BEGIN { q = sprintf("%c", 39) }
    /^[[:space:]]*(-[[:space:]]+)?number: / {
      v = $NF; gsub(/[^0-9]/, "", v); if (v != "") n = v
    }
    /^[[:space:]]*(-[[:space:]]+)?title: / {
      line = $0
      sub(/^[[:space:]]*(-[[:space:]]+)?title: /, "", line)
      gsub("^[" q "\",]+|[" q "\",]+$", "", line)
      if (line == t && n != "") { print n; exit }
    }
  ' "$1"
}

NUMBER=""
FOUND_STATE=""
for issue_state in open closed; do
  list_file="${tmp}/issues-${issue_state}.txt"
  cnb issues list-issues \
    --repo "${REPO}" \
    --state "${issue_state}" \
    --keyword "${variant}" \
    --page 1 \
    --page-size 50 \
    >"${list_file}" 2>&1 || true
  NUMBER="$(find_number_in "${list_file}" || true)"
  if [ -n "${NUMBER}" ]; then
    FOUND_STATE="${issue_state}"
    break
  fi
done

IS_NEW=no
if [ -n "${NUMBER}" ]; then
  info "找到 Issue #${NUMBER}（${FOUND_STATE}）：${TITLE}"
  if [ "${FOUND_STATE}" = "closed" ]; then
    cnb issues update-issue --repo "${REPO}" --number "${NUMBER}" --state open \
      >"${tmp}/reopen.txt" 2>&1 \
      || warn "重新打开 #${NUMBER} 失败（继续在其上评论）：$(head -n 3 "${tmp}/reopen.txt" 2>/dev/null | tr '\n' ' ' || true)"
  fi
  if cnb issues update-issue --repo "${REPO}" --number "${NUMBER}" --body-file "${BODY_FILE}" \
    >"${tmp}/update.txt" 2>&1; then
    info "已更新正文里的当前版本"
  else
    warn "更新正文失败（不影响评论）：$(head -n 5 "${tmp}/update.txt" 2>/dev/null | tr '\n' ' ' || true)"
  fi
else
  IS_NEW=yes
  # 仓库里没有「构建记录」标签时，带标签建 Issue 会被拒；先建标签，已存在时
  # 接口报 400、忽略即可。带标签仍失败时去掉标签再试一次。
  cnb repo-labels post-label \
    --repo "${REPO}" \
    --name "${LABEL}" \
    --color "52c41a" \
    --description "镜像构建记录（流水线自动维护）" \
    >/dev/null 2>&1 || true
  if ! cnb issues create-issue \
    --repo "${REPO}" \
    --title "${TITLE}" \
    --body-file "${BODY_FILE}" \
    --labels "${LABEL}" \
    >"${tmp}/create.txt" 2>&1; then
    cnb issues create-issue \
      --repo "${REPO}" \
      --title "${TITLE}" \
      --body-file "${BODY_FILE}" \
      >"${tmp}/create.txt" 2>&1 || true
  fi
  NUMBER="$(grep -oE 'number: .?[0-9]+' "${tmp}/create.txt" 2>/dev/null \
    | head -n 1 | grep -oE '[0-9]+' || true)"
  [ -n "${NUMBER}" ] || skip "创建 Issue 失败或没解析到编号：$(head -n 5 "${tmp}/create.txt" 2>/dev/null | tr '\n' ' ' || true)"
  info "已创建 Issue #${NUMBER}：${TITLE}"
fi

# ---------- 读上一次状态 ----------
PREV_STATE=""
HISTORY_OK=yes
if [ "${IS_NEW}" = no ]; then
  cnb issues list-issue-comments \
    --repo "${REPO}" \
    --number "${NUMBER}" \
    --sort -created \
    --page-size 50 \
    >"${tmp}/comments.txt" 2>&1 || true
  if grep -q 'status: 2' "${tmp}/comments.txt" 2>/dev/null; then
    # 列表按创建时间倒序，第一条带标记的评论就是上一次构建的状态。
    # 标记后紧跟正文，截到第一个「 -->」；去掉标记尾部空格（软件包列表里
    # 带空格），否则永远判为变化。
    PREV_STATE="$(sed -n 's/.*build-announce-state://p' "${tmp}/comments.txt" \
      | sed 's/ -->.*//' | sed 's/[[:space:]]*$//' | head -n 1)"
  else
    HISTORY_OK=no
    warn "读取历史评论失败，本次不评论（避免重复）"
  fi
fi

if [ "${HISTORY_OK}" = no ]; then
  exit 0
fi

# ---------- 常规评论：版本有变化时才发 ----------
diff_state "${PREV_STATE}"

if [ "${IS_NEW}" = no ] && [ "${DIFF_COUNT}" -eq 0 ]; then
  info "版本无变化（${STATE}），跳过常规评论"
else
  COMMENT_FILE="${tmp}/comment.md"
  {
    printf '<!-- build-announce-state:%s -->\n\n' "${STATE}"
    # 先 @ 仓库里的 NPC（见 .cnb/settings.yml 的 npc/CodeBuddy），让它根据下面的
    # 版本变化与 annotation 整理一版面向使用者的说明，作为评论发回来。
    printf '@CodeBuddy 请根据下面的版本变化和构建元数据，整理一份面向镜像使用者的简洁更新说明，并作为评论发布在这里。\n\n'
    printf '要求：\n'
    printf '1. 只写使用者能感知的变化（Alpine / Chromium / 软件包版本），忽略内部实现与 digest 细节；\n'
    printf '2. 按「版本变化 / 安全相关 / 其它」分组，每条一句话说清影响；\n'
    printf '3. 与下面的变更清单保持一致，不要编造未列出的版本。\n\n'
    if [ "${IS_NEW}" = yes ] || [ -z "${PREV_STATE}" ]; then
      printf '## %s 首次构建记录\n\n当前版本：\n' "${BUILT_AT}"
      print_current_versions
    else
      printf '## %s 版本变化\n\n%s' "${BUILT_AT}" "${DIFF_LINES}"
    fi
    printf '\n'
    printf '%s\n' "- 镜像：\`${IMAGE_REF}\`"
    printf '%s\n' "- 摘要：\`${DIGEST_SHORT:-${DIGEST:-unknown}}\`"
    printf '%s\n' "- 提交：\`${COMMIT_SHORT}\`"
    print_annotation
  } >"${COMMENT_FILE}"

  if cnb issues post-issue-comment \
    --repo "${REPO}" \
    --number "${NUMBER}" \
    --body-file "${COMMENT_FILE}" \
    >"${tmp}/post.txt" 2>&1; then
    info "✓ 已发布评论到 Issue #${NUMBER}"
  else
    warn "发布评论失败：$(head -n 5 "${tmp}/post.txt" 2>/dev/null | tr '\n' ' ' || true)"
  fi
fi

# ---------- 周 / 月总结 ----------
# 周一：总结上一个星期；每月 1 号：总结上一个月。都发在同一条镜像 Issue 里，
# 与常规评论互不影响（版本没变也会有总结）。
if [ "${IS_NEW}" = yes ]; then
  exit 0
fi

# CNB 的 cron 按 Asia/Shanghai 解释，这里也按 UTC+8 算日期；不依赖镜像里有没有
# tzdata（date -u -r 是 BSD，date -u -d @... 是 GNU / busybox）。
NOW_EPOCH="$(date -u +%s)"
CN_CAL="$(date -u -r $((NOW_EPOCH + 28800)) '+%u %d %Y-%m-%d' 2>/dev/null \
  || date -u -d "@$((NOW_EPOCH + 28800))" '+%u %d %Y-%m-%d' 2>/dev/null || true)"
WEEKDAY="${CN_CAL%% *}"
CN_DAY="${CN_CAL#* }"
CN_DAY="${CN_DAY%% *}"
CN_DATE="${CN_CAL##* }"
case "${CN_DATE}" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;;
  *) skip "无法计算 Asia/Shanghai 日期，跳过周/月总结" ;;
esac

POST_WEEKLY=no
POST_MONTHLY=no
if [ "${WEEKDAY}" = "1" ]; then
  POST_WEEKLY=yes
fi
if [ "$(printf '%s' "${CN_DAY}" | sed 's/^0//')" = "1" ]; then
  POST_MONTHLY=yes
fi
if [ "${POST_WEEKLY}" = no ] && [ "${POST_MONTHLY}" = no ]; then
  exit 0
fi

# 读最近一条同类总结的日期与版本快照；今天已经发过就跳过（重跑幂等）。
# 同一天周/月总结合并成一条评论、两个标记，截到第一个「 -->」即可分别取出。
read_summary_marker() {
  marker="$(sed -n "s/.*build-summary-state:$1://p" "${tmp}/comments.txt" \
    | sed 's/ -->.*//' | sed 's/[[:space:]]*$//' | head -n 1)"
  MARK_DATE="${marker%%:*}"
  MARK_STATE="${marker#*:}"
}

WEEK_BASE_DATE=""
WEEK_BASE_STATE=""
if [ "${POST_WEEKLY}" = yes ]; then
  read_summary_marker weekly
  if [ "${MARK_DATE}" = "${CN_DATE}" ]; then
    info "今天已发过周总结，跳过"
    POST_WEEKLY=no
  else
    WEEK_BASE_DATE="${MARK_DATE}"
    WEEK_BASE_STATE="${MARK_STATE}"
  fi
fi

MONTH_BASE_DATE=""
MONTH_BASE_STATE=""
if [ "${POST_MONTHLY}" = yes ]; then
  read_summary_marker monthly
  if [ "${MARK_DATE}" = "${CN_DATE}" ]; then
    info "今天已发过月总结，跳过"
    POST_MONTHLY=no
  else
    MONTH_BASE_DATE="${MARK_DATE}"
    MONTH_BASE_STATE="${MARK_STATE}"
  fi
fi

if [ "${POST_WEEKLY}" = no ] && [ "${POST_MONTHLY}" = no ]; then
  exit 0
fi

SUMMARY_LABEL="月总结"
if [ "${POST_WEEKLY}" = yes ] && [ "${POST_MONTHLY}" = yes ]; then
  SUMMARY_LABEL="周总结和月总结"
elif [ "${POST_WEEKLY}" = yes ]; then
  SUMMARY_LABEL="周总结"
fi

print_summary_section() {
  section_label="$1"
  base_date="$2"
  base_state="$3"
  if [ -z "${base_state}" ]; then
    printf '## %s\n\n首次总结，先记录当前版本：\n' "${section_label}"
    print_current_versions
    return 0
  fi
  diff_state "${base_state}"
  if [ "${DIFF_COUNT}" -eq 0 ]; then
    printf '## %s\n\n自 %s 以来无版本变化。\n\n当前版本：\n' "${section_label}" "${base_date}"
    print_current_versions
  else
    printf '## %s\n\n自 %s 以来：\n%s' "${section_label}" "${base_date}" "${DIFF_LINES}"
  fi
}

SUMMARY_FILE="${tmp}/summary.md"
{
  if [ "${POST_WEEKLY}" = yes ]; then
    printf '<!-- build-summary-state:weekly:%s:%s -->\n' "${CN_DATE}" "${STATE}"
  fi
  if [ "${POST_MONTHLY}" = yes ]; then
    printf '<!-- build-summary-state:monthly:%s:%s -->\n' "${CN_DATE}" "${STATE}"
  fi
  printf '\n@CodeBuddy 请根据下面的%s，整理一份面向镜像使用者的简洁总结，并作为评论发布在这里。\n\n' "${SUMMARY_LABEL}"
  printf '要求：\n'
  printf '1. 只写使用者能感知的变化（Alpine / Chromium / 软件包版本），忽略内部实现与 digest 细节；\n'
  printf '2. 按「版本变化 / 安全相关 / 其它」分组，每条一句话说清影响；\n'
  printf '3. 与下面的变更清单保持一致，不要编造未列出的版本。\n\n'
  if [ "${POST_WEEKLY}" = yes ]; then
    print_summary_section "${CN_DATE} 周总结" "${WEEK_BASE_DATE}" "${WEEK_BASE_STATE}"
  fi
  if [ "${POST_MONTHLY}" = yes ]; then
    if [ "${POST_WEEKLY}" = yes ]; then
      printf '\n'
    fi
    print_summary_section "${CN_DATE} 月总结" "${MONTH_BASE_DATE}" "${MONTH_BASE_STATE}"
  fi
  printf '\n'
  printf '%s\n' "- 镜像：\`${IMAGE_REF}\`"
  printf '%s\n' "- 摘要：\`${DIGEST_SHORT:-${DIGEST:-unknown}}\`"
  printf '%s\n' "- 提交：\`${COMMIT_SHORT}\`"
  print_annotation
} >"${SUMMARY_FILE}"

if cnb issues post-issue-comment \
  --repo "${REPO}" \
  --number "${NUMBER}" \
  --body-file "${SUMMARY_FILE}" \
  >"${tmp}/summary-post.txt" 2>&1; then
  info "✓ 已发布${SUMMARY_LABEL}到 Issue #${NUMBER}"
else
  warn "发布${SUMMARY_LABEL}失败：$(head -n 5 "${tmp}/summary-post.txt" 2>/dev/null | tr '\n' ' ' || true)"
fi
