# --- 阶段 1: 构建阶段 (Builder Stage) ---
# 使用一个包含 Rust、Clang、LLVM 和内核头文件的基础镜像来编译 eBPF 程序
# rust:latest 是一个很好的选择，因为它通常包含了 Clang/LLVM，
# 但我们还需要安装内核头文件和 libbpf-dev 等。
FROM rust:latest as builder

# 设置构建阶段的工作目录
WORKDIR /app

# 安装编译 eBPF 程序所需的工具和库
# 注意：`linux-headers-$(uname -r)` 需要在构建时能够获取宿主机的内核版本，
# 这对于编译与特定内核兼容的 eBPF 程序非常重要。
RUN apt-get update && apt-get install -y --no-install-recommends \
    clang \
    llvm \
    libelf-dev \
    libbpf-dev \
    linux-headers-$(uname -r) && \
    rm -rf /var/lib/apt/lists/*

# 复制 Cargo.toml 和 Cargo.lock，利用 Docker 层缓存加速依赖下载
COPY Cargo.toml Cargo.lock ./

# 运行一个占位构建，只为下载和缓存依赖。
# 如果依赖不变，这步会被缓存，后续构建更快。
# `|| true` 是为了防止因为缺少源代码而导致的首次构建失败。
RUN mkdir -p src && echo "fn main() {println!(\"Hello\");}" > src/main.rs && cargo build --release || true

# 复制所有项目源文件（包括你的 Rust eBPF 代码）
# 这一步应该在你所有的 Cargo.toml 和 Cargo.lock 拷贝之后
COPY . .

# 编译你的 Rust eBPF 项目（以 release 模式），生成可执行文件
RUN cargo build --release

# --- 阶段 2: 运行阶段 (Runner Stage) ---
# 使用一个轻量级的基础镜像，只包含运行 eBPF 程序所需的最小运行时依赖
FROM ubuntu:22.04

# 设置运行阶段的工作目录
WORKDIR /root/

# 安装运行 eBPF 程序可能需要的运行时依赖
# `libelf1` 是常见的依赖，用于处理 eBPF 程序本身（通常是 ELF 格式）
RUN apt-get update && apt-get install -y --no-install-recommends \
    libelf1 \
    libbpf0 && \ # 添加 libbpf0，因为它可能是 eBPF 程序加载时的运行时依赖
    rm -rf /var/lib/apt/lists/*

# 从构建阶段复制编译好的可执行文件到最终镜像
# `runqslower` 会从 builder 阶段的 `/app/target/release/` 复制过来
COPY --from=builder /app/target/release/runqslower /root/runqslower

# 定义容器启动时运行的命令
ENTRYPOINT ["/root/runqslower"]