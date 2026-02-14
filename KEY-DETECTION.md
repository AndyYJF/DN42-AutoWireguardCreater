# WireGuard密钥自动检测功能

脚本现在支持自动检测和使用本地已有的WireGuard密钥，避免重复生成密钥。

## 功能说明

### 自动检测位置

脚本会在以下位置查找已有的WireGuard密钥：

1. **独立密钥文件**
   - `/etc/wireguard/*.key`
   - `/etc/wireguard/privatekey`
   - `/etc/wireguard/private.key`

2. **配置文件中的密钥**
   - `/etc/wireguard/*.conf` 中的 `PrivateKey` 字段

### 使用流程

当你运行脚本时，如果检测到已有密钥：

```bash
sudo ./dn42-ospf-wg.sh
```

脚本会显示：

```
[INFO] 检测到 2 个已有的WireGuard密钥

是否使用已有密钥? [Y/n]: y

[INFO] 检测到以下WireGuard密钥:

[1] 来源: /etc/wireguard/wg0.conf
    公钥: AbCdEfGhIjKlMnOpQrStUvWxYz1234567890+/=

[2] 来源: /etc/wireguard/private.key
    公钥: XyZaBcDeFgHiJkLmNoPqRsTuVwXyZ1234567890=

请选择密钥编号 (1-2) 或输入 0 生成新密钥:
```

### 选项说明

- **选择 1-N**：使用对应编号的已有密钥
- **选择 0**：生成新的密钥对
- **输入 n**（在第一个提示时）：跳过已有密钥，直接生成新密钥

## 使用场景

### 场景1：重新配置隧道

如果你需要重新配置一个已有的隧道：

```bash
# 之前的配置
sudo wg-quick down wg0

# 运行脚本重新配置
sudo ./dn42-ospf-wg.sh

# 选择使用已有密钥，避免需要更新对端配置
```

### 场景2：添加新隧道使用相同密钥

在某些情况下，你可能想让多个隧道使用相同的密钥：

```bash
# 配置第二个隧道
sudo ./dn42-ospf-wg.sh

# 选择使用第一个隧道的密钥
```

### 场景3：迁移配置

从手动配置迁移到使用脚本：

```bash
# 你已经有手动创建的 /etc/wireguard/wg0.conf
# 现在想用脚本创建新隧道

sudo ./dn42-ospf-wg.sh

# 脚本会检测到 wg0.conf 中的密钥
# 你可以选择复用或生成新密钥
```

## 密钥验证

脚本会验证检测到的密钥是否有效：

1. **长度检查**：必须是44个字符
2. **格式检查**：必须是有效的Base64格式
3. **WireGuard验证**：能够成功生成对应的公钥

只有通过所有验证的密钥才会显示在列表中。

## 安全考虑

### 密钥文件权限

脚本会检查 `/etc/wireguard/` 目录，该目录通常需要root权限访问：

```bash
# 推荐的密钥文件权限
chmod 600 /etc/wireguard/*.key
chmod 600 /etc/wireguard/*.conf
```

### 临时文件

脚本使用临时文件 `/tmp/wg_detected_keys.tmp` 存储检测到的密钥信息：

- 文件在使用后会自动删除
- 仅包含公钥和文件路径，不包含私钥明文
- 仅在脚本运行期间存在

### 密钥复用注意事项

**建议**：每个隧道使用独立的密钥对

**可以复用的情况**：
- 重新配置同一个隧道
- 测试环境
- 临时配置

**不建议复用的情况**：
- 生产环境的不同隧道
- 连接到不同对端的隧道
- 需要独立管理的隧道

## 手动管理密钥

### 生成独立密钥文件

```bash
# 生成私钥
wg genkey > /etc/wireguard/node1.key
chmod 600 /etc/wireguard/node1.key

# 生成公钥
wg pubkey < /etc/wireguard/node1.key > /etc/wireguard/node1.pub

# 查看公钥
cat /etc/wireguard/node1.pub
```

### 从配置文件提取密钥

```bash
# 提取私钥
grep "^PrivateKey" /etc/wireguard/wg0.conf | awk '{print $3}'

# 生成对应的公钥
grep "^PrivateKey" /etc/wireguard/wg0.conf | awk '{print $3}' | wg pubkey
```

### 备份密钥

```bash
# 备份所有WireGuard配置和密钥
sudo tar -czf wireguard-backup-$(date +%Y%m%d).tar.gz /etc/wireguard/

# 恢复备份
sudo tar -xzf wireguard-backup-20260214.tar.gz -C /
```

## 故障排查

### 问题1：未检测到已有密钥

**可能原因**：
- 密钥文件不在标准位置
- 文件权限问题
- 密钥格式不正确

**解决方法**：
```bash
# 检查密钥文件位置
sudo find /etc/wireguard -type f -name "*.key" -o -name "*.conf"

# 检查文件权限
sudo ls -la /etc/wireguard/

# 验证密钥格式
cat /path/to/private.key | wg pubkey
```

### 问题2：密钥验证失败

**可能原因**：
- 密钥文件损坏
- 包含额外的空格或换行符

**解决方法**：
```bash
# 清理密钥文件（移除空格和换行）
sudo sed -i 's/[[:space:]]//g' /etc/wireguard/private.key

# 重新生成密钥
wg genkey | sudo tee /etc/wireguard/private.key
```

### 问题3：选择密钥后配置失败

**可能原因**：
- 私钥文件权限不足
- 密钥已被其他接口使用

**解决方法**：
```bash
# 检查哪些接口在使用密钥
sudo wg show all

# 停止冲突的接口
sudo wg-quick down wg0
```

## 最佳实践

1. **密钥命名规范**
   ```bash
   /etc/wireguard/
   ├── node1.key          # 节点1私钥
   ├── node1.pub          # 节点1公钥
   ├── dn42-hk.conf       # HK节点配置
   └── dn42-us.conf       # US节点配置
   ```

2. **定期轮换密钥**
   ```bash
   # 每6个月轮换一次密钥
   # 1. 生成新密钥
   # 2. 更新对端配置
   # 3. 重启隧道
   # 4. 删除旧密钥
   ```

3. **密钥备份策略**
   ```bash
   # 加密备份
   sudo tar -czf - /etc/wireguard/ | \
       gpg --symmetric --cipher-algo AES256 > \
       wireguard-backup-$(date +%Y%m%d).tar.gz.gpg
   ```

4. **文档记录**
   ```bash
   # 记录每个密钥的用途
   # /etc/wireguard/README.txt
   node1.key - 用于dn42-hk隧道，连接到HK节点
   node2.key - 用于dn42-us隧道，连接到US节点
   ```

## 示例：完整工作流程

### 首次配置

```bash
# 1. 运行脚本
sudo ./dn42-ospf-wg.sh

# 2. 没有检测到已有密钥，自动生成新密钥
[INFO] 生成新密钥...
[INFO] 本节点公钥: AbCdEf...

# 3. 完成配置
```

### 重新配置

```bash
# 1. 运行脚本
sudo ./dn42-ospf-wg.sh

# 2. 检测到已有密钥
[INFO] 检测到 1 个已有的WireGuard密钥
是否使用已有密钥? [Y/n]: y

# 3. 选择密钥
[1] 来源: /etc/wireguard/dn42-hk.conf
    公钥: AbCdEf...

请选择密钥编号 (1-1) 或输入 0 生成新密钥: 1

# 4. 使用已有密钥完成配置
[INFO] 使用已选择的密钥
```

### 添加新隧道

```bash
# 1. 运行脚本配置新隧道
sudo ./dn42-ospf-wg.sh

# 2. 选择生成新密钥
是否使用已有密钥? [Y/n]: n

# 或者
请选择密钥编号 (1-1) 或输入 0 生成新密钥: 0

# 3. 使用新密钥完成配置
```

## 总结

密钥自动检测功能让你可以：

- ✅ 避免重复生成密钥
- ✅ 简化隧道重新配置
- ✅ 灵活选择使用已有或新密钥
- ✅ 自动验证密钥有效性
- ✅ 提高配置效率

建议在生产环境中为每个隧道使用独立的密钥对，以提高安全性和可管理性。
