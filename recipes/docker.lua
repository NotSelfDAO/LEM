return {
    name = "docker",
    description = "Docker environment",
    packages = {
        { name = "docker.io", manager = "apt" },
        { name = "docker-compose", manager = "apt" },
    },
    sources = {},
    env = {},
}
