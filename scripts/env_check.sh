#!/usr/bin/env bash
#
# scripts/env_check.sh — Day 001 环境自检脚本
#
# 作用：报告学习主机的操作系统 / CPU / 内存 / 磁盘 / 关键工具版本，
#       并对缺失工具给出提示。输出是纯文本，方便用 tee 归档到 evidence/。
#
# 用法：
#   ./scripts/env_check.sh                                # 打印到终端
#   ./scripts/env_check.sh | tee evidence/day01-env.txt   # 打印并归档
#
# 设计约定（这也是整个 100 天项目要遵守的工程习惯）：
#   1. 只读探测：不安装、不修改系统，绝不使用 sudo。
#   2. 分级提示：CORE  = 阶段一（Day 1~10）就会用到，缺失请立即安装；
#                LATER = 后续阶段才用，缺失不影响 Day 001 验收。
#   3. 退出码契约：CORE 齐全返回 0，CORE 缺失返回 1（见文末）。
#
# 【写给 C 程序员】Shell vs C 的六大思维差异（细节见文内【对比 C】注释）：
#   1. 不经编译：脚本是文本，bash 逐行解释执行；bash -n 脚本 相当于"只查语法"。
#      语法错误要到运行那一行才暴露，没有编译期类型检查兜底。
#   2. 无类型：所有变量都是字符串。x=0 存的是"0"这个字符串，
#      只有放进 $(( )) 里才按数字运算；也不存在 struct/指针/内存管理。
#   3. 取值要加 $：赋值写 x=1，取值写 $x。C 里两边都不加 —— 这是 C 程序员
#      最容易混的地方（忘了 $ 会得到空串，多了 $ 会当命令名）。
#   4. 退出码即布尔：0 = 成功/成立，非 0 = 失败。C 的 if(0) 是 false，
#      shell 的 if 测退出码时 0 反而是"真"，直觉恰好相反。
#   5. 命令即表达式：if / && / || 作用于"上一条命令的退出码"，不是布尔值。
#   6. 函数返回值只有退出码（0~255）：想"返回数据"就打印到 stdout，
#      调用方用 $( ) 捕获 —— 没有 return 一个字符串这种事。
#
set -euo pipefail
# -e           任何"未加保护"的命令失败就立刻退出
# -u           引用未定义变量直接报错，防止 $typo 静默展开成空串
# -o pipefail  管道里任何一段失败，整条管道都算失败
# 有了 -e，凡是"允许失败"的命令都必须显式写 || true，或包进下面的函数里。
# 【对比 C】C 靠每一步 if (ret < 0) 手工检查错误；-e 相当于"任何库函数返回
#   非 0 就 abort()"的全局开关。省事的代价：可接受的失败必须显式豁免。

# ---------------------------------------------------------------------------
# 小工具函数
# ---------------------------------------------------------------------------

# 【对比 C】函数定义的差异：
#   C:     void section(const char *title) { printf(...); }
#   shell: section() { ... }   —— 没有返回类型、没有参数表、大括号内侧要空格/换行
#   参数不声明，靠 $1 $2 ... 按位置取（个数是 $#，全部参数是 $@）。
#   调用时不写括号、不用逗号分隔实参：section "标题"，不是 section("标题")。

# 打印小节标题
section() {
    printf '\n=== %s ===\n' "$1"
}

# 打印 "名称: 值" 一行
# 【对比 C】printf 是少数直接照搬 C 的地方，%-22s 格式串语法完全一致。
#   差别在参数无类型：C 里 %-22s 后面必须跟 char*，这里跟什么都是字符串。
kv() {
    printf '%-22s %s\n' "$1:" "$2"
}

# 运行命令并取第一行输出；命令失败或没输出都不影响脚本继续。
# 为什么不写成 `cmd | head -n 1`：
#   本脚本开了 pipefail，head 取完一行就退出，上游命令可能收到 SIGPIPE
#   （退出码 141），管道会"莫名其妙"失败。先整体捕获、再截断，没这个坑。
# 【对比 C】
#   "$@"     = 展开为本函数收到的全部实参，像 C 的 argv，但自动保持分词边界
#             （"gcc" "--version" 两个参数不会粘成一个）。
#   local out = C 的局部变量天然块作用域；shell 变量默认全局（进程级），
#             必须显式 local。没有 local 的 out 会污染脚本其他地方。
#   $( ...)  = 命令替换，捕获子进程 stdout。C 要 popen() 或 pipe()+fork()+
#             dup2()+read() 才能干同样的事，这里只要两美元一对括号。
first_line() {
    local out
    out="$("$@" 2>&1 || true)"
    # ${out%%pattern} 参数展开做字符串裁剪：从尾部删掉匹配 pattern 的最长部分。
    #   等价于 C 里 strchr 找换行 + strncpy 截断的组合，但不需要缓冲区和长度。
    # $'\n' 是 ANSI-C 引用法，表示换行字符本身（不是反斜杠和字母 n）。
    printf '%s' "${out%%$'\n'*}"
}

# 运行一条多行的信息类命令；失败时给出提示而不是中断脚本
# 【对比 C】2>&1 是文件描述符重定向，约等于 C 的 dup2(2, 1)：
#   0=stdin、1=stdout、2=stderr。这是 shell 的"语法"，不是函数调用。
#   || 连接的是退出码而非布尔值，读作"前面的命令失败就执行 echo"。
#   $* = 全部参数拼成一个字符串（提示用）；对比 "$@" 是保持边界的逐个展开。
run() {
    "$@" 2>&1 || echo "（无法执行：$*）"
}

# ---------------------------------------------------------------------------
# 脚本路径定位
# ---------------------------------------------------------------------------

# ${BASH_SOURCE[0]} 是"本脚本自己的路径"，比 $0 可靠（被 source 时也正确）
# 【对比 C】≈ main 的 argv[0]，但 C 的 argv[0] 可被调用方伪造。
#   嵌套 $( $( ) ) 像表达式嵌套：dirname 算目录、cd 进去、pwd 拿绝对路径。
#   赋值 = 两边不能有空格：写 x = 1 会把 x 当命令执行！与 C 的自由风格相反。
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(dirname "$script_dir")"   # scripts/ 的上一级 = 仓库根目录

# ---------------------------------------------------------------------------
# 报告正文
# ---------------------------------------------------------------------------

section "环境自检报告"
kv "生成时间" "$(first_line date -Is)"
kv "主机名"   "$(first_line hostname)"
kv "当前用户" "$(first_line id -un)"
kv "仓库根目录" "$repo_root"

section "操作系统"
# 【对比 C】if 测的是退出码：[ -r 文件 ] 成立则退出码 0，即 if 为"真"。
#   [ 不是语法而是命令（test 的别名），所以 [ 后、] 前必须有空格 —— 少个空格
#   就是语法错误。等价于 C 的 access(path, R_OK) == 0。
if [ -r /etc/os-release ]; then
    # 【对比 C】. 文件（source 的简写）= 运行期把文件内容当代码在当前 shell 里
    #   执行，变量直接进入当前作用域。对比 C 的 #include：编译期文本插入。
#   一个发生在运行时、一个发生在编译时 —— 时机完全不同。
    . /etc/os-release    # 这个文件里是 PRETTY_NAME=... 这样的赋值语句，source 进来即可用
    # ${VAR:-默认值}：变量未定义或为空时取默认值。C 的变量没有"未定义"概念
    #（未初始化是垃圾值）；shell 未定义变量展开为空串（本脚本 set -u 时会直接报错）。
    kv "发行版" "${PRETTY_NAME:-${NAME:-unknown}}"
else
    kv "发行版" "读不到 /etc/os-release"
fi
kv "内核版本" "$(first_line uname -r)"
kv "完整内核信息" "$(first_line uname -a)"

section "CPU"
kv "逻辑核心数" "$(first_line nproc)"
# 过滤 lscpu 的关键行；末尾 || true 不能省：
# 开了 pipefail 时 grep 一条都没匹配到会返回 1，会把脚本整个杀掉。
# 【对比 C】续行符 \：shell 命令遇换行即结束，长命令必须 \ 续行
#（C 里换行基本无意义）。管道 | 在 C 里要 pipe()+fork()+dup2() 三个系统调用，
# shell 一个字符搞定：左进程 stdout 直连右进程 stdin。
lscpu 2>&1 | grep -E '^(Architecture|CPU\(s\)|Model name|Thread\(s\) per core|Core\(s\) per socket|Socket\(s\))' \
    || echo "（读不到 lscpu 关键信息）"

section "内存"
run free -h

section "磁盘"
echo "-- 根分区（系统与工具）--"
run df -hT /
echo
echo "-- 仓库所在文件系统（Day 51+ 的 Buildroot 构建目录请放空间大的盘）--"
run df -hT "$repo_root"

section "编译器与目标架构（主机 vs 目标机）"
kv "主机架构" "$(first_line uname -m)"
if command -v gcc >/dev/null 2>&1; then
    # >/dev/null 是重定向到空设备（丢弃 stdout），2>&1 再把 stderr 也并过去。
    # command -v 只查不执行，找到返回 0 —— C 程序员会联想到 which/PATH 搜索，
    # 但那在 shell 里是"跑一个子进程"，这里是内建命令，更快且不依赖外部程序。
    kv "gcc 默认目标三元组" "$(first_line gcc -dumpmachine)"
    # 【对比 C】下面这行本身就是 shell 特有写法：相邻的引号片段会拼接成同一个词，
    # "a"b"c" 在 shell 里是 abc 一个词，在 C 里 "a"b"c" 是语法错误。
    echo "  ↑ 这是"本机编译、本机运行"（原生编译）。"
    echo "    Day 47 起改用 aarch64-linux-gnu-gcc 产出 AArch64 代码（交叉编译），"
    echo "    那种二进制不能在本机直接跑 —— 这就是主机(host)与目标机(target)的区别。"
fi

# ---------------------------------------------------------------------------
# 工具版本检查
# ---------------------------------------------------------------------------

# 【对比 C】变量声明：没有类型、没有声明语句，第一次赋值即创建。
# missing_count=0 不是 int，是字符串 "0"；真正按数字算要靠 $(( ))。
# 字符串拼接就是把变量挨着写，没有 strcat、没有缓冲区、没有内存管理。
missing_count=0
missing_names=""
core_missing=""

# check_tool <命令名> <CORE|LATER> <用途说明> [版本参数]
# 版本参数不传时默认 --version（${4:---version} 即"取 $4，没给就用 --version"）
# 【对比 C】${4:-默认值} 是"默认实参"，C 没有这特性（C++ 才有）。
#   local 可以一条语句声明多个变量并同时初始化，C 得写多行。
check_tool() {
    local cmd="$1" group="$2" purpose="$3" ver_flag="${4:---version}"
    if command -v "$cmd" >/dev/null 2>&1; then
        local ver
        ver="$(first_line "$cmd" "$ver_flag")"
        kv "$cmd" "${ver:-（已安装，但没取到版本信息）}"
    else
        kv "$cmd" "MISSING [ $group | $purpose ]"
        # 别写 ((missing_count++))：计数从 0 变 1 时算术式值为 0、返回码为 1，
        # 会被 set -e 当作失败杀掉脚本。用赋值形式就没这个坑。
        # 【对比 C】$(( )) 是算术展开，里面的写法几乎就是 C 表达式
        #（+ - * / % 优先级都一样），但外层必须套 $(( ))，且参与运算的
        # 变量在这里是"长得像数字的字符串"，C 里它们是真正的 int。
        missing_count=$((missing_count + 1))
        missing_names="${missing_names} ${cmd}"
        # 【对比 C】字符串比较用单个 =（C 是 == 或 strcmp()）；数字比较用
        # -eq / -lt / -gt。这里的 = 是 [ 命令的参数，不是赋值！
        # 变量必须加引号：不写的话 $group 为空时变成 [ = "CORE" ]，语法错误。
        if [ "$group" = "CORE" ]; then
            core_missing="${core_missing} ${cmd}"
        fi
    fi
}

section "工具版本"
echo "-- CORE：阶段一（Day 1~10）就会用到，缺失请立即安装 --"
# 【对比 C】调用语法：实参空格分隔，无括号无逗号。bash 按位置把
# git→$1、CORE→$2、"版本控制（全程）"→$3，与 C 的 call(arg1, arg2) 对应。
check_tool git  CORE "版本控制（全程）"
check_tool gcc  CORE "C 编译器（Day 2 起）"
check_tool make CORE "构建工具（Day 5 起）"
check_tool bash CORE "脚本运行环境"

echo
echo "-- LATER：后续阶段才用，缺失不影响 Day 001 验收 --"
check_tool clang    LATER "Day 43 Sanitizer 检查"
check_tool gdb      LATER "Day 42 调试与 core dump"
check_tool cmake    LATER "备用构建系统"
check_tool python3  LATER "Day 29 起写测试脚本"
check_tool strace   LATER "Day 41 系统调用追踪"
check_tool valgrind LATER "Day 43 内存检查"
check_tool perf     LATER "Day 44 CPU 性能分析"  version
check_tool aarch64-linux-gnu-gcc LATER "Day 47 交叉编译"
check_tool qemu-aarch64          LATER "Day 49 用户态模拟"
check_tool qemu-system-aarch64   LATER "Day 50+ 整机模拟"
check_tool dtc      LATER "Day 50 设备树编译"

# ---------------------------------------------------------------------------
# 结论与退出码
# ---------------------------------------------------------------------------

section "结论"
if [ "$missing_count" -eq 0 ]; then
    echo "检查通过：以上工具全部就绪。"
else
    echo "缺失 ${missing_count} 个工具：${missing_names}"
    echo "  CORE  → 现在安装：sudo apt update && sudo apt install -y <包名>"
    echo "  LATER → 记下来，到对应阶段再装即可。"
    if [ -n "$core_missing" ]; then
        echo "CORE 仍有缺失（${core_missing}）→ 返回退出码 1"
        exit 1
    fi
fi
exit 0
# 【对比 C】exit N ≈ main 里 return N，0=成功、非 0=失败（shell 里最好别超过
# 125，126/127/128+ 被 shell 保留给"不可执行/找不到命令/被信号杀"）。
# 再强调一次语感差异：C 的 if(0) 为 false，而 shell 的 if 在退出码 0 时为真。
