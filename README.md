# Setup script for linux distribution
See help for listing available commands
```bash
bash setup.sh --help

```
By default, the script installs all apps and skips apps/packages that are already installed:
```bash
bash setup.sh
```

You can still run all explicitly with `bash setup.sh --all`, or install a single app with a flag such as `bash setup.sh --uv` or `bash setup.sh --tmux`.

Idea is to add/remove apps when they make sense for my setup.

## Next
Add support for
- pipx
- pyenv
- python3.12, python3.13, python3.14?
- kaggle CLI tool
