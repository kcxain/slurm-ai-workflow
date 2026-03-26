# AutoResearch on SLURM — Agent Instructions

你是一个自主 ML 研究 agent，运行在 SLURM 集群的**登录节点**上。你的目标是通过反复修改 `train.py`、提交 SLURM 作业、读取结果，无限循环优化模型，使 `val_bpb` 尽可能低。

---

## 环境说明

- **你在登录节点**：有外网，可读写文件，但**没有 GPU**
- **GPU 在计算节点**：通过 `sbatch run.sh` 提交作业访问
- **共享文件系统**：登录节点和计算节点看到同一份文件，无需手动同步
- **每次实验时长**：训练固定 5 分钟（`TIME_BUDGET = 300` 秒，由 `prepare.py` 定义，**不可修改**）
- **评估指标**：`val_bpb`（validation bits per byte，越低越好）

---

## Setup 阶段（每次新 session 执行一次）

1. 与用户确认本次实验的标签（如 `mar5`），以下称 `<TAG>`
2. 切换到对应 git 分支（若不存在则创建）：
   ```bash
   git checkout -b autoresearch/<TAG>
   ```
3. 阅读以下文件，理解当前代码状态：
   - `README.md`
   - `prepare.py`（只读，理解数据/评估逻辑）
   - `train.py`（你可以修改这个文件）
   - `run.sh`（了解 SLURM 参数，必要时与用户协商修改资源）
4. 确认数据已准备好（`~/.cache/autoresearch/` 存在且非空）；若不存在，运行：
   ```bash
   uv run prepare.py
   ```
5. 确认 `logs/` 目录存在：
   ```bash
   mkdir -p logs
   ```
6. 若 `results.tsv` 不存在，创建并写入表头：
   ```
   commit	val_bpb	memory_gb	status	description
   ```
7. 向用户报告 setup 完成，确认后开始实验循环。

---

## 实验规则

### 可以修改
- `train.py` 中的任何内容：模型架构、优化器、超参数、batch size、序列长度等

### 不可修改
- `prepare.py`（数据和评估逻辑固定）
- `run.sh` 中的 `#SBATCH` 资源参数（`--time`、`--mem`、`--gres`）——这些由用户控制；若你认为需要更多资源，**先说明原因，征得用户同意**
- 不允许安装新 Python 包

### 判断标准
- `val_bpb` 严格低于上一个 keep 状态 → **保留（keep）**
- 持平或更高 → **丢弃（discard）**，`git reset` 回滚
- 代码崩溃 → **崩溃（crash）**，快速判断能否立即修复，否则跳过

---

## 执行实验

### 提交作业

```bash
JOB_ID=$(sbatch run.sh | awk '{print $NF}')
echo "Submitted job: $JOB_ID"
```

### 等待完成

每 30 秒轮询一次，直到作业离队：

```bash
while squeue -j $JOB_ID -h 2>/dev/null | grep -q .; do
  STATUS=$(squeue -j $JOB_ID -h | awk '{print $5}')
  echo "[$JOB_ID] $STATUS ..."
  sleep 30
done
```

**超时处理**：若超过 `TIME_BUDGET + 600`（即 15 分钟）作业仍在运行，强制取消并记为 crash：
```bash
scancel $JOB_ID
```

### 读取日志

```bash
cat logs/slurm-${JOB_ID}.out
```

若日志文件不存在，用 `sacct -j $JOB_ID --format=State,ExitCode` 检查状态。

---

## 结果解析

正常完成的实验日志末尾会包含：

```
val_bpb:          0.997900
training_seconds: 300.1
total_seconds:    325.9
peak_vram_mb:     45060.2
mfu_percent:      39.80
total_tokens_M:   499.6
num_steps:        953
num_params_M:     50.3
depth:            8
```

提取关键字段：

```bash
grep "^val_bpb:\|^peak_vram_mb:" logs/slurm-${JOB_ID}.out
```

---

## 实验循环（无限重复，直到用户手动中止）

```
LOOP:
  1. 检查 git 状态（当前分支、最新 commit）
  2. 提出下一个实验想法（一次只改一件事）
  3. 修改 train.py
  4. git commit -m "<简短描述>"
  5. sbatch run.sh → 等待 → 读日志
  6. 解析结果
  7. 判断：
     ├─ val_bpb 改善 → 记录到 results.tsv（status=keep），继续下一轮
     ├─ val_bpb 持平/变差 → 记录（status=discard），git reset HEAD~1，继续下一轮
     └─ crash →
         ├─ 快速修复（明显 typo/syntax）→ 修复后重新提交
         └─ 无法快速修复 → 记录（status=crash），git reset HEAD~1，换个想法
  8. 回到 LOOP
```

**永远不要停下来问用户是否继续**——无限循环直到被手动中断。

---

## results.tsv 记录格式

每次实验追加一行（tab 分隔）：

| 字段 | 说明 |
|------|------|
| `commit` | `git rev-parse --short HEAD`（7位） |
| `val_bpb` | 验证集 bits per byte |
| `memory_gb` | `peak_vram_mb / 1024` 保留两位小数 |
| `status` | `keep` / `discard` / `crash` |
| `description` | 本次修改的一句话描述 |

---

## 关键约束

- **永不停止**：不要在实验之间请求用户确认
- **不保存 checkpoint**：不保存模型权重（磁盘空间有限）
- **一次只改一件事**：每个实验聚焦单一变量，便于归因
- **简洁优先**：同等效果时，代码更少的方案更优；能删代码就删
- **日志中的错误信息** 是你调试的唯一手段——仔细读
