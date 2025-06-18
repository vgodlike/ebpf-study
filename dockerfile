# --- 阶段 1: 构建阶段 (Builder Stage) ---
# 使用 rust:latest 作为基础镜像。它包含了 Rust 编译器、Cargo，
# 并且通常也预装了 Clang 和 LLVM，这些是编译 eBPF C/Rust 代码所必需的。
FROM rust:latest as builder

# 设置构建阶段的工作目录
WORKDIR /app

# 安装编译 eBPF 程序所需的工具和库。
# 这些包括：
# - clang, llvm: eBPF 后端编译工具。
# - libelf-dev: 处理 ELF 格式（eBPF 程序通常是 ELF 文件）所需的开发库。
# - libbpf-dev: 用于构建 BPF 程序加载器和帮助库。
# - linux-headers-$(uname -r): 宿主机的内核头文件，编译 eBPF 程序时通常需要这些头文件来定义数据结构和 BPF Helper 函数。
# 注意：`uname -r` 在 Docker 构建时会获取构建环境（这里是 `rust:latest` 容器）的内核版本，
# 这通常会导致问题，因为容器的内核版本可能与宿主机的实际内核版本不同。
# 更好的做法是在宿主机上获取 `uname -r` 的值，然后作为构建参数传递给 Dockerfile，
# 但为了简化，这里先用 `$(uname -r)`，如果遇到内核版本不匹配问题，可能需要手动指定。
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    clang \
    llvm \
    libelf-dev \
    libbpf-dev \
    linux-headers-$(uname -r) && \
    rm -rf /var/lib/apt/lists/*

# 复制 Cargo.toml 和 Cargo.lock。
# 这样做的目的是利用 Docker 的层缓存。如果依赖没有改变，
# 这一层以及之前的依赖下载/编译步骤就可以被缓存下来，加速后续构建。
COPY Cargo.toml Cargo.lock ./

# 运行一个“假”构建，目的是让 Cargo 下载并缓存所有依赖。
# 我们会创建一个临时的 `src/main.rs` 文件来让 `cargo build` 成功执行。
# `|| true` 确保即使第一次由于某种原因失败（比如没有实际源代码），也不会中断 Docker 构建。
RUN mkdir -p src && echo "fn main() {println!(\"Hello\");}" > src/main.rs && cargo build --release || true

# 复制所有项目源文件（包括你的 Rust eBPF 代码）。
# 这一步应该在 Cargo.toml 和 Cargo.lock 复制之后，以确保依赖缓存的有效性。
COPY . .

# 编译你的 Rust eBPF 项目，以 release 模式生成优化后的可执行文件。
# 假设你的 eBPF 程序编译后会生成在 `target/release/` 目录下，名为 `runqslower`。
RUN cargo build --release

# --- 阶段 2: 运行阶段 (Runner Stage) ---
# 使用一个轻量级的 Ubuntu 镜像作为最终镜像，只包含运行 eBPF 程序所需的最小运行时依赖。
FROM ubuntu:22.04

# 设置运行阶段的工作目录
WORKDIR /root/

# 安装运行 eBPF 程序可能需要的运行时依赖。
# - libelf1: 处理 eBPF 程序二进制文件（ELF 格式）所需的运行时库。
# - libbpf0: 如果你的 eBPF 程序使用了 libbpf 库来加载和管理 BPF 程序，那么运行时就需要这个库。
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    libelf1 \
    libbpf0 && \
    rm -rf /var/lib/apt/lists/*

# 从构建阶段复制编译好的可执行文件到最终的运行镜像中。
# `COPY --from=builder` 指令告诉 Docker 从名为 `builder` 的阶段复制文件。
# `/app/target/release/runqslower` 是在 builder 阶段编译后的路径。
# `/root/runqslower` 是在当前运行阶段镜像中的目标路径。
COPY --from=builder /app/target/release/runqslower /root/runqslower

# 定义容器启动时默认执行的命令。
# 当你运行这个 Docker 镜像时，它会自动尝试执行 `/root/runqslower`。
ENTRYPOINT ["/root/runqslower"]