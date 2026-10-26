# Triggr 汉化 + 扩展动作

Triggr 2.0.x 的简体中文汉化与扩展动作二合一包（rootless / 隐根越狱，arm64 + arm64e）。
本仓库是**构建仓**：只放源码、打包脚本和 CI 配置，不放成品二进制。

- 汉化：运行时 swizzle 显示层（UILabel / UIButton / UINavigationItem / UIAlertController 等），
  不修改 Triggr 本体，卸载即恢复英文。
- 扩展动作：通过 libtriggr 的公开注册接口，在动作选择器里新增「扩展动作」分类。

## 目录

```
src/TriggrChinese.m                  汉化注入库（TriggrChinese.dylib）
src/dict.h                           生成的词典（由 zh_complete / zh_overrides 合并而来）
src/iosmini/                         编译用最小 UIKit/Foundation 头文件（不依赖本机 SDK 头）
ext/Tweak.m                          扩展动作注册（SpringBoard，TriggrActions.dylib）
ext/Relay.m                          「返回上级」进程间接收端（UIKit 进程，TriggrBackRelay.dylib）
build/DEBIAN/                        control / postinst
build/var/jb/.../DynamicLibraries/   三个 filter plist
scripts/package.py                   切片 → 签名 → FAT → deb
.github/workflows/build.yml          云端构建（macos-14，真 Apple 工具链）
```

## 云端构建

推送到 `main` 即触发 Actions，产出 6 个 thin slice（3 个 tweak × arm64 / arm64e）：
`TriggrChinese-arm64.dylib`、`TriggrChinese-arm64e.dylib`、`TriggrActions-*`、`TriggrBackRelay-*`。

编译参数要点：

- 三份都用 `-fobjc-arc -O2 -dynamiclib -Wl,-undefined,dynamic_lookup`
- 必须带 `-fno-omit-frame-pointer`：汉化库靠 `__builtin_return_address(0)` + `dladdr()`
  判断调用方是不是 Triggr，没有帧指针就拿不到返回地址，横幅等界面就不会翻。
- 汉化库用 `-nostdinc -isystem src/iosmini` 走自带头文件，避免依赖 SDK 头。

## 打包

拿到 6 个切片后（本地或 CI 产物都行）：

```sh
python3 scripts/package.py --slices ci/out --out dist            # ldid 在 PATH 里
python3 scripts/package.py --slices ci/out --out dist --ldid ./bin/ldid
python3 scripts/package.py --slices ci/out --out dist --version 1.1
```

脚本做的事：

1. 每个 thin slice 单独 `ldid -S` 签名；
2. 两个切片拼 FAT（`0xcafebabe`，对齐 `0x4000`）；
3. 整包再签一次，然后把 FAT 第二项 cputype 改回 `0x0200000c`；
4. 写进 `build/` 目录树，用 `dpkg-deb` 打 deb；机器上没有 `dpkg-deb` 时用内置的
   ar + tar.gz 实现，产物同样能被 Sileo / Zebra / dpkg 识别。

> **为什么要手动改 cputype**：ldid 给 FAT 签名时会把第二个架构的 cputype 归一成
> `0x0100000c`（arm64），arm64e 设备会按 arm64 加载甚至直接不加载。所以签名之后
> 必须把 header 偏移 28–31 写回 `0x0200000c`。这一步漏了就会「装了没反应」。

## 安装

```sh
dpkg -i com.777qwq.triggrzh_<版本>_iphoneos-arm64.deb
# 或直接丢进 Sileo / Zebra 安装
```

装完注销（respring）一次生效。扩展动作需要 Triggr 2.0.x，1.5.x 请勿安装。

## 已知坑

- clang 会把**代码里**含非 ASCII 的 `@"..."` 字面量编码成 UTF-16（`__TEXT,__ustring`），
  而词典里的字面量走 UTF-8。用 `strings | grep 中文` 校验二进制时会误判「中文丢了」，
  要同时搜 UTF-8 和 UTF-16LE 两种编码。
- 扩展源的 `Relay.m` 用到 `objc_msgSend` / `class_getMethodImplementation`，
  必须 `#import <objc/message.h>` 和 `<objc/runtime.h>`，否则在新 Xcode 上编不过。
