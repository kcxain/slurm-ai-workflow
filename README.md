# slurm-ai-workflow

在 SLURM 集群上运行自主 ML 研究 agent 的工作流套件。基于 [karpathy/autoresearch](https://github.com/karpathy/autoresearch) 的实验循环，适配 SLURM 调度环境（登录节点无 GPU，计算节点无外网）。

**核心思路**：agent 运行在登录节点，通过 `sbatch` 把训练作业提交到 GPU 计算节点，读取共享文件系统上的日志，循环迭代——和直接 GPU 访问的体验一致，但走 SLURM 调度。

## 文件结构

```
program.md                    # Agent 实验指令（人类可编辑，定义研究目标）
run.sh                        # SLURM job script（wraps uv run train.py）
train.py                      # 模型和训练代码（agent 修改这个）
prepare.py                    # 数据准备和评估（只读）
results.tsv                   # 实验结果日志（agent 自动维护）
.claude/
├── SKILL.md                  # Agent 工作流指南（自动读取）
└── commands/
    ├── slurm-run.md          # /slurm-run：提交 + 等待 + 日志 + 自动修复
    └── slurm-test.md         # /slurm-test：srun 快速测试
```

## 快速开始

**前置要求**：登录节点已安装 Claude Code 和 `uv`，项目在共享文件系统上。

```bash
# 1. 准备数据（在登录节点，有外网）
uv run prepare.py

# 2. 启动 Claude Code
claude

# 3. 告诉 agent 开始实验
# 在 Claude 会话中输入：
# "请阅读 program.md，按其中的指令开始今天的实验，标签用 mar5"
```

Agent 会自动：创建 git 分支 → 修改 `train.py` → 提交 SLURM 作业 → 读取日志 → 保留/回滚 → 无限循环。

## 与原版 autoresearch 的差异

| 项目 | autoresearch（原版） | 本项目（SLURM） |
|------|---------------------|----------------|
| 运行训练 | `uv run train.py` | `sbatch run.sh` |
| 等待结果 | 直接阻塞 | 轮询 `squeue` |
| 读取输出 | 实时终端 | `cat logs/slurm-<JOB_ID>.out` |
| 超时处理 | kill 进程 | `scancel $JOB_ID` |
| GPU 访问 | 直接 | 通过 SLURM 调度 |

## 自定义

- **修改实验方向**：编辑 `program.md` 中的目标描述和约束
- **调整计算资源**：编辑 `run.sh` 中的 `#SBATCH` 参数（需与用户协商，agent 不会自行修改）
- **查看实验进度**：`cat results.tsv` 或用 `analysis.ipynb`
