# disk-idle

Linux 下的 USB 硬盘盒休眠延长脚本：监控各磁盘的真实读写量，使用期内保活，闲置满设定时间后停止保活，由硬盘盒固件自动休眠。

适用场景：硬盘盒固件休眠太激进（如 Orico 闲置 30 秒就停转），想改成"闲置 1 小时才休眠"。

## 工作方式

- 每个周期（默认 20 秒）重新扫描磁盘，硬盘盒插拔、重新识别成别的 sdX 都能自动跟上；按 `/dev/disk/by-id` 识别磁盘。
- **真实读写量**取分区统计 `/sys/block/sdX/sdX*/stat`（内核内存计数，读取不会唤醒硬盘）。
- **保活**：使用期内每个周期直读整盘设备第 0 扇区 4KB（`O_DIRECT`，只读不写），阻止硬盘盒固件提前休眠。整盘设备的读取不计入分区统计，因此保活不会被当成"有人在用"。
- 连续闲置满 `IDLE_TIMEOUT` 后停止保活，硬盘盒固件随后自动让硬盘停转（脚本不发休眠命令）；之后有超过阈值的真实读写即恢复保活并重新计时。
- 多块盘各自独立计时。

## 配置（disk-idle.conf）

| 项 | 默认 | 说明 |
|---|---|---|
| `CHECK_INTERVAL` | 20 | 检测/保活周期（秒），必须小于硬盘盒固件的休眠时间 |
| `IDLE_TIMEOUT` | 3600 | 闲置多久后停止保活（秒），之后由硬盘盒自动休眠 |
| `MIN_ACTIVITY_KB` | 1024 | 一个周期内真实读写低于此值视为闲置 |
| `DISKS` | auto | `auto` = 所有 USB 机械盘（rotational=1）；或 by-id 名字列表，支持通配符 |
| `EXCLUDE` | 空 | 排除的盘（by-id 名字，支持通配符） |
| `DRY_RUN` | 0 | 1 = 不做保活读取，只输出每周期读写量 |

## 安装

脚本默认放在 `/home/orangepi/disk-idle/`，路径不同请修改 `disk-idle.service`。

```bash
sudo cp disk-idle.service /etc/systemd/system/
sudo systemctl enable --now disk-idle
journalctl -u disk-idle -f
```

修改配置后 `sudo systemctl restart disk-idle` 生效。

依赖：`bash`、`dd`（coreutils）。需要 root 运行（读整盘设备）。
