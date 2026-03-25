# SLURM 集群 + Claude Code 开发工作流

适用场景：本地 Mac 写代码，远程 SLURM 集群（登录节点 + 计算节点分离，计算节点无外网）调试运行。

## 架构概览

```
Local (Mac)               Login Node                Compute Node (GPU)
+-----------+   Unison    +------------------+  共享文件系统 (NFS/Lustre)
|  Editor   | <=========> | Claude Code      | <======================>
|           |   git       | (tmux session)   |  sbatch / srun jobs
+-----------+ <=========> +------------------+  (无外网，不能运行 Claude)
```

**关键设计原则：**
- **Unison** 只需同步到登录节点——计算节点通过共享文件系统自动看到相同文件
- **Claude Code 运行在登录节点**（有外网，能调用 API）
- **GPU 测试通过 `srun`/`sbatch` 提交**，输出写到共享文件系统，Claude 读取日志迭代

## 前置条件

- SSH 可访问登录节点（建议配置密钥登录和 SSH config 别名）
- 登录节点和本地都安装了 [Unison](https://github.com/bcpierce00/unison)（**版本必须一致**）
- 登录节点安装了 Claude Code
- 项目目录在共享文件系统上（如 `/data/username/project` 或 `~/project`，确认计算节点可访问）

## Part 1：Unison 文件同步

与单机方案相同，Unison 目标是**登录节点**。计算节点通过共享 FS 自动同步，无需额外配置。

### 安装 Unison

```bash
# Mac (本地)
brew install unison

# 登录节点 (无 sudo 时用 conda)
conda install -c conda-forge unison
# 或从 GitHub Releases 下载静态二进制

# 验证版本一致
unison -version  # 两端必须完全相同
```

### 创建 Unison Profile

在本地创建 `~/.unison/myproject.prf`：

```ini
# 本地路径 和 登录节点路径
root = /path/to/local/project
root = ssh://login-node//path/to/remote/project

# 忽略 .git（重要！）
ignore = Name .*

# 如需同步 .github 等特定隐藏目录，单独放行：
# ignorenot = Name .github

# 忽略编译产物和缓存
ignore = Name __pycache__
ignore = Name *.pyc
ignore = Name *.egg-info
ignore = Name dist
ignore = Name build
ignore = Name node_modules

# 忽略 SLURM 日志（可选，避免日志反向同步到本地）
ignore = Name slurm-*.out
ignore = Name slurm-*.err

# 跨平台兼容
perms = 0
prefer = newer
times = true

# 每 1 秒检测变更
repeat = 1

follow = Name *
```

### 运行 Unison

```bash
unison myproject
# 首次运行会询问每个文件的处理方式，直接回车接受默认值
```

## Part 2：Git 历史同步

Unison 只同步文件内容，忽略 `.git`。需要单独同步 git 历史，以便拉取 Claude 在登录节点上的 commit。

### 一次性设置

**本地——将登录节点添加为 git remote：**

```bash
git remote add cluster ssh://login-node/path/to/remote/project
```

**登录节点——允许 push 到当前分支：**

```bash
cd ~/project
git config receive.denyCurrentBranch warn
```

**登录节点——创建 post-receive hook：**

创建 `~/project/.git/hooks/post-receive`：

```bash
#!/bin/sh
GIT_DIR=/path/to/remote/project/.git git reset HEAD 2>/dev/null
```

```bash
chmod +x ~/project/.git/hooks/post-receive
```

> **为什么需要这个 hook？** `git push` 更新了 `.git` 中的引用，但 working tree 已经由 Unison 管理了。`git reset HEAD` 让 index 与新 commit 一致，否则登录节点会把所有 Unison 同步的文件显示为 unstaged changes。

### 日常工作流

```bash
# 把本地 commit 推到集群
git push cluster main

# 拉取 Claude 在集群上产生的 commit
git pull cluster main
```

## Part 3：在登录节点运行 Claude Code

SSH 进登录节点，在 tmux 里启动 Claude：

```bash
ssh login-node
tmux new-session -s claude
cd ~/project
claude --dangerously-skip-permissions
```

tmux 保证 SSH 断线后 Claude 继续运行。随时重新连接：

```bash
ssh -t login-node 'tmux attach -t claude'
```

## Part 4：Claude 通过 SLURM 调试 GPU 代码

这是与单机方案最大的不同。Claude 在登录节点，GPU 在计算节点，两者通过 SLURM 通信。

### 方式一：`srun` 快速测试（阻塞，适合单次调试）

`srun` 同步执行，输出直接打印到终端，Claude 可立即看到结果：

```bash
# Claude 可以直接运行这类命令来测试代码
srun --gres=gpu:1 --mem=16G python test_forward_pass.py
srun --gres=gpu:1 python -c "import torch; print(torch.cuda.is_available())"
```

适合场景：验证单个函数、检查 GPU 是否可用、快速检查数据加载。

### 方式二：`sbatch` 异步提交（适合完整训练/长时间任务）

**标准作业脚本模板** `scripts/run.sh`：

```bash
#!/bin/bash
#SBATCH --job-name=myproject
#SBATCH --output=logs/slurm-%j.out
#SBATCH --error=logs/slurm-%j.err
#SBATCH --gres=gpu:1
#SBATCH --mem=32G
#SBATCH --time=02:00:00
#SBATCH --cpus-per-task=8

# 激活环境（conda 环境在共享 FS 上，计算节点可访问）
source ~/.bashrc
conda activate myenv

cd /path/to/remote/project

python train.py \
    --config configs/default.yaml \
    "$@"
```

**Claude 的调试循环：**

```bash
# 1. 提交作业
JOB_ID=$(sbatch scripts/run.sh --debug | awk '{print $NF}')

# 2. 查看状态
squeue -j $JOB_ID

# 3. 实时跟踪日志（作业运行中或结束后）
tail -f logs/slurm-${JOB_ID}.out

# 4. 查看完整输出
cat logs/slurm-${JOB_ID}.out
```

Claude 提交作业后会等待日志文件出现，然后读取输出，根据错误信息修改代码，再次提交。

### 方式三：交互式计算节点 session（人工调试）

如果你自己想在计算节点上手动调试：

```bash
# 申请交互式节点（在登录节点上执行）
srun --gres=gpu:1 --mem=16G --time=01:00:00 --pty bash

# 进入后激活环境，手动运行代码
conda activate myenv
cd ~/project
python debug_script.py
```

> **注意**：此 session 里无法运行 Claude Code（计算节点无外网），但你可以在这里手动测试，发现问题后回到登录节点让 Claude 修改代码。

## Part 5：离线依赖管理

计算节点无外网，所有依赖必须在**登录节点**（有外网）提前准备好，放在共享文件系统上。

### Python 环境

```bash
# 在登录节点上安装（conda 环境装在共享 FS，计算节点自动可用）
conda create -n myenv python=3.11
conda activate myenv
pip install -r requirements.txt
```

### 模型权重 / 数据集

```bash
# 在登录节点上下载（有外网）
huggingface-cli download meta-llama/Llama-3.1-8B --local-dir /data/models/llama3

# 代码里用本地路径，不要写 Hub ID
model = AutoModel.from_pretrained("/data/models/llama3")
```

### 禁用运行时的自动下载

在作业脚本里加入：

```bash
export HF_HUB_OFFLINE=1          # 禁止 huggingface_hub 联网
export TRANSFORMERS_OFFLINE=1     # 禁止 transformers 联网
export HF_DATASETS_OFFLINE=1      # 禁止 datasets 联网
```

## 典型工作流（日常使用）

```
1. 本地用编辑器改代码
       ↓ (Unison 自动同步到登录节点)
2. 登录节点的 Claude 看到变更，或由你在 Claude 会话里触发
       ↓
3. Claude 用 srun/sbatch 提交测试作业
       ↓
4. Claude 读取 logs/slurm-*.out，分析错误
       ↓
5. Claude 修改代码（Unison 自动同步回本地）
       ↓
6. 重复 3-5 直到通过
       ↓
7. Claude commit，你用 git pull cluster main 拉取结果
```

## 快速参考

| 操作 | 命令 |
|------|------|
| 启动文件同步 | `unison myproject` |
| 推送本地 commit | `git push cluster main` |
| 拉取 Claude 的 commit | `git pull cluster main` |
| 启动远程 Claude | `ssh login-node 'tmux new -s claude -d "cd ~/project && claude --dangerously-skip-permissions"'` |
| 连接远程 Claude | `ssh -t login-node 'tmux attach -t claude'` |
| 快速 GPU 测试 | `srun --gres=gpu:1 python test.py` |
| 提交训练作业 | `sbatch scripts/run.sh` |
| 查看作业状态 | `squeue -u $USER` |
| 查看作业日志 | `tail -f logs/slurm-<JOB_ID>.out` |
| 申请交互节点 | `srun --gres=gpu:1 --pty bash` |

## 与单机方案的核心差异

| 项目 | 单机远程 GPU | SLURM 集群 |
|------|-------------|-----------|
| Claude 运行位置 | 计算节点（直接 SSH） | 登录节点（计算节点无外网） |
| GPU 访问方式 | 直接使用 | `srun`/`sbatch` 提交作业 |
| 文件同步目标 | GPU 机器 | 登录节点（共享 FS 自动扩散） |
| 调试反馈 | 实时终端输出 | 读取日志文件 |
| 依赖安装 | 直接 `pip install` | 提前在登录节点安装到共享 FS |
