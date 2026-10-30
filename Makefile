

# 格式化
format: format-yaml format-markdown format-shell format-docker

# 格式化 YAML 文件
.PHONY: format-yaml
format-yaml:
	@echo "[Format] 格式化配置文件 (YAML)…"
	@yamlfmt -conf .yamlfmt \
		".cnb" \
		".cnb.yml" || { echo "❌ yamlfmt 格式化失败"; exit 1; }
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
.PHONY: format-shell
format-shell:
	@echo "[Format] 格式化脚本 (Shell)…"
	@shfmt -w -i 2 -ci -bn -s -ln posix .cnb/scripts/ || { echo "❌ shfmt 格式化失败"; exit 1; }
	@echo "[Format] Shell 格式化完成（shfmt）。"

# 静态检查：shellcheck 按 POSIX sh 方言检查 CI 脚本
.PHONY: lint-shell
lint-shell:
	@echo "[Lint] 检查脚本 (ShellCheck)…"
	@shellcheck -s sh -S warning .cnb/scripts/*.sh || { echo "❌ shellcheck 未通过"; exit 1; }
	@echo "[Lint] ShellCheck 通过。"

# 格式化 Dockerfile 文件
# -n：文件以换行结尾（dockerfmt 默认不补，会被多数编辑器/git 视为「末尾缺换行」）
.PHONY: format-docker
format-docker:
	@echo "[Format] 格式化 Dockerfile..."
	@find .cnb -type f -name "Dockerfile*" -exec dockerfmt -w -n {} + || { echo "❌ dockerfmt 格式化失败"; exit 1; }
	@echo "[Format] Dockerfile 格式化完成（dockerfmt）。"
