# z8g4-max

HP Z8 G4 双路工作站 `jackywang-xubuntu-max` 的装机计划和部署文件。硬件包括双 Xeon 8269CY、DDR4、Optane PMem 100、四张 V100 16 GiB、P4618、P4800X 和七块 HC620。系统使用 Xubuntu 26.04.1，登录用户为 `jackywang`。

- [装机计划 v2.16](Z8-G4-workstation-plan.md)涵盖 BIOS、验机、系统安装、存储、Buck2/Buildbarn 和 DeepSeek 推理。
- [部署文件](z8-kit/README.md)包括逐步命令、配置样例和 systemd 单元。

设备路径和节点编号以实机为准。PMem 分层、四卡推理和混合负载的结果待实机验证。
