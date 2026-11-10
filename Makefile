
# 环境变量优先级高于 .env：include 的赋值会覆盖环境值，先暂存一份
ifeq ($(origin GIT_REMOTE),environment)
    GIT_REMOTE_ENV := $(GIT_REMOTE)
endif

# 加载 .env 文件（如果存在）
ifneq (,$(wildcard ./.env))
    include .env
    export
endif

ifneq ($(GIT_REMOTE_ENV),)
    GIT_REMOTE := $(GIT_REMOTE_ENV)
endif

# 同步/推送目标远程，逗号分隔：GIT_REMOTE=origin,github,gitlab
# 可通过 .env / 环境变量 / 命令行覆盖，未配置时默认 origin。
GIT_REMOTE ?= origin
export GIT_REMOTE

# 格式化
format: format-yaml format-markdown format-shell format-docker

# 格式化 YAML 文件
.PHONY: format-yaml
format-yaml:
	@echo "[Format] 格式化配置文件 (YAML)…"
	@yamlfmt -conf .yamlfmt \
		".cnb" \
		".cnb.yml" \
		".github" \
		".gitlab" \
		".gitlab-ci.yml" || { echo "❌ yamlfmt 格式化失败"; exit 1; }
	@echo "[Format] YAML 格式化完成（yamlfmt）。"

# 格式化 Markdown 文件
.PHONY: format-markdown
format-markdown:
	@echo "[Format] 格式化文档 (Markdown)…"
	@for f in $(shell find . -type f -name '*.md' \
		-not -path './.git/*' \
		-not -path './.vscode/*' \
		-not -path './.idea/*' \
		-not -path './.codebuddy/*' \
		-not -path './.trae/*' \
		-not -path './.mimocode/*'); do \
		[ -f "$$f" ] || continue; \
		markdownfmt -w "$$f" || { echo "❌ markdownfmt 格式化失败: $$f"; exit 1; }; \
	done
	@echo "[Format] Markdown 格式化完成（markdownfmt）。"

# 格式化 Shell 脚本
# 脚本是 #!/bin/sh（POSIX），shfmt 的方言必须跟着改，否则 -ln bash 会把 POSIX
# 写法当成 bash 合法化，本地通过、CNB 的 dash 上炸。
# .cnb/scripts、.github/scripts、.gitlab/scripts 是三份副本（CNB / GitHub / GitLab
# 各一份），一并格式化。
.PHONY: format-shell
format-shell:
	@echo "[Format] 格式化脚本 (Shell)…"
	@shfmt -w -i 2 -ci -bn -s -ln posix .cnb/scripts/ .github/scripts/ .gitlab/scripts/ || { echo "❌ shfmt 格式化失败"; exit 1; }
	@echo "[Format] Shell 格式化完成（shfmt）。"

# 静态检查：shellcheck 按 POSIX sh 方言检查 CI 脚本
.PHONY: lint-shell
lint-shell:
	@echo "[Lint] 检查脚本 (ShellCheck)…"
	@shellcheck -s sh -S warning .cnb/scripts/*.sh .github/scripts/*.sh .gitlab/scripts/*.sh || { echo "❌ shellcheck 未通过"; exit 1; }
	@echo "[Lint] ShellCheck 通过。"

# 格式化 Dockerfile 文件
# -n：文件以换行结尾（dockerfmt 默认不补，会被多数编辑器/git 视为「末尾缺换行」）
.PHONY: format-docker
format-docker:
	@echo "[Format] 格式化 Dockerfile..."
	@find .cnb .github .gitlab -type f -name "Dockerfile*" -exec dockerfmt -w -n {} + || { echo "❌ dockerfmt 格式化失败"; exit 1; }
	@echo "[Format] Dockerfile 格式化完成（dockerfmt）。"

# 按 GIT_REMOTE 顺序先全部拉取合并，再统一推送（保留本地未提交改动）
.PHONY: sync
sync:
	@IFS=,; for r in $$GIT_REMOTE; do \
		git fetch "$$r" && git merge --ff-only "$$r/main" || exit 1; \
	done
	@IFS=,; for r in $$GIT_REMOTE; do git push "$$r" HEAD || exit 1; done
	@echo "同步完成！"

# 推送到所有远程仓库
.PHONY: push
push:
	@IFS=,; for r in $$GIT_REMOTE; do git push "$$r" HEAD || exit 1; done
	@echo "推送完成！"

# 强制推送到所有远程仓库（忽略冲突）
.PHONY: push-force
push-force:
	@IFS=,; for r in $$GIT_REMOTE; do git push --force "$$r" HEAD || exit 1; done
	@echo "强制推送完成！"
