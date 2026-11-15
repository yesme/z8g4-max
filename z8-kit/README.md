# Z8 G4 配套部署文件

机旁操作从 [上机操作顺序](host/FIRST-BOOT.md) 开始。目标主机是 `jackywang-xubuntu-max`，登录用户 `jackywang`。以下命令在目标 Linux 上运行，配置中的设备名按实机填写。每次保存 kernel、驱动、引擎 Git SHA、模型 revision 和运行参数。

| 目录 | 用途 |
|---|---|
| host | AX210 首次 Live 联网、F10 与固件、Memtest86+、PMem 专用拷机、App Direct、UPI 和 CPU 分核 |
| inference | llama.cpp 首装、Xolotl 回退、1Cat 专项、SSE/并发/工具探针 |
| harness | 按项目启动独立 tmux，OMP/Pi/DSH 直连 DeepSeek，本地 OMP 验机样例 |
| buildbarn | Z8 的 RAIDZ1 冷库和调度器、mini 与 Mac 的边缘缓存、Linux/Darwin worker、Buck2 延迟物化和 XFS reflink |
| storage | P4800X 九分区、七个 dm-zoned 映射、RAIDZ1 与 p9 冷索引依赖 |
| remote | SSH tunnel、xrdp、Sunshine |
| market-quote.csv | 当日采购报价登记 |

## 上机路径

1. **测试（含 BIOS）**。按 [F10 配置](host/BIOS.md) 和 [拷机手册 T1–T5](host/BURN-IN.md)，依次验 CPU、DDR4、PMem、裸盘、算力坞。T4 七块 HC620 并行慢扫。主机硬件全通过后才接坞；T5 完成后关机并断开 V100。
2. **正式安装**。按 [系统盘手册](host/INSTALL.md) 安装 Xubuntu 26.04.1 和 RAID0/XFS 根，配 [SSH 与 xrdp](remote/README.md)，装 NVIDIA 显卡驱动、验 P620 后再接回 V100。接回数据盘后按 [存储手册](storage/README.md) 建 dm-zoned 和 RAIDZ1、装强制依赖、验 scrub 和缺盘。I5 按每路 6 核[安装 CPU 分核和 runner 配置](host/CPU-PLACEMENT.md#生成并安装)，再启用 Buildbarn worker。I6 按 [推理手册](inference/README.md) 验收引擎、配置 CLI 和推理服务，I7 跑一次整机混合负载。

`*.example` 是需要合并或改路径的样例。先在空盘、独立测试目录和本机监听口完成验收。脚本中的权限边界依赖目标机的 Unix 用户、SSH 和具体 CLI 许可。
