#!/bin/sh
# ===================================================================
# GitHub Actions 专用：多架构（linux/amd64 + linux/arm64）构建并推送
# Alpine 基础镜像到 GHCR
#
# 这是 .cnb/scripts/build-alpine.sh 的 GitHub 侧副本：两个平台有意各留一份，
# 不互相引用（CNB 侧读取的是 CNB_* 变量、输出 CNB 的 annotation；这里读取的是
# 下面这组 GitHub 语义的变量、输出 Step Summary 用的 JSON）。
# 代价是改标签规则/冒烟断言时要同步两份；收益是任何一侧都不必为对方的约定
# 让路（例如 CNB 的 imports 改写风险、CNB 的 annotation 插件都不再影响这里）。
#
# 环境变量（默认从 GitHub Actions 内置变量派生，显式传同名变量可覆盖）：
#   REGISTRY_TOKEN 必填，docker login 密码（workflow 里传 secrets.GITHUB_TOKEN；
#                  GITHUB_TOKEN 不会自动进环境变量，这是唯一必须显式传的）
#   IMAGE          默认 ghcr.io + GITHUB_REPOSITORY（转小写），完整镜像名
#   REGISTRY_USER  默认 GITHUB_ACTOR
#   REVISION       默认 GITHUB_SHA，写进 OCI revision
#   IMAGE_SOURCE   默认 https://github.com/<GITHUB_REPOSITORY>，写进 OCI source/url
#   version        选填，空/latest = 跟随 Dockerfile 的 alpine:latest
#
# 设计约束（改之前先读，五条互相牵制）：
#   1. 只构建一次多架构，单平台标签从同一份 manifest 派生 —— 不重建，
#      所以三类标签的 digest 天然相同。
#   2. 基座跟随上游：Dockerfile 的 ARG ALPINE_VERSION 默认 latest，定时任务
#      每天重建就能吃到新补丁甚至新小版本；具体版本由脚本解析成 3.25.1 这种
#      确定值，写进标签与 OCI label，标签名因此永远是可读的 alpine 版本号。
#   3. 标签就是 alpine 版本号（不加日期）：先推 <版本>，冒烟通过后才提升 latest / minor。
#      同名标签每天被覆盖，历史只能靠元数据里的 digest 追；冒烟失败时 latest / minor 不动。
#   4. 必须 source 执行：GITHUB_OUTPUT 与 export 只在当前 shell 生效，
#      用 `sh build-alpine.sh` 跑会静默丢掉这两件事。
#   5. 不启用任何层缓存：唯一那层 RUN 一旦命中缓存就不会再执行 apk add，
#      每日 cron 会永远装到同一批包。宁可每次多跑几秒，也要让「重建=刷新依赖」。
#
# 依赖：docker buildx（setup-buildx-action 提供）、jq 可选（体积精确求和）。
# ===================================================================

set -eu

# ---------- 常量 ----------
# 路径写死：脚本始终从仓库根目录执行（workflow 里 checkout 后即是）。
DOCKERFILE=".github/docker/Dockerfile.alpine"
PLATFORMS="linux/amd64,linux/arm64"
EPOCH_DATE="1970-01-01T00:00:00Z"
# 1 MiB：正常 alpine 派生镜像不可能低于此值，低于说明拿到的不是镜像清单
MIN_IMAGE_BYTES=1048576
# 构建元数据落盘位置：workflow 的 Step Summary / artifact 步骤读它
ANNOTATION_FILE=".github/annotation.json"

# ---------- 输出助手 ----------
info() { printf '  %s\n' "$*"; }
die() {
  printf '错误: %s\n' "$*" >&2
  exit 1
}

# ---------- 0. 环境检查与默认值 ----------
# 与 CNB 侧从内置变量取地址（CNB_DOCKER_REGISTRY + CNB_REPO_SLUG_LOWERCASE）同理：
# GitHub 侧优先从 Actions 内置变量派生，不把 ghcr.io/<owner>/<repo> 写死在 workflow 里。
#   IMAGE          ← ghcr.io + GITHUB_REPOSITORY（转小写）
#   REGISTRY_USER  ← GITHUB_ACTOR
#   REVISION       ← GITHUB_SHA
#   IMAGE_SOURCE   ← https://github.com/<GITHUB_REPOSITORY>
# 显式传同名变量可覆盖（fork、本地复跑、试推时用）。
: "${REGISTRY_TOKEN:?缺少环境变量 REGISTRY_TOKEN（workflow 里传 secrets.GITHUB_TOKEN）}"

version="${version:-}"
_slug="$(printf '%s' "${GITHUB_REPOSITORY:-}" | tr '[:upper:]' '[:lower:]')"
REGISTRY_USER="${REGISTRY_USER:-${GITHUB_ACTOR:-}}"
REVISION="${REVISION:-${GITHUB_SHA:-unknown}}"
IMAGE_SOURCE="${IMAGE_SOURCE:-https://github.com/${GITHUB_REPOSITORY:-}}"

[ -n "${REGISTRY_USER}" ] || die "无法确定 REGISTRY_USER：请在 GitHub Actions 里运行（GITHUB_ACTOR 自动可用），或显式传 REGISTRY_USER"

# 镜像名：优先用显式传入的 IMAGE，否则从 GITHUB_REPOSITORY 派生
if [ -z "${IMAGE:-}" ]; then
  [ -n "${_slug}" ] || die "无法确定 IMAGE：请在 GitHub Actions 里运行（GITHUB_REPOSITORY 自动可用），或显式传 IMAGE=ghcr.io/<owner>/<repo>"
  IMAGE="ghcr.io/${_slug}"
fi
case "${IMAGE}" in
  *//* | */) die "IMAGE 含空路径段：${IMAGE}" ;;
esac
case "${IMAGE}" in
  */*/*) : ;;
  *) die "IMAGE 必须形如 ghcr.io/<owner>/<repo>，收到：${IMAGE}" ;;
esac
case "${IMAGE_SOURCE}" in
  *://*) : ;;
  *) die "无法确定 IMAGE_SOURCE（得到：${IMAGE_SOURCE:-空}）：请在 GitHub Actions 里运行，或显式传 IMAGE_SOURCE=https://github.com/<owner>/<repo>" ;;
esac

REGISTRY="${IMAGE%%/*}"
case "${REGISTRY}" in
  *.* | localhost) : ;;
  *) die "IMAGE 必须带 registry 前缀（如 ghcr.io/<owner>/<repo>），收到：${IMAGE}" ;;
esac
# GHCR 的仓库名必须小写；大写会在 push 阶段才被拒，提前拦下来
case "${IMAGE}" in
  *[A-Z]*) die "IMAGE 不能含大写字母：${IMAGE}" ;;
esac

# 凭证只在本次构建内有效：结束时删掉登录态，避免残留在 runner 上
set +u
HOMEDIR="$HOME"
set -u
[ -n "$HOMEDIR" ] || HOMEDIR=/root
cleanup() { rm -f "$HOMEDIR/.docker/config.json"; }
trap cleanup EXIT

echo "=============================="
echo "🔧 构建多架构基础镜像（GHCR）"
echo "=============================="

# ---------- 1. version 校验 ----------
# 入参只有这几种形态：留空（= 跟随 Dockerfile 默认，即 latest）、latest、
# 3.25 / 3.25.1、3.25.1@sha256:<64 位 hex>。
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

# ---------- 4. 时间戳与标签 ----------
# BUILD_DATE 取最后一次提交时间而非当前时间：同一份源码重复构建出同样的
# config/label，同 STAMP 的两次构建才能逐字节比对。
BUILD_DATE="$(git log -1 --format=%cI 2>/dev/null || true)"
[ -n "${BUILD_DATE}" ] || BUILD_DATE="${EPOCH_DATE}"
# 标签名就是 alpine 的版本号，不加日期：每天重建会覆盖同名标签（3.24.3 → 3.24.3），
# 这是刻意的——alpine 的版本就是产品的版本。代价是「昨天那份」没有标签可指，
# 只能靠元数据里记录的 digest 回查（见第 11 段），所以 built_at 必须每次都写。
STAMP="${ALPINE_REAL}"
VCS_REF="${REVISION}"
VCS_REF_SHORT="$(printf '%s' "${VCS_REF}" | cut -c1-7)"
# 构建时刻只进元数据，不进镜像：进镜像会让同一份源码每次构建的 config 都不同
BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

info "IMAGE       ${IMAGE}"
info "ALPINE_REF  ${ALPINE_REF}"
info "ALPINE_REAL ${ALPINE_REAL}"
info "BASE_DIGEST ${BASE_DIGEST}"
info "MINOR       ${MINOR}"
info "STAMP       ${STAMP}"
info "SOURCE      ${IMAGE_SOURCE}"
info "BUILD_DATE  ${BUILD_DATE}"
info "VCS_REF     ${VCS_REF}（短 sha ${VCS_REF_SHORT}）"

# ---------- 5. 登录 ----------
info "登录 ${REGISTRY}"
printf '%s' "${REGISTRY_TOKEN}" \
  | docker login -u "${REGISTRY_USER}" --password-stdin "${REGISTRY}" \
  || die "docker login 失败"

# ---------- 6. buildx 自检 ----------
# setup-buildx-action 已创建 docker-container builder；这里只确认可用。
docker buildx version || die "docker buildx 不可用"
docker buildx inspect >/dev/null || die "buildx builder 不可用"

# ---------- 7. 一次多架构构建（唯一的构建） ----------
# 直接推到 ${STAMP}（即 alpine 版本）标签；MINOR / latest 在冒烟通过后由 digest 提升。
# 没有额外的不可变标签：同名标签每天被覆盖，历史只能靠元数据里的 digest 追。
#
# 刻意不用缓存（gha / registry 都不用）：本镜像只有一个 RUN，缓存能复用的就是
# 这一层，一旦命中就再也不会执行 apk add —— 每日 cron 会永远装到同一批包。
# 代价也只是每次多跑一遍「2 个索引 + 6 个包」（实测秒级）。
info "构建 ${IMAGE}:${STAMP}（${PLATFORMS}）"
docker buildx build \
  -t "${IMAGE}:${STAMP}" \
  --platform "${PLATFORMS}" \
  --build-arg "ALPINE_VERSION=${ALPINE_REF}" \
  --build-arg "IMAGE_VERSION=${STAMP}" \
  --build-arg "IMAGE_SOURCE=${IMAGE_SOURCE}" \
  --build-arg "VCS_REF=${VCS_REF}" \
  --build-arg "BUILD_DATE=${BUILD_DATE}" \
  --build-arg "BASE_DIGEST=${BASE_DIGEST}" \
  --provenance=mode=min \
  --sbom=false \
  -f "$DOCKERFILE" \
  --push . \
  || die "docker buildx build 失败"

# ---------- 8. 从同一 manifest 派生单平台标签 ----------
# 取某平台「镜像清单」的 digest。必须定位到镜像清单本身：
# manifest list / index 没有 layers 字段，对它求体积只会得到几 KB 的假值。
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

# 不重新构建：digest 与 index 里的条目完全一致，省掉两次构建
# （其中 arm64 那次要在 amd64 runner 上用 QEMU 重跑一遍 apk add，最贵）
for arch in amd64 arm64; do
  digest="$(manifest_digest_for "${arch}")"
  [ -n "${digest}" ] || die "未在 ${IMAGE}:${STAMP} 中找到 linux/${arch} 条目"
  docker buildx imagetools create -t "${IMAGE}:${STAMP}-linux-${arch}" "${IMAGE}@${digest}" \
    || die "派生 ${STAMP}-linux-${arch} 失败"
  info "派生 ${STAMP}-linux-${arch} ← ${digest}"
done

# ---------- 9. 冒烟测试（amd64，只跑一次） ----------
# 六项断言：基座版本、时区、源配置（官方 main + community 两行）、五个命令可用性、OCI 版本标签。
# 先显式 pull：buildx --push 只把镜像推进 registry，本地没有；让 `docker run` 隐式
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
for tag in "${MINOR}" latest; do
  docker buildx imagetools create -t "${IMAGE}:${tag}" "${IMAGE}:${STAMP}" \
    || die "提升 ${tag} 失败"
  info "提升 ${IMAGE}:${tag} → ${STAMP}"
done

# ---------- 11. 汇总元数据 ----------
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

INDEX_DIGEST="$(docker buildx imagetools inspect "${IMAGE}:${STAMP}" \
  --format '{{.Manifest.Digest}}' 2>/dev/null || true)"
DIGEST_SHORT="$(printf '%s' "${INDEX_DIGEST#sha256:}" | cut -c1-12)"
SIZE_AMD64="$(image_size_mb amd64)"
SIZE_ARM64="$(image_size_mb arm64)"

# 构建元数据落盘：workflow 的「写入运行摘要」「上传构建元数据」两步读这个文件
mkdir -p "$(dirname "${ANNOTATION_FILE}")"
cat >"${ANNOTATION_FILE}" <<EOF
{
  "image_ref": "${IMAGE}",
  "image_digest": "${INDEX_DIGEST:-unknown}",
  "image_digest_short": "${DIGEST_SHORT:-unknown}",
  "image_version": "${STAMP}",
  "alpine_version": "${ALPINE_REAL}",
  "base_image": "alpine:${ALPINE_REF}",
  "base_digest": "${BASE_DIGEST}",
  "image_size": "${SIZE_AMD64}",
  "image_size_arm64": "${SIZE_ARM64}",
  "built_at": "${BUILT_AT}",
  "source_date": "${BUILD_DATE}",
  "revision": "${VCS_REF}"
}
EOF

# 交给后续步骤（step outputs）：workflow 里给这一步加 id: build 即可引用
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    printf 'image_version=%s\n' "${STAMP}"
    printf 'image_digest=%s\n' "${INDEX_DIGEST:-unknown}"
    printf 'alpine_version=%s\n' "${ALPINE_REAL}"
  } >>"${GITHUB_OUTPUT}"
fi

info "digest  ${INDEX_DIGEST:-unknown}"
info "size    amd64 ${SIZE_AMD64} / arm64 ${SIZE_ARM64}"
info "元数据  ${ANNOTATION_FILE}"

echo "=============================="
echo "🎉 构建完成 ${IMAGE}:${STAMP}"
echo "=============================="
