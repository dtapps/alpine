#!/bin/sh
# 合并多架构 Docker 镜像清单（manifest）
# 用于 CNB 流水线，支持 amd64 Runner 执行

echo "=============================="
echo "🔧 开始处理 web_trigger_merge_manifest_docker"
echo "=============================="

# 登录 Docker Registry
echo " 登录 Docker Registry: ${CNB_DOCKER_REGISTRY}"
docker login -u "${CNB_TOKEN_USER_NAME}" -p "${CNB_TOKEN}" "${CNB_DOCKER_REGISTRY}"
IMAGE_NAME="${CNB_REPO_SLUG_LOWERCASE}"

# 定义最终的统一标签和架构特定标签
FINAL_TAG="${CNB_DOCKER_REGISTRY}/${IMAGE_NAME}:latest"

# 要合并 latest 标签
AMD64_TAG="${CNB_DOCKER_REGISTRY}/${IMAGE_NAME}:latest-linux-amd64"
ARM64_TAG="${CNB_DOCKER_REGISTRY}/${IMAGE_NAME}:latest-linux-arm64"

# 创建 Manifest List
echo " 创建 Manifest List: ${FINAL_TAG} 指向 ${AMD64_TAG} 和 ${ARM64_TAG}"
docker manifest create "${FINAL_TAG}" "${AMD64_TAG}" "${ARM64_TAG}"

# 推送 Manifest List
echo " 推送 Manifest List: ${FINAL_TAG}"
docker manifest push "${FINAL_TAG}"

echo "=============================="
echo "🎉 处理结束 web_trigger_merge_manifest_docker"
echo "=============================="