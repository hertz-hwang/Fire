## Git (hard rule)

**所有代码更改都会被提交。** 没有例外，不会将多个不相关的更改合并到一个提交中，也不会在任务结束时留下脏的工作树。

1. 做出一个合乎逻辑的改动。
2. 使用 `git status` 命令检查是否只列出了你的文件。
3. `git add <explicit paths>`，永远不要使用 `git add -A`，永远不要使用 `git add .`，永远不要使用 `git commit -a`。
4. `git commit` 保持中文提交信息。
