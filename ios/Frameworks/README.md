# ios/Frameworks

这个目录放 iOS 端链接用的 Rust 静态库，产物**不入库**（`ios/.gitignore` 忽略
`Frameworks/*.a` 和 `Frameworks/*.xcframework`），由脚本从 `rust/` 源码重建。

`ios/Flutter/{Debug,Release}.xcconfig` 里写死了：

```
OTHER_LDFLAGS = $(inherited) -force_load $(SRCROOT)/Frameworks/libfqapi_core.a ...
```

所以第一次 clone 下来直接 `flutter build ios` 会失败在链接阶段，报找不到
`libfqapi_core.a`（或 Rust 符号未定义）。先跑一次：

```bash
./scripts/build_rust_ios.sh              # 真机 arm64 → Frameworks/libfqapi_core.a
./scripts/build_rust_ios.sh --simulator  # 额外编模拟器片，产出 FqapiCore.xcframework
```

注意 `--simulator` 产出的 xcframework 与 `libfqapi_core.a` 二选一，当前 xcconfig
链接的是 `.a`，要在模拟器上跑需要改 xcconfig 里的链接路径。

改了 `rust/` 下的代码之后要重新跑一次脚本，否则 App 里跑的还是旧的静态库。
