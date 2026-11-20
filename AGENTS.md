# 项目开发与推送约定

1. **版本号递增**：每次推送代码前，必须将 `Resources/Info.plist` 中的小版本号 `CFBundleShortVersionString` 末位 `+1`（例如 `0.1.23` → `0.1.24`），并同步将 `CFBundleVersion` `+1`。
2. **测试与构建**：提交推送前确保运行 `make test` 与 `make app` 验证通过。
3. **双推同步**：完成修改、测试与构建后，直接提交并执行 `git push origin master` 双推至 Gitee 与 GitHub。
