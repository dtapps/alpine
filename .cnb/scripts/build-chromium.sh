#!/bin/sh
# ===================================================================
# 多架构（linux/amd64 + linux/arm64）构建并推送 Chromium 镜像
#
# 产物路径：<registry>/<仓库 slug>/chromium
#
# 标签与 Alpine 基础镜像同一套契约 —— 标签里的版本号来自基座，不是入参：
#   <alpine 版本>               本次基座的实际版本（如 3.25.1），构建阶段直接推送
#   <major.minor>               滚动 minor（如 3.25），冒烟通过且基座对齐后提升
#   latest                      最近一次成功构建，规则同上
#   <alpine 版本>-linux-amd64   从同一份 manifest list 派生的单平台标签
#   <alpine 版本>-linux-arm64   同上
#
# 设计约束（改之前先读，六条互相牵制）：
#   1. 镜像必须挂在 <仓库 slug>/chromium 这个子路径下：本仓库同时发布 Alpine
#      基础镜像（<仓库 slug>），chromium 若推到 <仓库 slug> 会把它的 latest 顶掉。
#   2. 基座必须是本仓库构建的 Alpine 基础镜像：按 version 选 <slug>:latest /
#      :3.25 / :3.25.1，进容器读 /etc/alpine-release 得到实际版本，再钉住
#      <slug>:<实际版本> 的 digest。找不到就失败，不会退回官方 alpine。
#   3. 标签用解析出来的实际 Alpine 版本。latest / minor 只在基座对应标签已指向
#      同一 digest 时提升，Chromium 永远不会跑到基座前面。
#   4. 必须 source 执行：##[set-output] 与 export 只在当前 shell 生效。
#   5. registry 缓存按「上游是否真的变了」失效：装包层的缓存键里带 APK 索引
#      指纹（apk update 后对 APKINDEX 求 sha256）。索引不变就命中；任何包升级
#      就重跑 apk add。每日 cron 仍然检查上游，但没变化时不再白装 761 MiB。
#      CACHE=off 可退回全量重建。
#   6. 变体（-cjk / -headless）不再发布：需要中文字体或内置无头参数的下游，
#      用 --build-arg WITH_CJK=1 / Dockerfile.headless 自行派生，本流水线只发
#      一个中性镜像。
#
# 依赖：docker buildx（CNB services: docker 自带）、jq 可选、git 可选。
# ===================================================================
set -eu

# ---------- 常量 ----------
# 路径写死、不做变量拼接：与 build-alpine.sh 一样，这一行没有 ${...}，
# 谁来做模板处理都改不到它。
DOCKERFILE=".cnb/docker/Dockerfile.chromium"
PLATFORMS="linux/amd64,linux/arm64"
MIN_IMAGE_BYTES=1048576
EPOCH_DATE="1970-01-01T00:00:00Z"
# 基座由另一条流水线产出：手动触发时最多等 5 分钟（20 × 15s）
BASE_WAIT_ATTEMPTS=20
BASE_WAIT_SECONDS=15
# registry 缓存：每个镜像用自己的 <镜像>:buildcache，不和上游/下游共用
CACHE_REF_SUFFIX="buildcache"
CACHE_MODE="min"

# ---------- 输出助手 ----------
info() { printf '  %s\n' "$*"; }
warn() { printf '警告: %s\n' "$*" >&2; }
_selfcheck=ok
die() {
  printf '错误: %s\n' "$*" >&2
  exit 1
}

# ---------- 自检：脚本必须原样到达 runner ----------
# 与 build-alpine.sh 相同的探针：脚本被 imports 改写时，${...} 会变成带引号的
# 字面量，这里立刻停下并指路，而不是等某个下游命令报怪错。
case "${_selfcheck:-missing}" in
  ok) : ;;
  *) die '脚本被外部改写：${...} 没有正常展开（检查 .cnb.yml 的 imports 是否又引入了本脚本）' ;;
esac

# ---------- CACHE 开关 ----------
# on（默认）：读写 <镜像>:buildcache；off：--no-cache 全量重建。
# 缓存解析失败时脚本会自动把本次降级成 off，不会带着空键去读旧缓存。
CACHE="${CACHE:-on}"
case "${CACHE}" in
  on | off) : ;;
  *) die "CACHE 只接受 on / off，收到：${CACHE}" ;;
esac

# ---------- manifest / 体积助手 ----------
# 取某平台「镜像清单」的 digest。必须定位到镜像清单本身：manifest list / index
# 没有 layers 字段，对它求体积只会得到几 KB 的假值。
manifest_digest_for() ( # $1=镜像引用 $2=arch
  ref=$1
  arch=$2
  digest=""
  if command -v jq >/dev/null 2>&1; then
    digest="$(docker buildx imagetools inspect "${ref}" \
      --format '{{json .Manifest.Manifests}}' 2>/dev/null \
      | jq -r --arg a "${arch}" \
        '.[]? | select((.platform.os // "") == "linux" and (.platform.architecture // "") == $a) | .digest' \
      | head -n 1 || true)"
  fi
  if [ -z "${digest}" ]; then
    digest="$(docker buildx imagetools inspect "${ref}" --format \
      "{{range \$m := .Manifest.Manifests}}{{with \$m.Platform}}{{if and (eq .OS \"linux\") (eq .Architecture \"${arch}\")}}{{\$m.Digest}}{{end}}{{end}}{{end}}" \
      2>/dev/null | tr -d '\n' || true)"
  fi
  printf '%s\n' "${digest}"
)

# 单平台压缩体积（字节）。只对「镜像清单」求和：layers 之和 + config。
# 解析失败输出 -1（不输出假的小数字）。
image_size_bytes() ( # $1=镜像引用 $2=arch
  ref=$1
  arch=$2
  bytes=""
  digest="$(manifest_digest_for "${ref}" "${arch}")"
  if [ -z "${digest}" ]; then
    printf '警告: 未取到 linux/%s 的清单 digest，体积记为 unknown\n' "${arch}" >&2
    printf '%s\n' "-1"
    return 0
  fi
  raw="$(docker buildx imagetools inspect "${ref%@*}@${digest}" --raw 2>/dev/null || true)"
  case "${raw}" in
    *'"layers"'*) : ;;
    *)
      printf '警告: linux/%s 取到的不是镜像清单（无 layers 字段），体积记为 unknown\n' "${arch}" >&2
      printf '%s\n' "-1"
      return 0
      ;;
  esac
  if command -v jq >/dev/null 2>&1; then
    bytes="$(printf '%s' "${raw}" \
      | jq -r '(([.layers[].size] | add) // 0) + (.config.size // 0)' 2>/dev/null || true)"
  fi
  case "${bytes:-}" in
    '' | *[!0-9]*)
      bytes="$(printf '%s' "${raw}" \
        | grep -o '"size":[[:space:]]*[0-9]\+' | grep -o '[0-9]\+' \
        | awk '{s+=$1} END{print s+0}')"
      ;;
  esac
  if [ "${bytes:-0}" -lt "${MIN_IMAGE_BYTES}" ]; then
    printf '警告: linux/%s 体积解析结果异常（%s 字节），记为 unknown\n' "${arch}" "${bytes:-0}" >&2
    printf '%s\n' "-1"
    return 0
  fi
  printf '%s\n' "${bytes}"
)

image_size_mb() ( # $1=镜像引用 $2=arch
  bytes="$(image_size_bytes "$1" "$2")"
  awk -v b="${bytes:--1}" \
    'BEGIN{ if (b < 0) print "unknown"; else printf "%.1fMB", b/1048576 }'
)

# ---------- APK 索引指纹 ----------
# 把「当前仓库里有什么包」压缩成一个确定值：apk update 后对 APKINDEX 求 sha256。
# 它进 Dockerfile 装包层的命令文本，于是：
#   索引没变 → 缓存键不变 → 命中；
#   任何包升级 → 索引变化 → 装包层重跑，拿到新包。
# 这比「按天击穿」精确：没变化时不会白装 184 个包 / 761 MiB，有变化时也不会漏。
# 解析失败输出空串，调用方据此关闭缓存（宁可全量重建，也不读可能过期的缓存）。
resolve_apk_index_digest() ( # $1=基础镜像引用
  ref=$1
  docker run --rm --platform linux/amd64 "${ref}" sh -eu -c '
    apk update >/dev/null 2>&1
    printf "APK_INDEX_DIGEST=%s\n" \
      "$(cat /var/cache/apk/APKINDEX.* 2>/dev/null | sha256sum | cut -d" " -f1)"
  ' 2>/dev/null | sed -n 's/^APK_INDEX_DIGEST=//p' | tail -n 1 | tr -d '[:space:]'
)

# ---------- 0. 环境检查 ----------
: "${CNB_DOCKER_REGISTRY:?缺少环境变量 CNB_DOCKER_REGISTRY}"
: "${CNB_REPO_SLUG_LOWERCASE:?缺少环境变量 CNB_REPO_SLUG_LOWERCASE}"
: "${CNB_TOKEN_USER_NAME:?缺少环境变量 CNB_TOKEN_USER_NAME}"
: "${CNB_TOKEN:?缺少环境变量 CNB_TOKEN}"

# 凭证只在本次构建内有效：结束时删掉登录态，避免残留在 runner 上
set +u
HOMEDIR="$HOME"
set -u
[ -n "$HOMEDIR" ] || HOMEDIR=/root
cleanup() { rm -f "$HOMEDIR/.docker/config.json"; }
trap cleanup EXIT

# 镜像路径：Alpine 基础镜像占据 <slug>，chromium 挂在子路径下
IMAGE="${CNB_DOCKER_REGISTRY}/${CNB_REPO_SLUG_LOWERCASE}/chromium"
BASE_REPO="${CNB_DOCKER_REGISTRY}/${CNB_REPO_SLUG_LOWERCASE}"
case "${IMAGE}" in
  */chromium) : ;;
  *) die "镜像路径异常：${IMAGE}（必须以 /chromium 结尾，否则会顶掉 Alpine 基础镜像的标签）" ;;
esac

# cron 不传 version。用 set +u 临时关掉未定义检查来兜住，而不是写成 ${version:-}：
# 带 :- 的写法在 CI 的模板处理里被改写风险最高（见 .cnb.yml 的 imports 注释）。
set +u
version="$version"
expected_chromium_major="$expected_chromium_major"
set -u

version=$(printf '%s' "${version}" | tr -d '[:space:]')
version=$(printf '%s' "${version}" | sed 's/[^[:print:]]//g')
[ -n "${version}" ] || version="latest"

echo "=============================="
echo "🔧 构建多架构 Chromium 镜像"
echo "=============================="
info "IMAGE     ${IMAGE}"
info "version   ${version}（Alpine 版本；latest = 跟随基座 latest）"

# ---------- 1. version 校验 ----------
# 只接受 latest 或 3.24 / 3.24.3 这类 Alpine 版本号；Chromium 版本号一律拒绝。
# 这里不接受 digest：本仓库的基座标签是 <slug>:<实际版本>，上游 alpine 的 digest
# 与本仓库产物的 digest 不是同一个值。
if [ "${version}" != "latest" ]; then
  printf '%s' "${version}" | grep -Eq '^[0-9]+\.[0-9]+(\.[0-9]+)?$' \
    || die "version 只接受 latest / 3.24 / 3.24.3，收到：${version}（这里填的是 Alpine 版本，不是 Chromium 版本）"
fi

# ---------- 1.5 可选的 Chromium 主版本断言覆盖 ----------
# 按钮输入 expected_chromium_major：留空 = 用 Dockerfile 里的 EXPECTED_CHROMIUM_MAJOR；
# 留空 = 不校验，跟随上游；填 155/156 = 显式确认这次构建的浏览器主版本；
# 填 any = 跳过断言。
# 注意它不是「装指定版本的 Chromium」：chromium 包由 Alpine 分支仓库决定，
# 仓库里只保留当前版本的 apk，指定旧版本会直接装不上。
expected_chromium_major=$(printf '%s' "${expected_chromium_major}" | tr -d '[:space:]')
EXPECTED_ARG=""
if [ -n "${expected_chromium_major}" ]; then
  if [ "${expected_chromium_major}" != "any" ]; then
    printf '%s' "${expected_chromium_major}" | grep -Eq '^[0-9]+$' \
      || die "expected_chromium_major 只接受主版本号（如 155）或 any，收到：${expected_chromium_major}"
  fi
  EXPECTED_ARG="--build-arg EXPECTED_CHROMIUM_MAJOR=${expected_chromium_major}"
  info "断言      chromium 主版本 = ${expected_chromium_major}（显式校验）"
else
  info "断言      chromium 主版本 = 不校验（跟随上游）"
fi

# ---------- 2. 登录与构建元数据 ----------
printf '%s' "${CNB_TOKEN}" \
  | docker login -u "${CNB_TOKEN_USER_NAME}" --password-stdin "${CNB_DOCKER_REGISTRY}" >/dev/null \
  || die "docker login 失败"

# 与 build-alpine.sh 一致：BUILD_DATE 取最后一次提交时间，同一份源码重复构建
# 得到同样的 config/label，便于逐字节比对
BUILD_DATE="$(git log -1 --format=%cI 2>/dev/null || true)"
[ -n "${BUILD_DATE}" ] || BUILD_DATE="${EPOCH_DATE}"
BUILD_REVISION="${CNB_COMMIT:-unknown}"
if [ "${BUILD_REVISION}" = "unknown" ]; then
  info "⚠️ CNB_COMMIT 为空，OCI revision 记为 unknown"
fi

# ---------- 3. buildx 自检 ----------
# CNB 的 services: docker 默认已内置可做多架构的 buildx builder，直接用；
# 不要再 docker buildx create --driver docker-container（受限容器拉不起嵌套 buildkitd）。
info "buildx $(docker buildx version 2>/dev/null | head -n 1)"
docker buildx inspect >/dev/null 2>&1 \
  || die "buildx 不可用：确认流水线里声明了 services: docker"

# attestation 开关：buildx 0.10 以下不认 --provenance/--sbom，缺了是硬失败，
# 所以先探测再决定。关掉之后 manifest list 里每个架构只剩一个条目。
ATTEST_ARGS=""
if docker buildx build --help 2>&1 | grep -q -- '--provenance'; then
  ATTEST_ARGS="--provenance=false --sbom=false"
else
  info "⚠️ 当前 buildx 不支持 --provenance，跳过关闭 attestation（体积解析可能取到 index）"
fi

# ---------- 4. 基座：本仓库的 Alpine 基础镜像 ----------
# version 只决定「选哪个基座标签」：
#   latest → <仓库 slug>:latest
#   3.24   → <仓库 slug>:3.24（build-alpine 冒烟通过后提升的 minor 标签）
#   3.24.3 → <仓库 slug>:3.24.3（需先以该版本构建过基座）
if [ "${version}" = "latest" ]; then
  BASE_REF="${BASE_REPO}:latest"
else
  BASE_REF="${BASE_REPO}:${version}"
fi
info "基座引用 ${BASE_REF}"

attempt=0
while [ "${attempt}" -lt "${BASE_WAIT_ATTEMPTS}" ]; do
  if docker buildx imagetools inspect "${BASE_REF}" >/dev/null 2>&1; then
    break
  fi
  attempt=$((attempt + 1))
  info "等待基座 ${BASE_REF}（${attempt}/${BASE_WAIT_ATTEMPTS}）"
  sleep "${BASE_WAIT_SECONDS}"
done
docker buildx imagetools inspect "${BASE_REF}" >/dev/null 2>&1 \
  || die "找不到基座 ${BASE_REF}：先运行 build-alpine 流水线并传入相同的 version（latest 由每日 00:05 任务产出），再重试"

# 实际版本从基座容器里读，而不是相信标签名：latest / 3.24 都可能指向 3.24.x。
info "解析基座 ${BASE_REF} 的实际 Alpine 版本"
ALPINE_REAL="$(docker run --rm --platform linux/amd64 "${BASE_REF}" \
  cat /etc/alpine-release 2>/dev/null | sed 's/-r[0-9]*$//' | tr -d '[:space:]' || true)"
printf '%s' "${ALPINE_REAL}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || die "无法从 ${BASE_REF} 解析 Alpine 版本（得到：${ALPINE_REAL:-空}），检查制品库与网络"

MINOR="$(printf '%s' "${ALPINE_REAL}" | cut -d. -f1,2)"
STAMP="${ALPINE_REAL}"
BASE_VERSION_REF="${BASE_REPO}:${STAMP}"

# build-alpine 先推 <版本>、冒烟通过后才提升 latest/minor，所以 latest 能解析到
# 某个版本时，该版本标签必然已存在。手动指定 3.24 时同理。
docker buildx imagetools inspect "${BASE_VERSION_REF}" >/dev/null 2>&1 \
  || die "找不到基座版本标签 ${BASE_VERSION_REF}：等 build-alpine 完成 ${STAMP} 的构建后重试"
BASE_DIGEST="$(docker buildx imagetools inspect "${BASE_VERSION_REF}" \
  --format '{{.Manifest.Digest}}' 2>/dev/null || true)"
[ -n "${BASE_DIGEST}" ] || die "无法读取 ${BASE_VERSION_REF} 的 digest"

info "ALPINE_REAL ${STAMP}"
info "MINOR       ${MINOR}"
info "基座        ${BASE_VERSION_REF}@${BASE_DIGEST}"

# ---------- 4.5 解析 APK 索引指纹（缓存击穿点） ----------
# 装包层的缓存键里会带这个值。索引不变 → 命中；任何包升级 → 重跑 apk add。
# 解析失败就把本次降级成 CACHE=off：宁可全量重建，也不读可能过期的缓存。
APK_INDEX_DIGEST="disabled"
if [ "${CACHE}" = "on" ]; then
  info "解析 APK 仓库索引指纹（缓存击穿点）"
  APK_INDEX_DIGEST="$(resolve_apk_index_digest "${BASE_VERSION_REF}@${BASE_DIGEST}")"
  if [ -z "${APK_INDEX_DIGEST}" ]; then
    warn "APK 索引解析失败，本次关闭缓存（全量重建）"
    CACHE="off"
    APK_INDEX_DIGEST="unknown"
  else
    info "APK_INDEX_DIGEST ${APK_INDEX_DIGEST}"
  fi
fi

# 公共构建参数。
#   CHROMIUM_BASE_IMAGE 用 digest 引用，避免构建期间基座 latest 被下一次构建挪走；
#   CHROMIUM_BASE_NAME 只用于 OCI base.name / base.digest 标签；
#   ALPINE_VERSION 写进 OCI version 标签，值就是解析出的实际版本；
#   APK_INDEX_DIGEST 是装包层的缓存击穿点，索引变了才会重跑 apk add。
# shellcheck disable=SC2086 # ATTEST_ARGS / EXPECTED_ARG 需要按空格拆成多个参数
COMMON_ARGS="--pull ${ATTEST_ARGS} ${EXPECTED_ARG} \
  --build-arg ALPINE_VERSION=${STAMP} \
  --build-arg CHROMIUM_BASE_IMAGE=${BASE_VERSION_REF}@${BASE_DIGEST} \
  --build-arg CHROMIUM_BASE_NAME=${BASE_VERSION_REF} \
  --build-arg CHROMIUM_BASE_DIGEST=${BASE_DIGEST} \
  --build-arg APK_INDEX_DIGEST=${APK_INDEX_DIGEST} \
  --build-arg BUILD_DATE=${BUILD_DATE} \
  --build-arg BUILD_REVISION=${BUILD_REVISION} \
  --build-arg IMAGE_SOURCE=${CNB_REPO_URL_HTTPS}"

# ---------- 5. 一次多架构构建 ----------
# 只构建一个中性镜像；-cjk / -headless 不再由 CI 发布。
# registry 缓存：每个镜像用自己的 <镜像>:buildcache，mode=min（单阶段构建）。
CACHE_REF="${IMAGE}:${CACHE_REF_SUFFIX}"
CACHE_FROM_READY=""
if [ "${CACHE}" = "on" ]; then
  if docker buildx imagetools inspect "${CACHE_REF}" >/dev/null 2>&1; then
    CACHE_FROM_READY=yes
    info "缓存源 ${CACHE_REF} 可读，本次尝试命中"
  else
    info "缓存源 ${CACHE_REF} 还不存在，本次只写不读"
  fi
fi

build_image() (
  mode=$1
  # shellcheck disable=SC2086 # COMMON_ARGS 需要按空格拆开
  set -- -t "${IMAGE}:${STAMP}" --platform "${PLATFORMS}" ${COMMON_ARGS}
  case "${mode}" in
    on)
      if [ -n "${CACHE_FROM_READY}" ]; then
        set -- "$@" --cache-from "type=registry,ref=${CACHE_REF}"
      fi
      set -- "$@" --cache-to "type=registry,ref=${CACHE_REF},mode=${CACHE_MODE}"
      ;;
    off) set -- "$@" --no-cache ;;
    *) : ;;
  esac
  set -- "$@" -f "${DOCKERFILE}" --push .
  docker buildx build "$@"
)

info "构建 ${IMAGE}:${STAMP}（${PLATFORMS}）"
if [ "${CACHE}" = "off" ]; then
  build_image off || die "docker buildx build 失败（CACHE=off）"
elif ! build_image on; then
  # 有的 registry 不接受 buildx 缓存清单，而且缓存导出是在镜像推完之后才报错。
  # 去掉缓存重试一次，别让当天的构建白跑。
  warn "带缓存的构建失败：可能是 registry 不支持 buildx 缓存清单，去掉缓存重试一次"
  build_image plain || die "docker buildx build 失败"
fi

# ---------- 6. 从同一 manifest 派生单平台标签 ----------
# 不重新构建：digest 与 index 里的条目完全一致。
for arch in amd64 arm64; do
  digest="$(manifest_digest_for "${IMAGE}:${STAMP}" "${arch}")"
  [ -n "${digest}" ] || die "未在 ${IMAGE}:${STAMP} 中找到 linux/${arch} 条目"
  docker buildx imagetools create -t "${IMAGE}:${STAMP}-linux-${arch}" \
    "${IMAGE}@${digest}" \
    || die "派生 ${STAMP}-linux-${arch} 失败"
  info "派生 ${IMAGE}:${STAMP}-linux-${arch} ← ${digest}"
done

# ---------- 7. 冒烟测试（amd64，只跑一次） ----------
# 放在提升 latest / minor 之前：镜像坏了就不动移动标签。
docker pull --platform linux/amd64 "${IMAGE}:${STAMP}" >/dev/null 2>&1 \
  || die "拉取 ${IMAGE}:${STAMP} 失败，latest 未提升"
info "冒烟测试 ${IMAGE}:${STAMP}（linux/amd64）"
CHROMIUM_VERSION="$(docker run --rm --platform linux/amd64 "${IMAGE}:${STAMP}" \
  chromium --version 2>/dev/null | awk '{print $2}' || true)"
case "${CHROMIUM_VERSION:-}" in
  [0-9]*.[0-9]*) : ;;
  *) die "冒烟失败：chromium --version 输出异常（得到：${CHROMIUM_VERSION:-空}）" ;;
esac
docker run --rm --platform linux/amd64 --shm-size=1g "${IMAGE}:${STAMP}" \
  chromium --headless --no-sandbox --disable-dev-shm-usage --dump-dom about:blank \
  >/dev/null 2>&1 \
  || die "冒烟失败：无头渲染 about:blank 退出码非 0"
[ "$(docker run --rm --platform linux/amd64 "${IMAGE}:${STAMP}" date +%Z 2>/dev/null)" = "CST" ] \
  || die "冒烟失败：容器内时区不是 CST"

# 反向确认「确实基于本仓库的 alpine」：OCI 标签必须指向本次解析的基座。
label_base="$(docker image inspect \
  --format '{{index .Config.Labels "org.opencontainers.image.base.name"}}' \
  "${IMAGE}:${STAMP}" 2>/dev/null || true)"
[ "${label_base}" = "${BASE_VERSION_REF}" ] \
  || die "OCI label 校验失败：base.name=${label_base:-<空>}，期望 ${BASE_VERSION_REF}"
label_version="$(docker image inspect \
  --format '{{index .Config.Labels "org.opencontainers.image.version"}}' \
  "${IMAGE}:${STAMP}" 2>/dev/null || true)"
[ "${label_version}" = "${STAMP}" ] \
  || die "OCI label 校验失败：version=${label_version:-<空>}，期望 ${STAMP}"
info "chromium ${CHROMIUM_VERSION}，渲染、时区与基座标签校验通过"

# ---------- 8. 提升可变标签（冒烟通过、且基座已对齐） ----------
# 与 golang/fnpack 相同的门闸：只有 <仓库 slug>:<tag> 已经指向本次基座 digest，
# 才把 chromium 的同名标签提升过去。手动构建旧分支（如 3.24）时，latest 仍在
# 3.25 上，这里会自动跳过，不会把 chromium:latest 拉回旧版本。
for tag in "${MINOR}" latest; do
  base_tag_digest="$(docker buildx imagetools inspect "${BASE_REPO}:${tag}" \
    --format '{{.Manifest.Digest}}' 2>/dev/null || true)"
  if [ "${base_tag_digest}" != "${BASE_DIGEST}" ]; then
    info "跳过 ${IMAGE}:${tag}：${BASE_REPO}:${tag} 尚未指向 ${STAMP}"
    continue
  fi
  docker buildx imagetools create -t "${IMAGE}:${tag}" "${IMAGE}:${STAMP}" \
    || die "提升 ${tag} 失败"
  info "提升 ${IMAGE}:${tag} → ${STAMP}"
done

# ---------- 9. 元数据 ----------
MANIFEST_REF="${IMAGE}:${STAMP}"
DIGEST="$(docker buildx imagetools inspect "${MANIFEST_REF}" \
  --format '{{.Manifest.Digest}}' 2>/dev/null || true)"
[ -n "${DIGEST}" ] || DIGEST="unknown"
DIGEST_SHORT="$(printf '%s' "${DIGEST#sha256:}" | cut -c1-12)"
SIZE_AMD64="$(image_size_mb "${MANIFEST_REF}" amd64)"
SIZE_ARM64="$(image_size_mb "${MANIFEST_REF}" arm64)"
BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# 提示：本仓库同时发布 Alpine 基础镜像，它的元数据用 image_* 无前缀键，
# 这里必须全部加 chromium_ 前缀，否则同一个 commit 上两组键互相覆盖。
mkdir -p .cnb
cat >.cnb/annotation.json <<EOF
{
  "chromium_image_ref": "${IMAGE}",
  "chromium_image_version": "${STAMP}",
  "chromium_image_digest": "${DIGEST}",
  "chromium_image_digest_short": "${DIGEST_SHORT}",
  "chromium_image_size": "${SIZE_AMD64}",
  "chromium_image_size_arm64": "${SIZE_ARM64}",
  "chromium_base_image": "${BASE_VERSION_REF}",
  "chromium_base_digest": "${BASE_DIGEST}",
  "chromium_apk_index_digest": "${APK_INDEX_DIGEST}",
  "chromium_cache": "${CACHE}",
  "chromium_version": "${CHROMIUM_VERSION}",
  "chromium_built_at": "${BUILT_AT}",
  "revision": "${BUILD_REVISION}"
}
EOF

printf '##[set-output chromium_image_version=%s]\n' "${STAMP}"
printf '##[set-output chromium_version=%s]\n' "${CHROMIUM_VERSION}"
printf '##[set-output chromium_image_digest=%s]\n' "${DIGEST}"
info "digest    ${DIGEST}"
info "size      amd64 ${SIZE_AMD64} / arm64 ${SIZE_ARM64}"
info "chromium  ${CHROMIUM_VERSION}"
info "元数据    .cnb/annotation.json"

echo "=============================="
echo "🎉 Chromium 镜像构建完成 ${IMAGE}:${STAMP}"
echo "=============================="
