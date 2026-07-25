return {
    name = "server",
    description = "Server environment with Docker services",
    packages = {
        { name = "docker.io", manager = "apt" },
    },
    services = {
        {
            name = "mysql",
            image = "mysql:8",
            port = "3306:3306",
            env = { MYSQL_ROOT_PASSWORD = "lem_root_pass" },
        },
        {
            name = "redis",
            image = "redis:7",
            port = "6379:6379",
        },
    },
    sources = {},
    env = {},
}
