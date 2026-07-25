return {
    name = "cpp",
    description = "C++ development environment",
    packages = {
        { name = "build-essential", manager = "apt" },
        { name = "clang", manager = "apt" },
        { name = "cmake", manager = "apt" },
        { name = "ninja-build", manager = "apt" },
        { name = "gdb", manager = "apt" },
        { name = "git", manager = "apt" },
    },
    sources = {},
    env = {
        CC = "clang",
        CXX = "clang++",
    },
}
