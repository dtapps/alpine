#!/bin/sh
# 构建并推送 ARM64 Docker 镜像
# 用于 CNB 流水线，必须通过 `source` 执行以支持 set-output

echo "原始 version: $version"
echo "CNB_DOCKER_REGISTRY: ${CNB_DOCKER_REGISTRY}"
echo "CNB_REPO_SLUG_LOWERCASE: ${CNB_REPO_SLUG_LOWERCASE}"

# 清理
version=$(echo "$version" | tr -d '[:space:]' | tr -d '\n\r')
version=$(echo "$version" | sed 's/[^[:print:]]//g')

# 空 version 自动转为 "latest"
[ -z "$version" ] && version="latest"

echo "处理 version: $version"

# 输出变量供后续 stage 使用（必须 source 执行才生效）
echo "##[set-output interior_version=$version]"

# 导出环境变量（供本 stage 后续命令使用）
export INTERIOR_VERSION="$version"

# ========== 构建并推送 ==========
echo "=============================="
echo "🔧 开始处理 web_trigger_build_docker_arm64_image"
echo "=============================="

# 登录 Docker Registry
echo " 登录 Docker Registry: ${CNB_DOCKER_REGISTRY}"
docker login -u "${CNB_TOKEN_USER_NAME}" -p "${CNB_TOKEN}" "${CNB_DOCKER_REGISTRY}"

IMAGE_ARCH="linux-arm64"
IMAGE_NAME="${CNB_REPO_SLUG_LOWERCASE}"
DOCKER_IMAGE_LATEST="${CNB_DOCKER_REGISTRY}/${IMAGE_NAME}:latest-${IMAGE_ARCH}"
DOCKER_IMAGE_VERSION=""

if [ "$INTERIOR_VERSION" != "latest" ]; then
  DOCKER_IMAGE_VERSION="${CNB_DOCKER_REGISTRY}/${IMAGE_NAME}:${INTERIOR_VERSION}-${IMAGE_ARCH}"
fi

# 构建
BUILD_ARGS="--build-arg ALPINE_VERSION=${INTERIOR_VERSION}"

if [ -z "$DOCKER_IMAGE_VERSION" ]; then
  echo " 构建 Docker 镜像: ${DOCKER_IMAGE_LATEST}"
  docker build -f "./Dockerfile" -t "${DOCKER_IMAGE_LATEST}" ${BUILD_ARGS} .
else
  echo " 构建 Docker 镜像: ${DOCKER_IMAGE_LATEST} ${DOCKER_IMAGE_VERSION}"
  docker build -f "./Dockerfile" -t "${DOCKER_IMAGE_LATEST}" -t "${DOCKER_IMAGE_VERSION}" ${BUILD_ARGS} .
fi

# 推送
if [ -z "$DOCKER_IMAGE_VERSION" ]; then
  echo " 推送 Docker 镜像: ${DOCKER_IMAGE_LATEST}"
  docker push "${DOCKER_IMAGE_LATEST}"
else
  echo " 推送 Docker 镜像: ${DOCKER_IMAGE_LATEST} ${DOCKER_IMAGE_VERSION}"
  docker push "${DOCKER_IMAGE_LATEST}"
  docker push "${DOCKER_IMAGE_VERSION}"
fi

echo "=============================="
echo "🎉 处理结束 web_trigger_build_docker_arm64_image"
echo "=============================="