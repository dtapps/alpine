

# 格式化
format: format-yaml format-markdown format-shell format-docker

# 格式化 YAML 文件
.PHONY: format-yaml
format-yaml:
	@echo "[Format] 格式化配置文件 (YAML)…"
	@yamlfmt -conf .yamlfmt \
		".cnb" \
		".cnb.yml" \
		".github" || { echo "❌ yamlfmt 格式化失败"; exit 1; }
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
# .cnb/scripts 与 .github/scripts 是两份副本（CNB / GitHub 各一份），一并格式化。
.PHONY: format-shell
format-shell:
	@echo "[Format] 格式化脚本 (Shell)…"
	@shfmt -w -i 2 -ci -bn -s -ln posix .cnb/scripts/ .github/scripts/ || { echo "❌ shfmt 格式化失败"; exit 1; }
	@echo "[Format] Shell 格式化完成（shfmt）。"

# 静态检查：shellcheck 按 POSIX sh 方言检查 CI 脚本
.PHONY: lint-shell
lint-shell:
	@echo "[Lint] 检查脚本 (ShellCheck)…"
	@shellcheck -s sh -S warning .cnb/scripts/*.sh .github/scripts/*.sh || { echo "❌ shellcheck 未通过"; exit 1; }
	@echo "[Lint] ShellCheck 通过。"

# 格式化 Dockerfile 文件
# -n：文件以换行结尾（dockerfmt 默认不补，会被多数编辑器/git 视为「末尾缺换行」）
.PHONY: format-docker
format-docker:
	@echo "[Format] 格式化 Dockerfile..."
	@find .cnb .github -type f -name "Dockerfile*" -exec dockerfmt -w -n {} + || { echo "❌ dockerfmt 格式化失败"; exit 1; }
	@echo "[Format] Dockerfile 格式化完成（dockerfmt）。"

# 拉取所有远程最新（先 CNB，后 GitHub 镜像）然后强制推送
sync: sync-cnb sync-github push-force

# 拉取 CNB 最新并以 fast-forward 合并（保留本地未提交改动）
sync-cnb:
	git fetch origin
	git merge --ff-only origin/main
	@echo "已同步 origin/main 最新代码，本地未提交改动已保留"

# 拉取 GitHub 最新并以 fast-forward 合并（保留本地未提交改动）
sync-github:
	git fetch github
	git merge --ff-only github/main
	@echo "已同步 github/main 最新代码，本地未提交改动已保留"

# 推送到所有远程仓库
push: 
	git push origin HEAD
	git push github HEAD
	@echo "推送完成！"

# 强制推送到所有远程仓库（忽略冲突）
push-force:
	git push --force origin HEAD
	git push --force github HEAD
	@echo "强制推送完成！"
