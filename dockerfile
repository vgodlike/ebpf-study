# --- 阶段 1: 构建阶段 (Builder Stage) ---
FROM rust:latest as builder

WORKDIR /app

# --- 更换 Debian 镜像源为阿里云并清理其他源 ---
# 首先清空 /etc/apt/sources.list.d/ 目录下的所有源配置
RUN rm -f /etc/apt/sources.list.d/*.list && \
    # 直接创建或覆盖 /etc/apt/sources.list 文件
    echo "deb https://mirrors.aliyun.com/debian/ bookworm main contrib non-free" > /etc/apt/sources.list && \
    echo "deb https://mirrors.aliyun.com/debian/ bookworm-updates main contrib non-free" >> /etc/apt/sources.list && \
    echo "deb https://mirrors.aliyun.com/debian-security/ bookworm-security main contrib non-free" >> /etc/apt/sources.list && \
    # 更新软件包列表，以便 apt-get install 使用新的源
    apt-get update

# 安装编译 eBPF 程序所需的工具和库。
RUN apt-get install -y --no-install-recommends \
    clang \
    llvm \
    libelf-dev \
    libbpf-dev && \
    rm -rf /var/lib/apt/lists/*

# 复制 Cargo.toml 和 Cargo.lock。利用 Docker 的层缓存来加速依赖下载和编译。
COPY Cargo.toml Cargo.lock ./

# 运行一个“假”构建，目的是让 Cargo 下载并缓存所有依赖。
RUN mkdir -p src && echo "fn main() {println!(\"Hello\");}" > src/main.rs && cargo build --release || true

# 复制所有项目源文件（包括你的 Rust eBPF 代码）。
COPY . .

# 编译你的 Rust eBPF 项目，以 release 模式生成优化后的可执行文件。
RUN cargo build --release

# --- 阶段 2: 运行阶段 (Runner Stage) ---
FROM ubuntu:22.04

WORKDIR /root/

# --- 更换 Ubuntu 镜像源为阿里云并清理其他源 ---
# 首先清空 /etc/apt/sources.list.d/ 目录下的所有源配置
RUN rm -f /etc/apt/sources.list.d/*.list && \
    # 直接创建或覆盖 /etc/apt/sources.list 文件
    echo "deb https://mirrors.aliyun.com/ubuntu/ jammy main restricted universe multiverse" > /etc/apt/sources.list && \
    echo "deb https://mirrors.aliyun.com/ubuntu/ jammy-updates main restricted universe multiverse" >> /etc/apt/sources.list && \
    echo "deb https://mirrors.aliyun.com/ubuntu/ jammy-backports main restricted universe multiverse" >> /etc/apt/sources.list && \
    echo "deb https://mirrors.aliyun.com/ubuntu/ jammy-security main restricted universe multiverse" >> /etc/apt/sources.list && \
    # 更新软件包列表，以便 apt-get install 使用新的源
    apt-get update

# 安装运行 eBPF 程序可能需要的运行时依赖。
RUN apt-get install -y --no-install-recommends \
    libelf1 \
    libbpf0 && \
    rm -rf /var/lib/apt/lists/*

# 从构建阶段复制编译好的可执行文件到最终的运行镜像中。
COPY --from=builder /app/target/release/runqslower /root/runqslower

# 定义容器启动时默认执行的命令。
ENTRYPOINT ["/root/runqslower"]