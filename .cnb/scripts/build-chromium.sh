#!/bin/sh
# ===================================================================
# 多架构（linux/amd64 + linux/arm64）构建并推送 Chromium 镜像
#
# 产物路径：<registry>/<仓库 slug>/chromium
#   主仓库 → docker.cnb.cool/dtapp/alpine/chromium
#   fork   → docker.cnb.cool/<你的命名空间>/alpine/chromium
# 三个变体一次构建完成：
#   default    latest / <alpine 版本>
#   -cjk       latest-cjk / <alpine 版本>-cjk
#   -headless  latest-headless / <alpine 版本>-headless
#   另有 latest[-cjk|-headless]-linux-{amd64,arm64} 十二个单平台标签（版本标签同理）。
#
# 设计约束（改之前先读，四条互相牵制）：
#   1. 镜像必须挂在 <仓库 slug>/chromium 这个子路径下：本仓库同时发布 Alpine
#      基础镜像（<仓库 slug>），chromium 若推到 <仓库 slug> 会把它的 latest 顶掉。
#   2. 必须 source 执行：##[set-output] 与 export 只在当前 shell 生效。
#   3. 不要把本脚本放进 .cnb.yml 的 imports：imports 会改写 ${...} 字面量。
#   4. 入参 version 是 Alpine 版本，不是 Chromium 版本；Chromium 版本由该
#      Alpine 分支的软件包仓库决定，实际值写进 chromium_version 元数据。
#
# 依赖：docker buildx（CNB services: docker 自带）、jq 可选、git 可选。
# ===================================================================
set -eu

# ---------- 常量 ----------
# 路径写死、不做变量拼接：与 build-alpine.sh 一样，这一行没有 ${...}，
# 谁来做模板处理都改不到它。
DOCKERFILE=".cnb/docker/Dockerfile.chromium"
DOCKERFILE_HEADLESS=".cnb/docker/Dockerfile.headless"
PLATFORMS="linux/amd64,linux/arm64"
MIN_IMAGE_BYTES=1048576
EPOCH_DATE="1970-01-01T00:00:00Z"

# ---------- 输出助手 ----------
info() { printf '  %s\n' "$*"; }
die() {
  printf '错误: %s\n' "$*" >&2
  exit 1
}

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
case "${IMAGE}" in
  */chromium) : ;;
  *) die "镜像路径异常：${IMAGE}（必须以 /chromium 结尾，否则会顶掉 Alpine 基础镜像的标签）" ;;
esac

# cron 不传 version。用 set +u 临时关掉未定义检查来兜住，而不是写成 ${version:-}：
# 带 :- 的写法在 CI 的模板处理里被改写风险最高（见 .cnb.yml 的 imports 注释）。
set +u
version="$version"
set -u

version=$(printf '%s' "${version}" | tr -d '[:space:]')
version=$(printf '%s' "${version}" | sed 's/[^[:print:]]//g')
[ -n "${version}" ] || version="latest"

echo "=============================="
echo "🔧 构建多架构 Chromium 镜像"
echo "=============================="
info "IMAGE     ${IMAGE}"
info "version   ${version}（Alpine 版本；latest = 跟随上游）"

# ---------- 1. version 校验 ----------
# 只接受 latest 或 3.24 / 3.24.3 这类 Alpine 版本号；Chromium 版本号一律拒绝，
# 免得它被拼进 FROM alpine:${JAVA} 之类的非法引用，跑到一半才失败。
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
set +u
expected_chromium_major="$expected_chromium_major"
set -u
expected_chromium_major=$(printf '%s' "${expected_chromium_major}" | tr -d '[:space:]')
EXPECTED_ARG=""
if [ -n "${expected_chromium_major}" ]; then
  case "${expected_chromium_major}" in
    any | [0-9]*) : ;;
    *) die "expected_chromium_major 只接受主版本号（如 155）或 any，收到：${expected_chromium_major}" ;;
  esac
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
# 装包层缓存击穿点：按天变化。启用跨轮次缓存后如果这里不变，apk 层永远命中
# 缓存，上游 chromium 补丁就再也进不到镜像里。
CACHE_BUST="$(date -u +%Y%m%d)"

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

# 公共构建参数：--pull 保证基础镜像不是 builder 里的旧层；
# CACHE_BUST 只影响装包层，改 Dockerfile 其它部分不会连带重装 chromium。
#
# 注意：ALPINE_VERSION 始终显式传入。cron 不传 version 时落到 latest，
# 与 Dockerfile 默认值一致；PR 校验也不传参数，验证的就是默认值。
# shellcheck disable=SC2086 # ATTEST_ARGS / EXPECTED_ARG 需要按空格拆成多个参数
COMMON_ARGS="--pull ${ATTEST_ARGS} ${EXPECTED_ARG} \
  --build-arg ALPINE_VERSION=${version} \
  --build-arg BUILD_DATE=${BUILD_DATE} \
  --build-arg BUILD_REVISION=${BUILD_REVISION} \
  --build-arg CACHE_BUST=${CACHE_BUST} \
  --build-arg IMAGE_SOURCE=${CNB_REPO_URL_HTTPS}"

# ---------- 4. 标签与变体构建 ----------
tags_for() { # $1=变体后缀 → 输出 -t 参数串
  _tags="-t ${IMAGE}:latest$1"
  if [ "${version}" != "latest" ]; then
    _tags="${_tags} -t ${IMAGE}:${version}$1"
  fi
  printf '%s' "${_tags}"
}

build_variant() { # $1=后缀 $2=Dockerfile $3=额外 build-arg
  _suffix="$1"
  _dockerfile="$2"
  _extra="$3"
  _label=${_suffix#-}
  _tags="$(tags_for "${_suffix}")"
  info "构建变体 ${_label:-default}"
  # shellcheck disable=SC2086 # _tags / COMMON_ARGS / _extra 需要按空格拆开
  docker buildx build ${_tags} --platform "${PLATFORMS}" ${COMMON_ARGS} ${_extra} \
    --cache-from "type=registry,ref=${IMAGE}:buildcache${_suffix}" \
    --cache-to "type=registry,ref=${IMAGE}:buildcache${_suffix},mode=min" \
    -f "${_dockerfile}" --push . \
    || die "变体 ${_label:-default} 构建失败"
}

info "== 1/3 default 变体 =="
build_variant "" "${DOCKERFILE}" ""

info "== 2/3 -cjk 变体（font-noto-cjk，+88.8MiB） =="
build_variant "-cjk" "${DOCKERFILE}" "--build-arg WITH_CJK=1"

# -headless 基于刚推上去的同一批 default 镜像，用 digest 固定，
# 避免 --pull 又去拉一次 tag（也避免并发构建时 latest 已经挪走）
info "== 3/3 -headless 变体（默认无头参数 + tini） =="
BASE_REF="${IMAGE}:latest"
if [ "${version}" != "latest" ]; then
  BASE_REF="${IMAGE}:${version}"
fi
BASE_DIGEST="$(docker buildx imagetools inspect "${BASE_REF}" --format '{{.Manifest.Digest}}' 2>/dev/null || true)"
if [ -n "${BASE_DIGEST}" ]; then
  info "headless 基座 ${BASE_REF}@${BASE_DIGEST}"
  build_variant "-headless" "${DOCKERFILE_HEADLESS}" "--build-arg BASE_IMAGE=${IMAGE}@${BASE_DIGEST}"
else
  info "⚠️ 取不到 base digest，-headless 变体退回按 tag 构建"
  build_variant "-headless" "${DOCKERFILE_HEADLESS}" ""
fi

# ---------- 5. 冒烟（amd64，只跑一次） ----------
# 放在派生单平台标签之前：镜像坏了就不要再往外派生更多标签。
# 注意 latest* 已经在构建阶段推上去了（与拆分前的行为一致），冒烟失败时
# 流水线变红、元数据不写，latest 的替换只能等下一次成功构建。
info "冒烟测试 ${IMAGE}:latest（linux/amd64）"
docker pull --platform linux/amd64 "${IMAGE}:latest" >/dev/null 2>&1 \
  || die "拉取 ${IMAGE}:latest 失败，跳过后续派生"
CHROMIUM_VERSION="$(docker run --rm --platform linux/amd64 "${IMAGE}:latest" \
  chromium --version 2>/dev/null | awk '{print $2}' || true)"
case "${CHROMIUM_VERSION:-}" in
  [0-9]*.[0-9]*) : ;;
  *) die "冒烟失败：chromium --version 输出异常（得到：${CHROMIUM_VERSION:-空}）" ;;
esac
docker run --rm --platform linux/amd64 --shm-size=1g "${IMAGE}:latest" \
  chromium --headless --no-sandbox --disable-dev-shm-usage --dump-dom about:blank \
  >/dev/null 2>&1 \
  || die "冒烟失败：无头渲染 about:blank 退出码非 0"
[ "$(docker run --rm --platform linux/amd64 "${IMAGE}:latest" date +%Z 2>/dev/null)" = "CST" ] \
  || die "冒烟失败：容器内时区不是 CST"
info "chromium ${CHROMIUM_VERSION}，渲染与时区冒烟通过"

# ---------- 6. 单平台标签 ----------
# 直接从已推送的 manifest list 里取每个架构的清单 digest 打标签，
# 不重新构建：内容与多架构条目完全一致，digest 天然相同。
platform_digest() { # $1=镜像引用 $2=arch → 该架构镜像清单的 digest
  docker buildx imagetools inspect "$1" --format \
    "{{range .Manifest.Manifests}}{{if and (eq .Platform.OS \"linux\") (eq .Platform.Architecture \"$2\")}}{{.Digest}}{{end}}{{end}}" \
    2>/dev/null | tr -d '\n' || true
}

tag_single_platform() { # $1=后缀 $2=arch $3=digest
  docker buildx imagetools create -t "${IMAGE}:latest$1-linux-$2" "${IMAGE}@$3" || return 1
  if [ "${version}" != "latest" ]; then
    docker buildx imagetools create -t "${IMAGE}:${version}$1-linux-$2" "${IMAGE}@$3" || return 1
  fi
  return 0
}

for _suffix in "" "-cjk" "-headless"; do
  for _arch in amd64 arm64; do
    _digest="$(platform_digest "${IMAGE}:latest${_suffix}" "${_arch}")"
    if [ -z "${_digest}" ]; then
      info "⚠️ 取不到 latest${_suffix}/${_arch} 的平台 digest，跳过该单平台标签"
      continue
    fi
    tag_single_platform "${_suffix}" "${_arch}" "${_digest}" \
      || die "派生 latest${_suffix}-linux-${_arch} 失败"
    info "单平台标签 latest${_suffix}-linux-${_arch} → ${_digest}"
  done
done

# ---------- 7. 元数据 ----------
# 提示：本仓库同时发布 Alpine 基础镜像，它的元数据用 image_* 无前缀键，
# 这里必须全部加 chromium_ 前缀，否则同一个 commit 上两组键互相覆盖。
MANIFEST_REF="${IMAGE}:latest"
DIGEST="$(docker buildx imagetools inspect "${MANIFEST_REF}" --format '{{.Manifest.Digest}}' 2>/dev/null || true)"
[ -n "${DIGEST}" ] || DIGEST="unknown"
DIGEST_SHORT="$(printf '%s' "${DIGEST#sha256:}" | cut -c1-12)"

image_size_bytes() { # $1=arch → 字节数；解析失败输出 -1
  _arch="$1"
  _ref="${IMAGE}:latest-linux-${_arch}"
  _raw="$(docker buildx imagetools inspect "${_ref}" --raw 2>/dev/null || true)"
  case "${_raw}" in
    *'"layers"'*) : ;;
    *)
      _sub="$(platform_digest "${MANIFEST_REF}" "${_arch}")"
      if [ -n "${_sub}" ]; then
        _raw="$(docker buildx imagetools inspect "${IMAGE}@${_sub}" --raw 2>/dev/null || true)"
      fi
      ;;
  esac
  case "${_raw}" in
    *'"layers"'*) : ;;
    *)
      printf '%s\n' "-1"
      return 0
      ;;
  esac
  _bytes="$(printf '%s' "${_raw}" \
    | grep -o '"size":[[:space:]]*[0-9]\+' | grep -o '[0-9]\+' \
    | awk '{s+=$1} END{print s+0}')"
  if [ "${_bytes:-0}" -lt "${MIN_IMAGE_BYTES}" ]; then
    printf '%s\n' "-1"
    return 0
  fi
  printf '%s\n' "${_bytes}"
}

human_mb() { awk -v b="${1:--1}" 'BEGIN{if (b < 0) print "unknown"; else printf "%.1fMB", b/1048576}'; }

SIZE_AMD64="$(human_mb "$(image_size_bytes amd64)")"
SIZE_ARM64="$(human_mb "$(image_size_bytes arm64)")"
BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

mkdir -p .cnb
cat >.cnb/annotation.json <<EOF
{
  "chromium_image_digest": "${DIGEST}",
  "chromium_image_digest_short": "${DIGEST_SHORT}",
  "chromium_image_size": "${SIZE_AMD64}",
  "chromium_image_size_arm64": "${SIZE_ARM64}",
  "chromium_version": "${CHROMIUM_VERSION}",
  "chromium_built_at": "${BUILT_AT}"
}
EOF

printf '##[set-output chromium_version=%s]\n' "${CHROMIUM_VERSION}"
printf '##[set-output chromium_image_digest=%s]\n' "${DIGEST}"
info "digest    ${DIGEST}"
info "size      amd64 ${SIZE_AMD64} / arm64 ${SIZE_ARM64}"
info "chromium  ${CHROMIUM_VERSION}"
info "元数据    .cnb/annotation.json"

echo "=============================="
echo "🎉 Chromium 镜像构建完成"
echo "=============================="
