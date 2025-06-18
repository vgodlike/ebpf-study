# --- 阶段 1: 构建阶段 (Builder Stage) ---
# 使用 rust:latest 作为基础镜像。这个镜像通常基于 Debian 系统，包含了 Rust 编译器和 Cargo。
FROM rust:latest as builder

# 设置构建阶段的工作目录
WORKDIR /app

# --- 更换 Debian 镜像源为阿里云并清理其他源 ---
# 首先清空 /etc/apt/sources.list.d/ 目录下的所有源配置，确保不干扰后续的源设置。
RUN rm -f /etc/apt/sources.list.d/*.list && \
    # 直接创建或覆盖 /etc/apt/sources.list 文件，指向阿里云的 Debian Bookworm (Debian 12) 镜像源。
    echo "deb https://mirrors.aliyun.com/debian/ bookworm main contrib non-free" > /etc/apt/sources.list && \
    echo "deb https://mirrors.aliyun.com/debian/ bookworm-updates main contrib non-free" >> /etc/apt/sources.list && \
    echo "deb https://mirrors.aliyun.com/debian-security/ bookworm-security main contrib non-free" >> /etc/apt/sources.list && \
    # 更新软件包列表，以便 apt-get install 使用新的源。
    apt-get update

# 安装 rustfmt 组件。如果你的 Rust 项目或其依赖需要用到 rustfmt，这一步是必需的。
RUN rustup component add rustfmt

# 安装编译 eBPF 程序所需的工具和库。
# 这些包括：
# - clang, llvm: eBPF 后端编译工具，通常 rust:latest 已经包含了，但这里显式安装以防万一。
# - libelf-dev: 处理 ELF 格式（eBPF 程序通常是 ELF 文件）所需的开发库。
# - libbpf-dev: 用于构建 BPF 程序加载器和帮助库。
# 注意：这里不再安装特定内核版本的 `linux-headers`，因为宿主机内核是定制的。
# 实际的内核头文件将在运行时通过卷挂载提供。
RUN apt-get install -y --no-install-recommends \
    clang \
    llvm \
    libelf-dev \
    libbpf-dev && \
    rm -rf /var/lib/apt/lists/*

# 复制 Cargo.toml 和 Cargo.lock。
# 这样做能利用 Docker 的层缓存。如果项目依赖没有改变，这一层及之前的依赖下载/编译步骤将被缓存，从而加速后续构建。
COPY Cargo.toml Cargo.lock ./

# 运行一个“假”构建，目的是让 Cargo 下载并缓存所有依赖。
# 我们创建一个临时的 `src/main.rs` 文件来使 `cargo build` 成功执行。
# `|| true` 确保即使第一次构建失败（例如缺少实际源代码），也不会中断 Docker 构建流程。
RUN mkdir -p src && echo "fn main() {println!(\"Hello\");}" > src/main.rs && cargo build --release || true

# 复制所有项目源文件（包括你的 Rust eBPF 代码）。
# 这一步应该在 Cargo.toml 和 Cargo.lock 复制之后，以确保依赖缓存的有效性。
COPY . .

# 编译你的 Rust eBPF 项目，以 release 模式生成优化后的可执行文件。
# 假设你的 eBPF 程序编译后会生成在 `target/release/` 目录下，名为 `runqslower`。
RUN cargo build --release

# --- 阶段 2: 运行阶段 (Runner Stage) ---
# 使用一个轻量级的 Ubuntu 镜像作为最终镜像，只包含运行 eBPF 程序所需的最小运行时依赖。
# Ubuntu 22.04 的代号是 Jammy Jellyfish。
FROM ubuntu:22.04

# 设置运行阶段的工作目录
WORKDIR /root/

# --- 更换 Ubuntu 镜像源为阿里云并清理其他源 ---
# 清空 /etc/apt/sources.list.d/ 目录下的所有源配置。
RUN rm -f /etc/apt/sources.list.d/*.list && \
    # 写入阿里云的 Ubuntu Jammy (22.04) 镜像源。
    echo "deb https://mirrors.aliyun.com/ubuntu/ jammy main restricted universe multiverse" > /etc/apt/sources.list && \
    echo "deb https://mirrors.aliyun.com/ubuntu/ jammy-updates main restricted universe multiverse" >> /etc/apt/sources.list && \
    echo "deb https://mirrors.aliyun.com/ubuntu/ jammy-backports main restricted universe multiverse" >> /etc/apt/sources.list && \
    echo "deb https://mirrors.aliyun.com/ubuntu/ jammy-security main restricted universe multiverse" >> /etc/apt/sources.list && \
    # 更新软件包列表，以便 apt-get install 使用新的源。
    apt-get update

# 安装运行 eBPF 程序可能需要的运行时依赖。
# - libelf1: 处理 eBPF 程序二进制文件（ELF 格式）所需的运行时库。
# - libbpf0: 如果你的 eBPF 程序使用了 libbpf 库来加载和管理 BPF 程序，那么运行时就需要这个库。
RUN apt-get install -y --no-install-recommends \
    libelf1 \
    libbpf0 && \
    rm -rf /var/lib/apt/lists/*

# 从构建阶段复制编译好的可执行文件到最终的运行镜像中。
# `runqslower` 会从 builder 阶段的 `/app/target/release/` 复制过来。
COPY --from=builder /app/target/release/runqslower /root/runqslower

# 定义容器启动时默认执行的命令。
# 当你运行这个 Docker 镜像时，它会自动尝试执行 `/root/runqslower`。
ENTRYPOINT ["/root/runqslower"]