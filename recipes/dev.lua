return {
    name = "dev",
    description = "General development environment",
    packages = {
        { name = "git", manager = "apt" },
        { name = "curl", manager = "apt" },
        { name = "wget", manager = "apt" },
        { name = "vim", manager = "apt" },
        { name = "htop", manager = "apt" },
        { name = "tmux", manager = "apt" },
        { name = "jq", manager = "apt" },
        { name = "unzip", manager = "apt" },
        { name = "net-tools", manager = "apt" },
    },
    sources = {},
    env = {},
}
