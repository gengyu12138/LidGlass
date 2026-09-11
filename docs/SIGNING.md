# 签名与 Apple 公证

v0.1.1 是 **ad-hoc 签名、未公证** 的预览版。`codesign --verify` 通过只表示签名结构完整，不代表 Apple 验证了开发者身份，也不代表 Gatekeeper 会允许首次启动。

## 正式分发需要什么

- Apple Developer Program 会员资格及创建证书所需的账号角色。
- 安装在签名机器钥匙串中的 **Developer ID Application** 证书及其匹配私钥。只有 `.cer` 公钥证书不够。
- Apple 公证服务的凭据，可使用 `notarytool` 的钥匙串配置保存。不要把私钥、证书密码或 Apple 账号凭据写入源码、Issue 或发布附件。

Apple Development、本地自签证书和 ad-hoc 签名不能替代 Developer ID 对外分发签名。为拖拽安装的 `.app`/DMG 分发不需要额外的 Developer ID Installer 证书；该证书针对 `.pkg` 安装器。

## 有证书之后

查看可用身份：

```sh
security find-identity -v -p codesigning
```

使用你的真实证书名称构建。构建脚本会启用 Hardened Runtime 与安全时间戳：

```sh
SIGNING_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)' zsh build.sh
zsh package.sh
```

上面的证书名称是占位符；必须替换。签名分支因当前维护环境没有证书，尚未实测。打包命令仍保留 `preview` 文件名，不会把签名成功误报为公证成功。

通过 `xcrun notarytool store-credentials` 的交互提示将自己的公证凭据保存为 `LidGlass-notary` 配置，然后提交 ZIP：

```sh
xcrun notarytool submit dist/LidGlass-0.1.1-arm64-preview.zip \
  --keychain-profile LidGlass-notary --wait
```

只有返回状态为 `Accepted` 才继续；失败时应读取对应 submission 的公证日志并处理原因。接受后：

```sh
xcrun stapler staple build/LidGlass.app
xcrun stapler validate build/LidGlass.app
spctl --assess --type execute --verbose=2 build/LidGlass.app
zsh package.sh
```

重新打包使 ZIP/DMG 包含已附加公证票据的应用。DMG 还应使用同一个 Developer ID Application 身份签名、向公证服务提交并检查 `Accepted`，随后对 DMG 执行 `stapler staple` 和 `stapler validate`。最终再计算 SHA-256；附加票据后文件内容和校验值会改变。版本号变化时也应同步替换以上文件名。

签名、公证和安装后的录屏授权是三个不同步骤。稳定的 Developer ID 身份有利于应用身份连续性，但不替用户授予隐私权限，也不能保证现有本地签名版本的权限自动迁移。

## 官方参考

- [Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates)
- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Distribute outside the Mac App Store](https://help.apple.com/xcode/mac/current/en.lproj/dev033e997ca.html)
