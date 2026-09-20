# 业火五笔输入法
![业火五笔输入法](https://github.com/qwertyyb/Fire/blob/ee8546aad395e4e6b3b1b756cfbd4f908c5dfe89/Fire/Assets.xcassets/AppIcon.appiconset/icon-256.png)

[![FOSSA Status](https://app.fossa.com/api/projects/git%2Bgithub.com%2Fqwertyyb%2FFire.svg?type=shield)](https://app.fossa.com/projects/git%2Bgithub.com%2Fqwertyyb%2FFire?ref=badge_shield)
![GitHub Release](https://img.shields.io/github/v/release/qwertyyb/Fire)
![GitHub License](https://img.shields.io/github/license/qwertyyb/Fire)
![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/qwertyyb/Fire/build.yml)
![GitHub Downloads (specific asset, all releases)](https://shields.io/github/downloads/qwertyyb/Fire/FireInstaller.pkg?displayAssetName=false)
![GitHub Repo stars](https://img.shields.io/github/stars/qwertyyb/Fire)


## 💰 打赏支持
如果本项目对你有帮助，欢迎请作者喝杯咖啡，你的支持是持续更新的动力~

| 微信 | 支付宝 |
| ---- | ---- |
| <img alt="微信赞赏码" src="./assets/wechat.jpg" width="240"> | <img alt="支付宝收款码" src="./assets/alipay.jpg" width="240"> |

## 介绍

轻量干净，但功能强大的五笔输入法

## 截图

<img width="529" alt="image" src="https://user-images.githubusercontent.com/9018466/181672239-826e2f48-ce58-434a-9e05-6c58fcb8a5c8.png">

<img width="549" alt="image" src="https://user-images.githubusercontent.com/9018466/181672303-345e30f9-dfa6-4562-828f-6e5e8d87166a.png">

<img width="545" alt="image" src="https://user-images.githubusercontent.com/9018466/181672403-f5372465-ccc5-4b7b-befb-47c913278d8b.png">

<img width="557" alt="image" src="https://user-images.githubusercontent.com/9018466/181672445-0b8c2e1f-2105-4629-8b62-fe46001ebcec.png">

<img width="556" alt="image" src="https://user-images.githubusercontent.com/9018466/181672510-8827fead-7a39-450a-bf62-4a129c9dc82d.png">

<img width="540" alt="image" src="https://user-images.githubusercontent.com/9018466/181672573-9645e5fc-0092-4ff6-8b88-cd8e77d78453.png">

<img width="540" alt="image" src="https://user-images.githubusercontent.com/9018466/181672627-4ab5b3c4-6d22-4bdc-93e5-a80570c24ef1.png">



## 功能
1. 五笔输入(支持86版/98版/自定义编码方案)
2. 五笔拼音混输，支持编码提示
3. 纯拼音输入：整句组词（字级 n-gram），支持简拼、模糊音、敲错纠正
   - 候选栏前五固定显示整句引擎「单字重码组句」打分的 top5（词 + 每个音节的同码重码单字一起进词图按分数裁决）
   - 双拼可切换全拼 / 小鹤 / 自然码，并支持在键盘图上拖拽声母、韵母自定义键位
   - 词库是 `.hdict` 私有容器（47.5 万条带词频，拼音与双拼共用），见[拼音词库](#拼音词库hdict)
3. -/+/向上/向下键支持翻页
4. z键查询
5. 候选词横向/竖向排列支持
6. 候选词数量可配置
7. 候选窗口显示输入编码
8. 应用输入模式切换
9. 支持手动调整候选词顺序(`control` + `数字`)
10. 支持用户词库
11. 支持自定义符号
12. 支持自定义主题
13. 支持数据统计
14. 支持临时英文模式(在中文输入模式下，按;键可以开启临时英文模式，输入英文字符和半角符号)
15. 快速组词(连续输入多个单字或词后，按`control` + `=`可将最近的输入自动组合成新词)
16. 快速删除候选词(`control` + `shift` + `数字`将对应候选词从词库删除)
17. 撤消上屏(`control` + `u`撤消前一次上屏的文字，可连续多次撤消，快捷键可在设置中修改)
18. 清空编码串(`control` + `l`直接丢弃当前未上屏的编码，无编码时不影响应用内复制，快捷键可在设置中修改)
19. 命令行

## 拼音词库（`.hdict`）

拼音与双拼共用一份词库：`Fire/Resources/schemas/py.hdict`。它是 Fire 的私有容器
（定长头 + raw deflate 压缩块），负载仍是统一码表行流 `候选\t连写全拼[\t词频]`；
双拼不另立词库 —— 引擎先把双拼键解成音节，查的还是同一份音节索引。

词库由收集的 rime 字词库（base / ext / 《通用规范汉字表》8105）合并注音生成，
按词频降序写盘（文件序就是 Fire 的 rank，同码重码的常用次序就靠它）。
容器格式、生成脚本与档位选择见 [docs/hdict.md](./docs/hdict.md)。

同一份 2742 句冻结句子集，换词库前后的首选命中率（冷启动不学习）：

| 敲法 | 旧词库（8.2 万条，无词频） | `py.hdict`（47.5 万条，带词频） |
|------|---------------------------|--------------------------------|
| 标准全拼 | 42.9% | **48.6%** |
| 小鹤 / 自然码双拼 | 43.5% | **49.4%** |
| 三成音节只敲声母（简拼） | 17.0% | **20.7%** |
| 每句约一处相邻敲反 | 29.3% | **33.2%** |
| 平翘舌混敲（开模糊音） | 34.5% | **41.4%** |

想换成自己整理的表：「偏好设置 → 词库 → 拼音词库」，`.hdict` 与明文
`候选\t连写全拼[\t词频]` 的 txt 都能直接指。

## 命令行使用

```bash
# 输出当前输入模式
/Library/Input\ Methods/Fire.app/Contents/MacOS/Fire --get-mode

# 设置输入模式并显示提示
/Library/Input\ Methods/Fire.app/Contents/MacOS/Fire --set-mode enUS 或 zhhans

# 设置输入模式不显示提示
/Library/Input\ Methods/Fire.app/Contents/MacOS/Fire --set-mode enUS 或 zhhans false
```

## 安装
> [下载地址](https://github.com/qwertyyb/Fire/releases)

1. 下载 `FireInstall.pkg` 文件到本地

2. 点击安装后使用


## 安装遇到问题
1. 没有自动切换到该输入法。
    > 可以在设置->键盘->输入法中添加此输入法

2. 输入法中没有此输入法。
    > 重启设备即可


## 开发
```bash
# 下载项目到本地
git clone --recursive https://github.com/qwertyyb/Fire.git

# 构建 sqlcipher
./scripts/0_prepare_sqlcipher.sh

# 使用Xcode打开项目启动开发
open Fire.xcodeproj

# 由于调试时，APP运行目录在/Library/Input Methods, 所以需要添加权限
sudo chmod -R 777 /Library/Input Methods
```


## License
[![FOSSA Status](https://app.fossa.com/api/projects/git%2Bgithub.com%2Fqwertyyb%2FFire.svg?type=large)](https://app.fossa.com/projects/git%2Bgithub.com%2Fqwertyyb%2FFire?ref=badge_large)
