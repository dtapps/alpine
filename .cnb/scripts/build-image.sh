#!/bin/sh
# 多架构（linux/amd64 + linux/arm64）构建并推送 Docker 镜像
# 在单条流水线内用 docker buildx 完成，不再需要 amd64/arm64 两条流水线
# 外加第三条流水线（或定时任务）等待并合并 manifest list。
# 必须通过 `source` 执行，以支持 CNB 的 set-output 和变量导出

echo "原始 version: $version"
echo "CNB_DOCKER_REGISTRY: ${CNB_DOCKER_REGISTRY}"
echo "CNB_REPO_SLUG_LOWERCASE: ${CNB_REPO_SLUG_LOWERCASE}"

# 清理
version=$(echo "$version" | tr -d '[:space:]' | tr -d '\n\r')
version=$(echo "$version" | sed 's/[^[:print:]]//g')

# 空 version 自动转为 "latest"
[ -z "$version" ] && version="latest"

echo "处理 version: $version"

# 向 CNB Stage Result 输出变量（必须 source 才生效）
echo "##[set-output interior_version=$version]"

# 导出环境变量供后续命令使用
export INTERIOR_VERSION="$version"

# ========== 构建并推送 ==========
echo "=============================="
echo "🔧 开始处理 web_trigger_build_image"
echo "=============================="

# 登录 Docker Registry
echo " 登录 Docker Registry: ${CNB_DOCKER_REGISTRY}"
docker login -u "${CNB_TOKEN_USER_NAME}" -p "${CNB_TOKEN}" "${CNB_DOCKER_REGISTRY}" || exit 1

IMAGE_NAME="${CNB_REPO_SLUG_LOWERCASE}"
IMAGE="${CNB_DOCKER_REGISTRY}/${IMAGE_NAME}"
DOCKERFILE=".cnb/docker/Dockerfile"
BUILD_ARGS="--build-arg ALPINE_VERSION=${INTERIOR_VERSION}"
PLATFORMS="linux/amd64,linux/arm64"

# 多架构标签（manifest list）：latest 恒定推送；指定版本时额外推送版本标签
MULTI_TAGS="-t ${IMAGE}:latest"
# 分架构标签（单平台镜像）：保留 latest-linux-amd64 / latest-linux-arm64 这类标签
AMD64_TAGS="-t ${IMAGE}:latest-linux-amd64"
ARM64_TAGS="-t ${IMAGE}:latest-linux-arm64"

if [ "$INTERIOR_VERSION" != "latest" ]; then
  MULTI_TAGS="${MULTI_TAGS} -t ${IMAGE}:${INTERIOR_VERSION}"
  AMD64_TAGS="${AMD64_TAGS} -t ${IMAGE}:${INTERIOR_VERSION}-linux-amd64"
  ARM64_TAGS="${ARM64_TAGS} -t ${IMAGE}:${INTERIOR_VERSION}-linux-arm64"
fi

# ========== buildx 环境自检 ==========
# CNB 的 `services: docker` 默认已内置可做多架构的 buildx builder，直接用即可。
# 千万不要再 `docker buildx create --driver docker-container`——受限容器里拉不起
# 嵌套 buildkitd，会以 bootstrap 失败告终。
echo "== buildx 环境 =="
docker buildx version || exit 1
docker buildx ls || exit 1
docker buildx inspect >/dev/null || exit 1

# ========== 1/3 多架构 manifest list ==========
echo " 构建多架构镜像: ${MULTI_TAGS} (${PLATFORMS})"
# shellcheck disable=SC2086 # 标签需要按空格拆成多个 -t 参数
docker buildx build ${MULTI_TAGS} --platform "${PLATFORMS}" ${BUILD_ARGS} -f "${DOCKERFILE}" --push . || exit 1

# ========== 2/3 amd64 单平台标签 ==========
# 与 1/3 共用同一个 builder 的 BuildKit 层缓存，命中缓存后基本只剩推层开销
echo " 构建 amd64 单平台镜像: ${AMD64_TAGS}"
docker buildx build ${AMD64_TAGS} --platform linux/amd64 ${BUILD_ARGS} -f "${DOCKERFILE}" --push . || exit 1

# ========== 3/3 arm64 单平台标签 ==========
echo " 构建 arm64 单平台镜像: ${ARM64_TAGS}"
docker buildx build ${ARM64_TAGS} --platform linux/arm64 ${BUILD_ARGS} -f "${DOCKERFILE}" --push . || exit 1

# ========== 汇总制品元数据 ==========
# 产出扁平 JSON 交给下一步 cnbcool/annotations 插件，写入 commit 元数据，
# 最终在 README 里渲染成徽章（/-/badge/annotation/commit/latest/{key}）。
# 元数据 key 只允许 0-9a-zA-Z_-，value 不允许含换行，故这里只放单行值。
echo "== 汇总镜像元数据 =="
MANIFEST_REF="${IMAGE}:latest"
# 优先用文本输出里的 Digest 行（任何 buildx 版本都有）；取不到再退回模板
DIGEST=$(docker buildx imagetools inspect "${MANIFEST_REF}" 2>/dev/null | awk '/^Digest:/{print $2; exit}')
[ -z "$DIGEST" ] && DIGEST=$(docker buildx imagetools inspect "${MANIFEST_REF}" --format '{{.Manifest.Digest}}' 2>/dev/null)
DIGEST_SHORT=$(echo "${DIGEST#sha256:}" | cut -c1-12)

# ---------- 单平台压缩体积 ----------
# 体积必须按平台算：多架构 index 没有「总拉取体积」这种东西，用户只会拉自己平台那几层。
# 但也不能对 platform tag 直接求和 —— buildx 默认带 attestation，单平台推送出来的
# 依然是一个 index，里面每个条目的 size 只是「清单 JSON 自身」的一两 KB，不是层体积。
manifest_digest_of() { # $1=arch，输出该平台「镜像清单」的 digest
  local arch="$1" digest
  digest=$(docker buildx imagetools inspect "${MANIFEST_REF}" --format \
    "{{range .Manifest.Manifests}}{{if and (eq .Platform.OS \"linux\") (eq .Platform.Architecture \"${arch}\")}}{{.Digest}}{{end}}{{end}}" 2>/dev/null)
  [ -z "$digest" ] && digest=$(docker buildx imagetools inspect "${IMAGE}:latest-linux-${arch}" --format \
    "{{range .Manifest.Manifests}}{{if and (eq .Platform.OS \"linux\") (eq .Platform.Architecture \"${arch}\")}}{{.Digest}}{{end}}{{end}}" 2>/dev/null)
  echo "$digest"
}

image_size_bytes() { # $1=arch，输出字节数；解析失败输出 -1
  local arch="$1" digest raw bytes=0
  digest=$(manifest_digest_of "${arch}")
  if [ -n "$digest" ]; then
    raw=$(docker buildx imagetools inspect "${IMAGE}@${digest}" --raw 2>/dev/null)
  else
    raw=$(docker buildx imagetools inspect "${IMAGE}:latest-linux-${arch}" --raw 2>/dev/null)
  fi
  # 只有真正的镜像清单才含 layers 字段；index 没有，求和结果不可信
  if echo "$raw" | grep -q '"layers"'; then
    bytes=$(echo "$raw" | grep -o '"size":[[:space:]]*[0-9]\+' | grep -o '[0-9]\+' \
      | awk '{s+=$1} END{print s+0}')
  fi
  # 一个正常 alpine 镜像不可能小于 1MB，低于该阈值说明取到的不是镜像清单
  if [ "${bytes:-0}" -lt 1048576 ]; then
    echo " ⚠️ ${arch} 体积解析失败，清单片段: $(echo "$raw" | head -c 200)" >&2
    echo "-1"
    return 0
  fi
  echo "$bytes"
}

human_mb() { awk -v b="${1:--1}" 'BEGIN{if(b<0) print "unknown"; else printf "%.1fMB", b/1048576}'; }

SIZE_AMD64=$(human_mb "$(image_size_bytes amd64)")
SIZE_ARM64=$(human_mb "$(image_size_bytes arm64)")
BUILT_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

mkdir -p .cnb
cat >.cnb/annotation.json <<EOF
{
  "image_digest": "${DIGEST:-unknown}",
  "image_digest_short": "${DIGEST_SHORT:-unknown}",
  "image_size": "${SIZE_AMD64}",
  "image_size_arm64": "${SIZE_ARM64}",
  "built_at": "${BUILT_AT}"
}
EOF

echo " digest: ${DIGEST:-unknown}"
echo " size:   amd64 ${SIZE_AMD64} / arm64 ${SIZE_ARM64}"
echo " 元数据: .cnb/annotation.json"

echo "=============================="
echo "🎉 处理结束 web_trigger_build_image"
echo "=============================="
