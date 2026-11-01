#!/bin/sh
# ===================================================================
# 多架构（linux/amd64 + linux/arm64）构建并推送 Alpine 基础镜像
#
# 设计约束（改之前先读，五条互相牵制）：
#   1. 只构建一次多架构，单平台标签从同一份 manifest 派生 —— 不重建，
#      所以三类标签的 digest 天然相同（旧实现三次构建，digest 各不相同）。
#   2. 基座跟随上游：Dockerfile 的 ARG ALPINE_VERSION 默认 latest，定时任务
#      每天重建就能吃到新补丁甚至新小版本；具体版本由脚本解析成 3.25.1 这种
#      确定值，写进标签与 OCI label，标签名因此永远是可读的 alpine 版本号。
#   3. 标签就是 alpine 版本号（不加日期）：先推 <版本>，冒烟通过后才提升 latest / minor。
#      同名标签每天被覆盖，历史只能靠元数据里的 digest 追；冒烟失败时 latest / minor 不动。
#   4. 必须 source 执行：##[set-output] 与 export 只在当前 shell 生效，
#      用 `sh build-alpine.sh` 跑会静默丢掉这两件事。
#   5. registry 缓存按「上游是否真的变了」失效：装包层的缓存键里带 APK 索引
#      指纹（apk update 后对 APKINDEX 求 sha256）。索引不变就命中；任何包升级
#      就重跑 apk add。每日 cron 仍然检查上游，但没变化时不再白装一遍。
#      CACHE=off 可退回全量重建。
#
# 依赖：docker buildx（CNB services: docker 自带）、jq 可选（体积精确求和）。
# ===================================================================

set -eu

# ---------- 常量 ----------
# 路径写死，不从环境变量读：CI 上曾出现过 `sed: can't read "${DOCKERFILE:-...}"`,
# 原因是脚本被当成 import 处理时 ${...} 被改写成了字面量。这一行现在没有任何
# 变量引用，谁来改写都影响不到它。
DOCKERFILE=".cnb/docker/Dockerfile.alpine"
PLATFORMS="linux/amd64,linux/arm64"
EPOCH_DATE="1970-01-01T00:00:00Z"
# 1 MiB：正常 alpine 派生镜像不可能低于此值，低于说明拿到的不是镜像清单
MIN_IMAGE_BYTES=1048576
# registry 缓存：每个镜像用自己的 <镜像>:buildcache，不和下游/上游共用
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
# CI 上出过一次事故：脚本被当作 import 处理，文件里的 ${...} 被改写成带引号的
# 字面量，导致 `sed` 拿到的是 `"${DOCKERFILE:-...}"` 这种字符串。这里用一个带
# 默认值的展开做探针：真被改写了就立刻停下并指路，而不是等某个下游命令报怪错。
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

# ---------- manifest 解析助手 ----------
# 取某平台「镜像清单」的 digest。必须定位到镜像清单本身：
# manifest list / index 没有 layers 字段，对它求体积只会得到几 KB 的假值。
# 优先用 jq 解析 JSON（字段缺失不会炸模板），没有 jq 再退回 Go 模板。
# 函数体用子 shell（( )）而非 local：POSIX sh 没有 local。
manifest_digest_for() (
  arch=$1
  ref="${IMAGE}:${STAMP}"
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

# 单平台压缩体积（字节）。只对「镜像清单」求和：layers 之和 + config，
# 与 docker pull 实际下载量一致。解析失败输出 -1（不输出假的小数字）。
image_size_bytes() (
  arch=$1
  bytes=""
  digest="$(manifest_digest_for "${arch}")"
  if [ -z "${digest}" ]; then
    printf '警告: 未取到 linux/%s 的清单 digest，体积记为 unknown\n' "${arch}" >&2
    printf '%s\n' "-1"
    return 0
  fi
  raw="$(docker buildx imagetools inspect "${IMAGE}@${digest}" --raw 2>/dev/null || true)"
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
  # 没有 jq（或 jq 解析失败）时回落到 grep：只能扫全文档，靠 1 MiB 门闸兜底
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

image_size_mb() (
  bytes="$(image_size_bytes "$1")"
  awk -v b="${bytes:--1}" \
    'BEGIN{ if (b < 0) print "unknown"; else printf "%.1fMB", b/1048576 }'
)

# ---------- APK 索引指纹 ----------
# 把「当前仓库里有什么包」压缩成一个确定值：apk update 后对 APKINDEX 求 sha256。
# 它进 Dockerfile 装包层的命令文本，于是：
#   索引没变 → 缓存键不变 → 命中；
#   任何包升级 → 索引变化 → 装包层重跑，拿到新包。
# 这比「按天击穿」精确：没变化时不会白装一遍，有变化时也不会漏。
# 解析失败输出空串，调用方据此关闭缓存（宁可全量重建，也不读可能过期的缓存）。
resolve_apk_index_digest() ( # $1=基础镜像引用 $2=是否换成腾讯云源(1/0)
  ref=$1
  mirror=${2:-0}
  docker run --rm --platform linux/amd64 -e "MIRROR=${mirror}" "${ref}" sh -eu -c '
    if [ "${MIRROR}" = "1" ]; then
      sed -i "s@dl-cdn.alpinelinux.org@mirrors.cloud.tencent.com@g" /etc/apk/repositories
    fi
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

IMAGE="${CNB_DOCKER_REGISTRY}/${CNB_REPO_SLUG_LOWERCASE}"
# cron 不传 version。用 set +u 临时关掉未定义检查来兜住，而不是写成 ${version:-}：
# 带 :- 的写法在 CI 的 import/模板处理里被改写风险最高。
set +u
version="$version"
set -u

echo "=============================="
echo "🔧 构建多架构基础镜像"
echo "=============================="

# ---------- 1. version 校验 ----------
# 入参只有这几种形态：留空（= 跟随 Dockerfile 默认，即 latest）、latest、
# 3.25 / 3.25.1、3.25.1@sha256:<64 位 hex>。
# 前两种是「每天跟上游」，后两种是「钉住某次」；其它一律拒绝，免得非法值
# 拼进 FROM 或标签名，跑到一半才失败。
case "$version" in
  '' | latest) : ;;
  *)
    printf '%s' "${version}" \
      | grep -Eq '^[0-9]+\.[0-9]+(\.[0-9]+)?(@sha256:[0-9a-f]{64})?$' \
      || die "version 只接受 latest / 3.25 / 3.25.1 / 3.25.1@sha256:<digest>，收到：${version}"
    ;;
esac

# ---------- 2. 基座引用 ----------
if [ -n "$version" ]; then
  ALPINE_REF="$version"
  info "version 入参 $version"
else
  [ -f "$DOCKERFILE" ] \
    || die "找不到 $DOCKERFILE（当前目录 $(pwd)）：请在仓库根目录执行本脚本"
  ALPINE_REF="$(sed -n 's/^ARG ALPINE_VERSION=//p' "$DOCKERFILE" | head -n 1 \
    | sed 's/[[:space:]]*#.*//' | tr -d '[:space:]')"
  [ -n "${ALPINE_REF}" ] || die "无法从 $DOCKERFILE 解析 ARG ALPINE_VERSION"
  info "version 未传：使用 $DOCKERFILE 里的 ${ALPINE_REF}"
fi

# ---------- 3. 解析基座的实际版本与 digest ----------
# 标签里不能出现 latest：下游看到 3.25.1 才知道自己吃到的是哪个版本。
# 所以先起一个一次性容器，把 alpine:latest 解析成具体版本号。
# digest 取 index 的，写进元数据与 OCI label，用来钉住「这次的最新是哪一份」。
info "解析基座 alpine:${ALPINE_REF} 的实际版本"
ALPINE_REAL="$(docker run --rm --platform linux/amd64 "alpine:${ALPINE_REF}" \
  cat /etc/alpine-release 2>/dev/null | sed 's/-r[0-9]*$//' | tr -d '[:space:]' || true)"
printf '%s' "${ALPINE_REAL}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || die "无法解析 alpine:${ALPINE_REF} 的版本（得到：${ALPINE_REAL:-空}），检查 Docker 服务与网络"
BASE_DIGEST="$(docker buildx imagetools inspect "alpine:${ALPINE_REF}" \
  --format '{{.Manifest.Digest}}' 2>/dev/null || true)"
[ -n "${BASE_DIGEST}" ] || BASE_DIGEST="unknown"
# 滚动 minor 固定取 major.minor（3.25.1 → 3.25，后续把 3.25 指到最新一次）
MINOR="$(printf '%s' "${ALPINE_REAL}" | cut -d. -f1,2)"

# ---------- 3.5 解析 APK 索引指纹（缓存击穿点） ----------
# 装包层的缓存键里会带这个值。索引不变 → 命中；任何包升级 → 重跑 apk add。
# 解析失败就把本次降级成 CACHE=off：宁可全量重建，也不读可能过期的缓存。
APK_INDEX_DIGEST="disabled"
if [ "${CACHE}" = "on" ]; then
  info "解析 APK 仓库索引指纹（缓存击穿点）"
  APK_INDEX_DIGEST="$(resolve_apk_index_digest "alpine:${ALPINE_REF}" 1)"
  if [ -z "${APK_INDEX_DIGEST}" ]; then
    warn "APK 索引解析失败，本次关闭缓存（全量重建）"
    CACHE="off"
    APK_INDEX_DIGEST="unknown"
  else
    info "APK_INDEX_DIGEST ${APK_INDEX_DIGEST}"
  fi
fi

# ---------- 4. 时间戳与标签 ----------
# BUILD_DATE 取最后一次提交时间而非当前时间：同一份源码重复构建出同样的
# config/label，同 STAMP 的两次构建才能逐字节比对。
BUILD_DATE="$(git log -1 --format=%cI 2>/dev/null || true)"
[ -n "${BUILD_DATE}" ] || BUILD_DATE="${EPOCH_DATE}"
# 标签名就是 alpine 的版本号，不加日期：每天重建会覆盖同名标签（3.24.3 → 3.24.3），
# 这是刻意的——alpine 的版本就是产品的版本。代价是「昨天那份」没有标签可指，
# 只能靠元数据里记录的 digest 回查（见第 11 段），所以 built_at 必须每次都写。
STAMP="${ALPINE_REAL}"
VCS_REF="${CNB_COMMIT:-unknown}"
VCS_REF_SHORT="$(printf '%s' "${VCS_REF}" | cut -c1-7)"
# 构建时刻只进元数据，不进镜像：进镜像会让同一份源码每次构建的 config 都不同
BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

info "ALPINE_REF  ${ALPINE_REF}"
info "ALPINE_REAL ${ALPINE_REAL}"
info "BASE_DIGEST ${BASE_DIGEST}"
info "APK_INDEX   ${APK_INDEX_DIGEST}"
info "CACHE       ${CACHE}"
info "MINOR       ${MINOR}"
info "STAMP       ${STAMP}"
info "BUILD_DATE  ${BUILD_DATE}"
info "VCS_REF     ${VCS_REF}（短 sha ${VCS_REF_SHORT}）"

# ---------- 5. 登录 ----------
info "登录 ${CNB_DOCKER_REGISTRY}"
printf '%s' "${CNB_TOKEN}" \
  | docker login -u "${CNB_TOKEN_USER_NAME}" --password-stdin "${CNB_DOCKER_REGISTRY}" \
  || die "docker login 失败"

# ---------- 6. buildx 自检 ----------
# CNB 的 services: docker 已内置可做多架构的 builder，不要再 create
# --driver docker-container：受限容器里拉不起嵌套 buildkitd，会 bootstrap 失败。
docker buildx version || die "docker buildx 不可用"
docker buildx inspect >/dev/null || die "buildx builder 不可用"

# ---------- 7. 一次多架构构建（唯一的构建） ----------
# 直接推到 ${STAMP}（即 alpine 版本）标签；MINOR / latest 在冒烟通过后由 digest 提升。
# 没有额外的不可变标签：同名标签每天被覆盖，历史只能靠元数据里的 digest 追。
#
# registry 缓存：每个镜像用自己的 <镜像>:buildcache，mode=min（单阶段构建，
# 所有层都在最终镜像里，min 足够）。装包层的缓存键里带 APK_INDEX_DIGEST：
# 上游没变化时命中，有包升级时重跑 apk add。
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
  set -- \
    -t "${IMAGE}:${STAMP}" \
    --platform "${PLATFORMS}" \
    --pull \
    --build-arg "ALPINE_VERSION=${ALPINE_REF}" \
    --build-arg "IMAGE_VERSION=${STAMP}" \
    --build-arg "VCS_REF=${VCS_REF}" \
    --build-arg "BUILD_DATE=${BUILD_DATE}" \
    --build-arg "BASE_DIGEST=${BASE_DIGEST}" \
    --build-arg "APK_INDEX_DIGEST=${APK_INDEX_DIGEST}" \
    --build-arg "IMAGE_SOURCE=${CNB_REPO_URL_HTTPS}" \
    --provenance=mode=min \
    --sbom=false
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

# ---------- 8. 从同一 manifest 派生单平台标签 ----------
# 不重新构建：digest 与 index 里的条目完全一致，省掉两次构建
# （其中 arm64 那次要在 amd64 runner 上用 QEMU 重跑一遍 apk add，最贵）
# 派生标签同样每天被覆盖，它只解决「只认单平台标签的工具」，不承担历史职责
for arch in amd64 arm64; do
  digest="$(manifest_digest_for "${arch}")"
  [ -n "${digest}" ] || die "未在 ${IMAGE}:${STAMP} 中找到 linux/${arch} 条目"
  docker buildx imagetools create -t "${IMAGE}:${STAMP}-linux-${arch}" "${IMAGE}@${digest}" \
    || die "派生 ${STAMP}-linux-${arch} 失败"
  info "派生 ${STAMP}-linux-${arch} ← ${digest}"
done

# ---------- 9. 冒烟测试（amd64，只跑一次） ----------
# 六项断言：基座版本、时区、源配置（腾讯云 main + community 两行）、五个命令可用性、OCI 版本标签。
# 先显式 pull：buildx --push 只把镜像推进制品库，本地没有；让 `docker run` 隐式
# 拉取会把「Unable to find image ... / Pulling fs layer」写进要断言的输出里。
docker pull --platform linux/amd64 "${IMAGE}:${STAMP}" \
  || die "拉取 ${IMAGE}:${STAMP} 失败，latest 未提升"
info "冒烟测试 ${IMAGE}:${STAMP}（linux/amd64）"
if ! smoke_output="$(docker run --rm --platform linux/amd64 \
  -e EXPECT_ALPINE="${ALPINE_REAL}" "${IMAGE}:${STAMP}" sh -eu -c '
    fail=""
    [ "$(cut -d- -f1 /etc/alpine-release)" = "${EXPECT_ALPINE}" ] || fail="${fail} alpine-release"
    [ "$(cat /etc/timezone 2>/dev/null)" = "Asia/Shanghai" ] || fail="${fail} /etc/timezone"
    [ "$(date +%z)" = "+0800" ] || fail="${fail} date+%z"
    [ "$(wc -l </etc/apk/repositories)" -eq 2 ] || fail="${fail} apk-repositories"
    for b in curl drill git nc nslookup; do
      command -v "$b" >/dev/null 2>&1 || fail="${fail} bin:$b"
    done
    if [ -n "${fail}" ]; then printf "FAIL%s" "${fail}"; exit 1; fi
    printf "SMOKE_OK"
  ' 2>&1)"; then
  die "冒烟测试失败，latest 未提升：${smoke_output:-docker run 无输出}"
fi
# 精确相等比对会被 docker 的杂项输出（平台警告、镜像名提示）打破，这里只认标记
case "${smoke_output}" in
  *SMOKE_OK*) : ;;
  *) die "冒烟测试输出异常，latest 未提升：${smoke_output}" ;;
esac

# 镜像已在上一步 pull 到本地，可以直接读 config 里的 label
label_version="$(docker image inspect \
  --format '{{index .Config.Labels "org.opencontainers.image.version"}}' \
  "${IMAGE}:${STAMP}" 2>/dev/null || true)"
[ "${label_version}" = "${STAMP}" ] \
  || die "OCI label 校验失败：org.opencontainers.image.version=${label_version:-<空>}，期望 ${STAMP}"

# ---------- 10. 提升可变标签（冒烟之后才动） ----------
# 顺序固定 minor 在前、latest 最后：minor 失败时 latest 一定还指向旧产物。
# 只有这两个标签是「移动」的，${STAMP} 在构建阶段就已经推上去了。
# 注意：冒烟失败时 ${STAMP} 指向的是这份坏产物（没有临时标签可以退回），
# 但 latest / MINOR 不会动，下游按这两个标签拉取不受影响。
for tag in "${MINOR}" latest; do
  docker buildx imagetools create -t "${IMAGE}:${tag}" "${IMAGE}:${STAMP}" \
    || die "提升 ${tag} 失败"
  info "提升 ${IMAGE}:${tag} → ${STAMP}"
done

# ---------- 11. 汇总元数据 ----------
INDEX_DIGEST="$(docker buildx imagetools inspect "${IMAGE}:${STAMP}" \
  --format '{{.Manifest.Digest}}' 2>/dev/null || true)"
DIGEST_SHORT="$(printf '%s' "${INDEX_DIGEST#sha256:}" | cut -c1-12)"
SIZE_AMD64="$(image_size_mb amd64)"
SIZE_ARM64="$(image_size_mb arm64)"

# 向 CNB Stage Result 输出变量（必须 source 才生效）
# interior_version 保留旧名（=解析出来的 alpine 版本，兼容既有文档），image_version 是本产物
printf '##[set-output interior_version=%s]\n' "${ALPINE_REAL}"
printf '##[set-output image_version=%s]\n' "${STAMP}"
export INTERIOR_VERSION="${ALPINE_REAL}"
export IMAGE_VERSION="${STAMP}"

# 元数据 key 只允许 0-9a-zA-Z_-，value 不允许含换行，故这里只放单行值
mkdir -p .cnb
cat >.cnb/annotation.json <<EOF
{
  "image_digest": "${INDEX_DIGEST:-unknown}",
  "image_digest_short": "${DIGEST_SHORT:-unknown}",
  "image_version": "${STAMP}",
  "alpine_version": "${ALPINE_REAL}",
  "base_image": "alpine:${ALPINE_REF}",
  "base_digest": "${BASE_DIGEST}",
  "image_size": "${SIZE_AMD64}",
  "image_size_arm64": "${SIZE_ARM64}",
  "apk_index_digest": "${APK_INDEX_DIGEST}",
  "cache": "${CACHE}",
  "built_at": "${BUILT_AT}",
  "source_date": "${BUILD_DATE}"
}
EOF

info "digest  ${INDEX_DIGEST:-unknown}"
info "size    amd64 ${SIZE_AMD64} / arm64 ${SIZE_ARM64}"
info "元数据  .cnb/annotation.json"

echo "=============================="
echo "🎉 构建完成 ${IMAGE}:${STAMP}"
echo "=============================="
